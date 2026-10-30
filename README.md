# High availability on European clouds

Scripts that build the same three-zone K3s cluster on Hetzner, Scaleway and OVHcloud (and AWS, for comparison),
measure it, and break one zone at a time. Every number in the articles comes from these scripts:

1. K3s losing a zone
2. CloudNativePG
3. Replicated volumes with DRBD

K3s keeps its defaults. Articles 2 and 3 add CloudNativePG and Piraeus/DRBD on top.

## What it builds

Three x86 machines with 2 vCPU, one per zone, on a private network. SSH and the Kubernetes API accept only your address.
The round behind article 1 ran in Milan:

| Provider | Zones | Machine | Disk under `/var/lib` |
|---|---|---|---|
| Hetzner | `fsn1`, `nbg1`, `hel1` | `cpx22`, then `ccx13` | local |
| Scaleway | `it-mil-1`, `it-mil-2`, `it-mil-3` | `BASIC3-X2C-4G` | Block Storage, 5000 IOPS |
| OVHcloud | `eu-south-mil-a`, `-b`, `-c` | `c3-4` | local |
| AWS | `eu-south-1a`, `-1b`, `-1c` | `c7i.large` | gp3, 5000 IOPS |

Hetzner has no zones inside a location, so its "zones" are three cities in Germany and Finland.
These are the defaults: Milan on Scaleway, OVHcloud and AWS, `cpx22` on Hetzner.
To change region, zones or type, set them in `infra/<provider>/terraform.tfvars`:

| Folder | Variables | Article 1 values that differ from the default |
|---|---|---|
| `infra/hetzner` | `locations`, `server_type` | `server_type = "ccx13"` for the second run |
| `infra/scaleway` | `region`, `server_types` (zone to type), `disk_iops`, `data_volume_gb` | none |
| `infra/ovh` | `region`, `zones`, `flavor` | none |
| `infra/aws` | `region`, `zones`, `instance_type`, `disk_iops`, `data_volume_gb` | `data_volume_gb = 0` (default 20) |

Every folder also takes `name` (default `ha`, the prefix of every resource), `ssh_public_key_file`
(default `~/.ssh/id_ed25519.pub`) and the required `operator_cidr`.
A `.tfvars` file is ignored by git, and `apply`, `destroy` and `smoke.sh` all read it.

Provider details that shaped the setup:
- OVHcloud gives new projects a security group quota of 0, so the firewall is nftables on each host (`infra/ovh/cloud-init.yaml.tftpl`).
- Scaleway does not sell the same types in every zone of every region, so `infra/scaleway` takes one machine type per zone.
- Hetzner limits primary IPv4 addresses per account: check the project limits before `apply`.
- AWS Milan is an opt-in region: enable it in the account first.

## Requirements

- OpenTofu (Terraform works too), `jq`, `kubectl`, `ssh`, `curl`, `openssl`
- Go 1.25 or newer: `probe/run.sh` builds the probe for linux/amd64 on your machine
- gnuplot for `charts/make.sh`, Node.js for `charts/article1/make.mjs`, plus Chrome or Chromium for its PNG files
- `python3` (standard library only) for `bench/steal.py`
- an SSH key and credentials for the provider

The machines download K3s, `etcdctl`, CloudNativePG and Piraeus from the internet themselves.

Copy `.env.example` to `.env`, fill in the provider you use, and load it with `source env.sh`.
It also finds the Scaleway and OVH project ids from the credentials.

## Smoke check

```bash
./smoke.sh hetzner      # or scaleway, ovh, aws
```

Creates the machines, measures network and disk briefly, installs K3s, partitions the last zone for 20 s while
the probe writes, and destroys the machines at the end, also on error or Ctrl-C. Results go to a folder ending
in `-fast`: not for publishing. `FAST=1` gives the same short measurements to any single script.

## Run

```bash
source env.sh
infra/available.sh hetzner ccx13      # can the type be ordered? (see below)

tofu -chdir=infra/scaleway init
tofu -chdir=infra/scaleway apply -var operator_cidr="$(curl -4 -s https://ifconfig.me)/32"
tofu -chdir=infra/scaleway output -json nodes > nodes.json
rm -f .known_hosts                    # new machines, new host keys

bench/net.sh            # RTT and TCP throughput between zones, private network
bench/disk.sh           # fsync latency of the disk behind /var/lib
01-k3s/install.sh       # three K3s servers with embedded etcd, one per zone, cluster DNS in every zone
```

The first zone in `nodes.json` is the one the probe writes from and is never broken.

`infra/available.sh` checks `fsn1`, `nbg1`, `hel1` on Hetzner, the three Milan zones on Scaleway (`SCW_ZONES` to change them)
and one OVH region (`OVH_REGION`, default `EU-SOUTH-MIL`).

### Article 1: K3s

```bash
01-k3s/addons.sh                # what K3s installed, how many copies, in which zone
REPEAT=3 01-k3s/run.sh          # API write latency per etcd leader zone, then 3 times each fault
REPEAT=3 01-k3s/app.sh          # a stateless app, one replica per zone, each zone lost in turn for 420 s
```

`01-k3s/run.sh` takes steps as arguments: `latency`, `partition-follower`, `partition-leader`, `crash-leader`
(all by default). Before each fault it moves the etcd leader to the third zone, then cuts off a zone for 30 s or resets
the leader's node, while the probe writes for 90 s.

`01-k3s/app.sh` runs `traefik/whoami` behind a Service and sends GET requests to it from another zone. 420 s is
longer than the 300 s Kubernetes waits before it evicts the pods of an unreachable node. A server in another zone
records nodes, endpoints, pods and etcd health every 2 s. `01-k3s/app-report.sh` turns that into a timeline;
`app.sh` calls it at the end of each repetition.

