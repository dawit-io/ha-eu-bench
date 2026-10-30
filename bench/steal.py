#!/usr/bin/env python3
"""Do slow API writes line up with CPU steal or with the disk under etcd?

Joins every probe write (probe-<step>-leader-<zone>.jsonl) with the 100 ms CPU and disk samples and the 1 s etcd
histograms of bench/sample.sh. A write's window is every sample interval that overlaps it, from sent to ack.
A spike is a value above the 95th percentile of that node's intervals during the probe runs (steal: at least 10 %).
Usage: bench/steal.py results/<run>   writes steal.json there and prints a short report
"""
import bisect
import glob
import json
import os
import re
import statistics
import sys

RUN = sys.argv[1]
NODES = json.load(open(os.path.join(RUN, "nodes.json")))
ZONES = [n["zone"] for n in NODES]
WRITER = ZONES[0]


def pct(values, q):
    v = sorted(values)
    return v[min(len(v) - 1, int(q * len(v)))] if v else None


def median(values):
    return statistics.median(values) if values else None


def mean(values):
    return sum(values) / len(values) if values else None


def ranks(values):
    order = sorted(range(len(values)), key=lambda i: values[i])
    r = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        for k in range(i, j + 1):
            r[order[k]] = (i + j) / 2
        i = j + 1
    return r


def spearman(x, y):
    pairs = [(a, b) for a, b in zip(x, y) if a is not None and b is not None]
    if len(pairs) < 3:
        return None
    rx, ry = ranks([p[0] for p in pairs]), ranks([p[1] for p in pairs])
    mx, my = mean(rx), mean(ry)
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    den = (sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry)) ** 0.5
    return num / den if den else None


def load_cpu(zone):
    t, rows = [], []
    for line in open(os.path.join(RUN, "samples", zone + ".cpu")):
        head, _, disk = line.partition("|")
        f = head.split()
        d = [int(x) for x in disk.split()]
        if len(f) < 9 or len(d) < 11:
            continue
        t.append(int(float(f[0]) * 1e9))
        rows.append([int(x) for x in f[1:9]] + d)
    iv = []
    for i in range(1, len(rows)):
        a, b = rows[i - 1], rows[i]
        c = [b[k] - a[k] for k in range(8)]
        total = sum(c)
        dk = [b[k] - a[k] for k in range(8, len(b))]
        writes, ms_writing = dk[4], dk[7]
        iv.append({
            "steal": 100 * c[7] / total if total else None,
            "iowait": 100 * c[4] / total if total else None,
            "busy": 100 * (c[0] + c[1] + c[2] + c[5] + c[6]) / total if total else None,
            "steal_share": 100 * c[7] / (c[7] + c[0] + c[1] + c[2] + c[5] + c[6]) if c[7] + c[0] + c[1] + c[2] else None,
            "disk_w_ms": ms_writing / writes if writes else None,
            "inflight": b[8 + 8],
            "writes": writes,
        })
    return t, iv


def load_disk(zone):
    path = os.path.join(RUN, "samples", zone + ".disk")
    t, rows = [], []
    if os.path.exists(path):
        for line in open(path):
            head, _, disk = line.partition("|")
            d = [int(x) for x in disk.split()]
            if len(d) >= 17:
                t.append(int(float(head) * 1e9))
                rows.append(d)
    iv = []
    for i in range(1, len(rows)):
        dk = [rows[i][k] - rows[i - 1][k] for k in range(17)]
        iv.append({
            "flush_ms": dk[16] / dk[15] if dk[15] else None,
            "flushes": dk[15],
            "whole_w_ms": dk[7] / dk[4] if dk[4] else None,
            "whole_inflight": rows[i][8],
        })
    return t, iv


