// probe writes without pause and records which writes the server acknowledged.
// A write counts only when the server confirmed it; a timeout or an error is not an acknowledgement.
//
//	probe pg     -dsn postgres://...      INSERT one row per write
//	probe read   -dsn postgres://...      read the newest row written by a pg run, one query per attempt
//	probe kube   -url https://127.0.0.1:6443   update one ConfigMap per write, with the K3s admin certificate
//	probe http   -url http://10.43.0.10/   one GET per attempt on a new connection, so a Service picks a backend each time
//	probe verify -dsn postgres://... -acks pg.jsonl   acknowledged rows that are missing from the database
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type record struct {
	N    int64  `json:"n"`
	Sent int64  `json:"sent"`
	Ack  int64  `json:"ack,omitempty"`
	Err  string `json:"err,omitempty"`
}

type writer func(ctx context.Context, n int64) error

func main() {
	if len(os.Args) < 2 {
		fail("usage: probe pg|read|kube|http|verify [flags]")
	}
	mode := os.Args[1]
	fs := flag.NewFlagSet(mode, flag.ExitOnError)
	interval := fs.Duration("interval", 20*time.Millisecond, "pause between writes")
	duration := fs.Duration("duration", 5*time.Minute, "how long to write")
	timeout := fs.Duration("timeout", 2*time.Second, "give up on one write after this")
	dsn := fs.String("dsn", "", "Postgres connection string")
	url := fs.String("url", "https://127.0.0.1:6443", "Kubernetes API")
	tlsDir := fs.String("tls", "/var/lib/rancher/k3s/server/tls", "K3s TLS directory")
	acks := fs.String("acks", "", "output of a pg run")
	_ = fs.Parse(os.Args[2:])

	switch mode {
	case "pg":
		run(pgWriter(*dsn), *interval, *duration, *timeout)
	case "read":
		run(pgReader(*dsn), *interval, *duration, *timeout)
	case "kube":
		run(kubeWriter(*url, *tlsDir), *interval, *duration, *timeout)
	case "http":
		run(httpGetter(*url), *interval, *duration, *timeout)
	case "verify":
		verify(*dsn, *acks)
	default:
		fail("unknown mode " + mode)
	}
}

func run(w writer, interval, duration, timeout time.Duration) {
	out := json.NewEncoder(os.Stdout)
	var acked, failed int64
	var last, pauseFrom time.Time
	var pause time.Duration

	for n, end := int64(1), time.Now().Add(duration); time.Now().Before(end); n++ {
		sent := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		err := w(ctx, n)
		cancel()

		r := record{N: n, Sent: sent.UnixNano()}
		if err != nil {
			r.Err = err.Error()
			failed++
		} else {
			now := time.Now()
			r.Ack = now.UnixNano()
			acked++
			if !last.IsZero() && now.Sub(last) > pause {
				pause, pauseFrom = now.Sub(last), last
			}
			last = now
		}
		_ = out.Encode(r)
		time.Sleep(interval)
	}
	fmt.Fprintf(os.Stderr, "acknowledged %d, failed %d, longest pause between acknowledgements %v from %s\n",
		acked, failed, pause, pauseFrom.UTC().Format(time.RFC3339Nano))
}

func pgWriter(dsn string) writer {
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	check(err)
	_, err = conn.Exec(ctx, "DROP TABLE IF EXISTS probe; CREATE TABLE probe (n bigint PRIMARY KEY, at timestamptz NOT NULL DEFAULT now())")
	check(err)

	return pgSession(dsn, conn, func(ctx context.Context, conn *pgx.Conn, n int64) error {
		_, err := conn.Exec(ctx, "INSERT INTO probe (n) VALUES ($1)", n)
		return err
	})
}

func pgReader(dsn string) writer {
	return pgSession(dsn, nil, func(ctx context.Context, conn *pgx.Conn, _ int64) error {
		var newest int64
		return conn.QueryRow(ctx, "SELECT coalesce(max(n), 0) FROM probe").Scan(&newest)
	})
}

func pgSession(dsn string, conn *pgx.Conn, attempt func(context.Context, *pgx.Conn, int64) error) writer {
	return func(ctx context.Context, n int64) error {
		if conn == nil || conn.IsClosed() {
			var err error
			if conn, err = pgx.Connect(ctx, dsn); err != nil {
				conn = nil
				return err
			}
		}
		err := attempt(ctx, conn, n)
		if err != nil {
			_ = conn.Close(context.Background())
			conn = nil
		}
		return err
	}
}

func kubeWriter(url, dir string) writer {
	cert, err := tls.LoadX509KeyPair(dir+"/client-admin.crt", dir+"/client-admin.key")
	check(err)
	ca, err := os.ReadFile(dir + "/server-ca.crt")
	check(err)
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(ca)
	client := &http.Client{Transport: &http.Transport{
		TLSClientConfig: &tls.Config{Certificates: []tls.Certificate{cert}, RootCAs: roots},
	}}

	configMaps := url + "/api/v1/namespaces/default/configmaps"
	send := func(ctx context.Context, method, target string, n int64) (int, error) {
		body := fmt.Sprintf(`{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"probe"},"data":{"n":"%d"}}`, n)
		req, err := http.NewRequestWithContext(ctx, method, target, strings.NewReader(body))
		if err != nil {
			return 0, err
		}
		req.Header.Set("Content-Type", "application/json")
		res, err := client.Do(req)
		if err != nil {
			return 0, err
		}
		_, _ = io.Copy(io.Discard, res.Body)
		res.Body.Close()
		return res.StatusCode, nil
	}

	// Right after a leader move the API can answer 500 for a moment; the run must not die before it starts.
	status, err := 0, error(nil)
	for try := 0; try < 10; try++ {
		if status, err = send(context.Background(), http.MethodPost, configMaps, 0); err == nil && status < 500 {
			break
		}
		time.Sleep(time.Second)
	}
	check(err)
	if status != http.StatusCreated && status != http.StatusConflict {
		fail(fmt.Sprintf("creating the probe ConfigMap: HTTP %d", status))
	}

	return func(ctx context.Context, n int64) error {
		status, err := send(ctx, http.MethodPut, configMaps+"/probe", n)
		if err == nil && status != http.StatusOK {
			err = fmt.Errorf("HTTP %d", status)
		}
		return err
	}
}

func httpGetter(url string) writer {
	client := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}}
	return func(ctx context.Context, _ int64) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return err
		}
		res, err := client.Do(req)
		if err != nil {
			return err
		}
		_, _ = io.Copy(io.Discard, res.Body)
		res.Body.Close()
		if res.StatusCode != http.StatusOK {
			return fmt.Errorf("HTTP %d", res.StatusCode)
		}
		return nil
	}
}

func verify(dsn, acks string) {
	f, err := os.Open(acks)
	check(err)
	defer f.Close()
	acked := map[int64]bool{}
	for scan := bufio.NewScanner(f); scan.Scan(); {
		var r record
		if json.Unmarshal(scan.Bytes(), &r) == nil && r.Ack > 0 {
			acked[r.N] = true
		}
	}

	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	check(err)
	rows, err := conn.Query(ctx, "SELECT n FROM probe")
	check(err)
	present, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	check(err)
	for _, n := range present {
		delete(acked, n)
	}

	lost := make([]int64, 0, len(acked))
	for n := range acked {
		lost = append(lost, n)
	}
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"rows": len(present), "acknowledged_and_lost": lost})
}

func check(err error) {
	if err != nil {
		fail(err.Error())
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(1)
}