Both scripts call `bench/stats.sh` before and after every step: CPU counters, steal and etcd's own metrics.
`01-k3s/healthy.sh` waits until every etcd member is healthy.

CPU steal at 100 ms resolution, around the latency step:

```bash
bench/sample.sh start
01-k3s/run.sh latency
bench/sample.sh stop
python3 bench/steal.py results/<run>   # writes steal.json there and prints a report
```

### Article 2: CloudNativePG

```bash
02-cnpg/run.sh                                   # every layout: commit latency, then the primary's node resets
FAULT=partition 02-cnpg/run.sh                   # the primary's zone lost for 180 s instead
FAULT=partition OPERATOR_HA=1 REPEAT=3 02-cnpg/run.sh sync   # operator in three copies, three losses
```

Layouts: `single`, `async`, `sync`, `sync-2`, `sync-2-preferred`. `FAULT=none` measures the commit only.

### Article 3: replicated volumes

```bash
03-volumes/run.sh install disk failover postgres
```

The volume group goes on `DEVICE` (default `/dev/sdb`) when that disk exists, otherwise on a 16 GB loop file on
the system disk. `infra/scaleway` and `infra/aws` add that disk with `data_volume_gb`. Set `DEVICE` to its path when
it is not `/dev/sdb`: on AWS it shows up as an NVMe device, check with `lsblk`.

`SINGLE_DNS=1 01-k3s/install.sh` keeps K3s' single copy of the cluster DNS. Losing the zone that holds it stops
a Postgres failover that needs a copy to reconnect by name, and a replicated volume that must reattach elsewhere,
until the zone comes back.

### Two clusters at once

`STATE=<absolute dir>` keeps one cluster's files apart: `nodes.json`, `kubeconfig`, `.known_hosts`, `.k3s-token`.
Without it they live in the repository root. `kubectl` by hand needs `KUBECONFIG=$STATE/kubeconfig`.

```bash
export STATE="$PWD/.state/hetzner" && mkdir -p "$STATE"
tofu -chdir=infra/hetzner output -json nodes > "$STATE/nodes.json"
```

Two clusters on the same provider also need another `name` and their own tofu state (a workspace or a copy of the folder).

Versions can be pinned with `K3S_VERSION`, `ETCD_VERSION`, `CNPG_VERSION`, `PIRAEUS_VERSION`.

## Break a zone by hand

The probe writes without pause from a zone you leave alone and records which writes were acknowledged.

```bash
probe/run.sh <first zone> kube -duration 3m &   # writes to the Kubernetes API of that zone's server
faults/fault.sh partition <zone> 60             # the zone reaches nobody for 60 s, then heals by itself
wait
```

- `faults/fault.sh partition <zone> [seconds]` keeps the machines up but cuts them off; only your SSH passes (default 600 s).
- `faults/fault.sh heal <zone>` ends a partition now.
- `faults/fault.sh crash <zone>` resets the zone's machines instantly, nothing flushed to disk.
- `01-k3s/leader.sh [zone]` shows the zone of the etcd leader, or moves it there first.

The partition lets through SSH from `OPERATOR_IP`, by default the address `ifconfig.me` sees. Set it when that is
not the address your SSH comes from. Probe modes: `kube`, `http`, `pg`, `read`, `verify`; flags `-duration`,
`-interval`, `-timeout`, `-url`, `-dsn`, `-acks`. `LABEL=<name>` names the output file.

## Results and charts

Every script writes to `results/<provider>-<type>-<YYYYMMDD>/` (UTC date, `-fast` with `FAST=1`).
`RUN_DIR=<dir>` picks another folder: the article 1 runs are `results/*-20261030-a1`.

| File | From |
|---|---|
| `net.jsonl`, `disk.jsonl` | `bench/net.sh`, `bench/disk.sh` |
| `probe-<label>.jsonl` | one line per write: sent, acknowledged or error |
| `faults.jsonl` | every fault with its time |
| `cpu-stat.jsonl`, `etcd-metrics.jsonl`, `steal_pct.jsonl` | `bench/stats.sh` |
| `addons.txt`, `addons-pods.jsonl` | `01-k3s/addons.sh` |
| `app-partition-<i>/`, `app-partition-<i>-timeline.jsonl`, `app-partitions.jsonl` | `01-k3s/app.sh` |
| `samples/`, `steal.json` | `bench/sample.sh`, `bench/steal.py` |

```bash
bench/summary.sh results/<run>               # one line per probe run: acknowledged, failed, p50, p99, longest pause
bench/etcd.sh results/<run>                  # etcd WAL fsync and commit percentiles per step
bench/export.sh results/<run>... > all.json  # every folder in one JSON array
charts/make.sh results/<run>...              # SVG charts in charts/out/ (gnuplot)
node charts/article1/make.mjs                # article 1 charts in charts/article1/out/
```

`charts/article1/make.mjs` reads the `*-20261030-a1` folders listed at its top. `RESULTS=<dir>` changes where they
are read from, `OUT=<dir>` where the charts go, `CHROME=<binary>` the browser. The AWS network numbers come from an
earlier run (`results/aws-c7i.large-20261030/net.jsonl`); `AWS_NET=<file>` points elsewhere.

`charts/make.sh` names timelines after the provider, so give it one run per provider.

## Tear down

```bash
tofu -chdir=infra/scaleway destroy -var operator_cidr=0.0.0.0/32
tofu -chdir=infra/scaleway state list        # prints nothing when everything is gone
```

Use the same `.tfvars` as for `apply`. `operator_cidr` is required but its value does not matter here.
Run it in every folder you applied, and check the provider's console for anything left.

## License

MIT, for the scripts and the results. See `LICENSE`.