def load_etcd(zone):
    names = open(os.path.join(RUN, "samples", zone + ".names")).read().split()
    t, rows = [], []
    for line in open(os.path.join(RUN, "samples", zone + ".etcd")):
        f = line.split()
        if len(f) != len(names) + 1:
            continue
        t.append(int(float(f[0]) * 1e9))
        rows.append(dict(zip(names, (float(x) for x in f[1:]))))

    def over(row, family, le):
        return row[family + "_count"] - row['%s_bucket{le="%s"}' % (family, le)]

    wal, commit = "etcd_disk_wal_fsync_duration_seconds", "etcd_disk_backend_commit_duration_seconds"
    iv = []
    for i in range(1, len(rows)):
        a, b = rows[i - 1], rows[i]
        n = b[wal + "_count"] - a[wal + "_count"]
        if n < 0:
            iv.append({})
            continue
        iv.append({
            "fsyncs": n,
            "fsync_mean_ms": 1000 * (b[wal + "_sum"] - a[wal + "_sum"]) / n if n else None,
            "fsync_over_8ms": over(b, wal, "0.008") - over(a, wal, "0.008"),
            "fsync_over_16ms": over(b, wal, "0.016") - over(a, wal, "0.016"),
            "commit_over_16ms": over(b, commit, "0.016") - over(a, commit, "0.016"),
            "commit_over_32ms": over(b, commit, "0.032") - over(a, commit, "0.032"),
            "leader": b.get("etcd_server_is_leader", 0) == 1,
        })
    return t, iv


def covering(t, sent, ack):
    lo = max(1, bisect.bisect_right(t, sent))
    hi = min(len(t) - 1, bisect.bisect_left(t, ack))
    return [i - 1 for i in range(lo, hi + 1)]


def window(series, sent, ack, key, agg=max):
    t, iv = series
    vals = [iv[i].get(key) for i in covering(t, sent, ack)]
    vals = [v for v in vals if v is not None]
    return agg(vals) if vals else None


def per_second(series):
    t, iv = series
    out_t, out = [], []
    start = t[0] if t else 0
    bucket = []
    for i, x in enumerate(iv):
        if t[i + 1] - start >= 1e9 and bucket:
            out_t.append(start)
            out.append(bucket)
            start, bucket = t[i], []
        bucket.append(x)
    out_t.append(start)
    out.append(bucket)
    secs = []
    for b in out:
        st = [x["steal"] for x in b if x["steal"] is not None]
        io = [x["iowait"] for x in b if x["iowait"] is not None]
        w = sum(x["writes"] for x in b)
        dl = [x["disk_w_ms"] * x["writes"] for x in b if x["disk_w_ms"] is not None]
        secs.append({"steal": mean(st), "iowait": mean(io), "disk_w_ms": sum(dl) / w if w else None,
                     "steal_peak": max(st) if st else None})
    out_t.append(t[-1] if t else 0)
    return out_t, secs


cpu = {z: load_cpu(z) for z in ZONES}
disk = {z: load_disk(z) for z in ZONES}
etcd = {z: load_etcd(z) for z in ZONES}
cpu1s = {z: per_second(cpu[z]) for z in ZONES}

writes = []
for path in sorted(glob.glob(os.path.join(RUN, "probe-*-leader-*.jsonl"))):
    m = re.match(r"probe-(\w+?)-leader-(.+)\.jsonl", os.path.basename(path))
    step, leader = m.group(1), m.group(2)
    for line in open(path):
        r = json.loads(line)
        if r.get("ack"):
            writes.append({"step": step, "load": step[0], "leader": leader, "sent": r["sent"], "ack": r["ack"],
                           "ms": (r["ack"] - r["sent"]) / 1e6})

lat = [w["ms"] for w in writes]
p99, p999 = pct(lat, 0.99), pct(lat, 0.999)
runs = [(min(w["sent"] for w in writes if w["step"] == s and w["leader"] == l),
         max(w["ack"] for w in writes if w["step"] == s and w["leader"] == l))
        for s, l in {(w["step"], w["leader"]) for w in writes}]


def in_runs(t0):
    return any(a <= t0 <= b for a, b in runs)


def thresholds(series, keys, floor):
    t, iv = series
    if not iv:
        return {k: float("inf") for k in keys}
    th = {}
    for k in keys:
        vals = [iv[i][k] for i in range(len(iv)) if in_runs(t[i + 1]) and iv[i].get(k) is not None]
        th[k] = max(pct(vals, 0.95) or 0, floor.get(k, 0))
    return th


keys100 = ["steal", "iowait", "disk_w_ms"]
keys_disk = ["flush_ms", "whole_w_ms"]
th100 = {z: thresholds(cpu[z], keys100, {"steal": 10}) | thresholds(disk[z], keys_disk, {}) for z in ZONES}
th1s = {z: thresholds(cpu1s[z], ["steal", "disk_w_ms"], {"steal": 5}) for z in ZONES}

for w in writes:
    s, a = w["sent"], w["ack"]
    for role, z in (("leader", w["leader"]), ("probe", WRITER)):
        for k in keys100 + ["busy", "steal_share", "inflight"]:
            w[f"{role}_{k}"] = window(cpu[z], s, a, k)
        for k in keys_disk + ["flushes"]:
            w[f"{role}_{k}"] = window(disk[z], s, a, k)
        for k in ("steal", "disk_w_ms", "steal_peak"):
            w[f"{role}_1s_{k}"] = window(cpu1s[z], s, a, k)
        for k in ("fsync_over_8ms", "fsync_over_16ms", "commit_over_16ms", "fsync_mean_ms"):
            w[f"{role}_etcd_{k}"] = window(etcd[z], s, a, k)
    w["probe_steal_spike"] = (w["probe_steal"] or 0) > th100[WRITER]["steal"]
    w["probe_disk_spike"] = ((w["probe_disk_w_ms"] or 0) > th100[WRITER]["disk_w_ms"]
                             or (w["probe_flush_ms"] or 0) > th100[WRITER]["flush_ms"])
    w["any_steal_spike"] = any((window(cpu[z], s, a, "steal") or 0) > th100[z]["steal"] for z in ZONES)
    w["any_disk_spike"] = any((window(cpu[z], s, a, "disk_w_ms") or 0) > th100[z]["disk_w_ms"]
                              or (window(disk[z], s, a, "flush_ms") or 0) > th100[z]["flush_ms"] for z in ZONES)
    w["any_fsync_slow_1s"] = any((window(etcd[z], s, a, "fsync_over_16ms") or 0) > 0
                                 or (window(etcd[z], s, a, "commit_over_32ms") or 0) > 0 for z in ZONES)
    w["any_steal_spike_1s"] = any((window(cpu1s[z], s, a, "steal") or 0) > th1s[z]["steal"] for z in ZONES)
    w["any_disk_spike_1s"] = any((window(cpu1s[z], s, a, "disk_w_ms") or 0) > th1s[z]["disk_w_ms"] for z in ZONES)


def compare(group, rest, fields):
    out = {}
    for f in fields:
        g = [w[f] for w in group if w[f] is not None]
        r = [w[f] for w in rest if w[f] is not None]
        out[f] = {"slow_median": median(g), "slow_mean": mean(g), "other_median": median(r), "other_mean": mean(r)}
    return out


def attribution(group, steal_key, disk_keys):
    c = {"steal_only": 0, "disk_only": 0, "both": 0, "neither": 0}
    for w in group:
        st, dk = w[steal_key], any(w[k] for k in disk_keys)
        c["both" if st and dk else "steal_only" if st else "disk_only" if dk else "neither"] += 1
    n = len(group)
    return {"n": n, **c, **{k + "_pct": round(100 * v / n, 1) for k, v in c.items()}} if n else {"n": 0}


fields100 = [f"{r}_{k}" for r in ("leader", "probe") for k in keys100 + ["busy", "steal_share", "inflight"] + keys_disk + ["flushes"]]
fields1s = [f"{r}_{k}" for r in ("leader", "probe") for k in
            ("1s_steal", "1s_steal_peak", "1s_disk_w_ms", "etcd_fsync_over_8ms", "etcd_fsync_over_16ms",
             "etcd_commit_over_16ms", "etcd_fsync_mean_ms")]

report = {"writes": len(writes), "p50_ms": pct(lat, 0.5), "p99_ms": p99, "p999_ms": p999, "max_ms": max(lat),
          "thresholds_100ms": th100, "thresholds_1s": th1s, "by_step": {}, "tails": {}}

for load in ("A", "B"):
    for leader in ZONES:
        sel = [w["ms"] for w in writes if w["load"] == load and w["leader"] == leader]
        if sel:
            report["by_step"][f"{load} leader {leader}"] = {
                "writes": len(sel), "p50_ms": pct(sel, 0.5), "p99_ms": pct(sel, 0.99), "p999_ms": pct(sel, 0.999),
                "max_ms": max(sel)}

for name, cut in (("p99", p99), ("p999", p999)):
    slow = [w for w in writes if w["ms"] > cut]
    rest = [w for w in writes if w["ms"] <= cut]
    report["tails"][name] = {
        "cut_ms": cut, "slow_writes": len(slow),
        "slow_by_load": {l: sum(1 for w in slow if w["load"] == l) for l in ("A", "B")},
        "compare_100ms": compare(slow, rest, fields100),
        "compare_1s": compare(slow, rest, fields1s),
        "attribution_100ms": {"slow": attribution(slow, "any_steal_spike", ["any_disk_spike"]),
                              "other": attribution(rest, "any_steal_spike", ["any_disk_spike"])},
        "attribution_1s": {"slow": attribution(slow, "any_steal_spike_1s", ["any_disk_spike_1s", "any_fsync_slow_1s"]),
                           "other": attribution(rest, "any_steal_spike_1s", ["any_disk_spike_1s", "any_fsync_slow_1s"])},
    }

def risk(cut, steal_key, disk_key):
    out = {}
    for name, st, dk in (("steal_only", True, False), ("disk_only", False, True), ("both", True, True),
                         ("neither", False, False)):
        sel = [w for w in writes if w[steal_key] == st and w[disk_key] == dk]
        slow = sum(1 for w in sel if w["ms"] > cut)
        out[name] = {"writes": len(sel), "slow": slow, "slow_pct": round(100 * slow / len(sel), 3) if sel else None}
    return out


report["risk"] = {f"{name} {scope}": risk(cut, *keys) for name, cut in (("p99", p99), ("p999", p999), ("over_100ms", 100))
                  for scope, keys in (("probe node", ("probe_steal_spike", "probe_disk_spike")),
                                      ("any node", ("any_steal_spike", "any_disk_spike")))}

report["spearman_latency_vs"] = {f: spearman(lat, [w[f] for w in writes]) for f in fields100 + fields1s}
report["slowest"] = [{k: (round(v, 2) if isinstance(v, float) else v) for k, v in w.items()
                      if k not in ("sent", "ack")} | {"sent": w["sent"]}
                     for w in sorted(writes, key=lambda w: -w["ms"])[:15]]

report["steal_during_runs"] = {}
for z in ZONES:
    for load in ("A", "B"):
        t, iv = cpu[z]
        spans = [(min(w["sent"] for w in writes if w["step"] == s and w["leader"] == l),
                  max(w["ack"] for w in writes if w["step"] == s and w["leader"] == l))
                 for s, l in {(w["step"], w["leader"]) for w in writes if w["load"] == load}]
        st = [x["steal"] for i, x in enumerate(iv) if x["steal"] is not None and any(a <= t[i + 1] <= b for a, b in spans)]
        report["steal_during_runs"][f"{z} {load}"] = {"mean": mean(st), "median": median(st), "p95": pct(st, 0.95),
                                                     "share_over_10pct": mean([x > 10 for x in st])}
UNITS = {"ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1}
report["clock_offset_s"] = {z: [float(x) * UNITS[u] for x, u in re.findall(
    r"Offset:\s*([+-]?[\d.]+)(ns|us|ms|s)\b", open(os.path.join(RUN, "samples", z + ".clock")).read())]
    for z in ZONES}

json.dump(report, open(os.path.join(RUN, "steal.json"), "w"), indent=1, default=str)


def show(x):
    return "-" if x is None else f"{x:.2f}"


print(f"writes {len(writes)}  p50 {show(report['p50_ms'])} ms  p99 {show(p99)} ms  p99.9 {show(p999)} ms  max {show(max(lat))} ms")
for k, v in report["by_step"].items():
    print(f"  {k}: n {v['writes']} p50 {show(v['p50_ms'])} p99 {show(v['p99_ms'])} p99.9 {show(v['p999_ms'])} max {show(v['max_ms'])}")
for name, t in report["tails"].items():
    print(f"\n> {name} ({show(t['cut_ms'])} ms): {t['slow_writes']} slow writes, by load {t['slow_by_load']}")
    for f, c in list(t["compare_100ms"].items()) + list(t["compare_1s"].items()):
        print(f"  {f:32s} slow median {show(c['slow_median']):>8} mean {show(c['slow_mean']):>8} | "
              f"other median {show(c['other_median']):>8} mean {show(c['other_mean']):>8}")
    for g in ("attribution_100ms", "attribution_1s"):
        print(f"  {g}: slow {t[g]['slow']}\n  {' ' * len(g)}  other {t[g]['other']}")
print("\nshare of writes that are slow, by what their 100 ms window holds:")
for k, v in report["risk"].items():
    print(f"  {k:22s} " + "  ".join(f"{c} {x['slow']}/{x['writes']} ({x['slow_pct']}%)" for c, x in v.items()))
print("\nspearman(latency, x):")
for f, r in report["spearman_latency_vs"].items():
    print(f"  {f:32s} {show(r)}")
