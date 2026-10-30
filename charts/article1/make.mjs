#!/usr/bin/env node
// Charts for article 1, from the a1 result folders: SVG, and PNG at 2x when Chrome or Chromium is found.
// Usage: node charts/article1/make.mjs
// OUT=<dir> changes where the charts go (default charts/article1/out), RESULTS=<dir> where the runs are read from,
// AWS_NET=<net.jsonl> where the AWS network numbers are (they come from an earlier run), CHROME=<binary> the browser.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const results = process.env.RESULTS || join(root, 'results');
const out = resolve(process.env.OUT || join(here, 'out'));
const awsNet = process.env.AWS_NET || join(results, 'aws-c7i.large-20261030/net.jsonl');

const milan = [
  { name: 'AWS', run: 'aws-c7i.large-20261030-a1', color: '#E69F00' },
  { name: 'OVHcloud', run: 'ovh-milan-c3-4-20261030-a1', color: '#56B4E9' },
  { name: 'Scaleway', run: 'scaleway-milan-BASIC3-X2C-4G-20261030-a1', color: '#CC79A7' },
];
// #F0E442, the Hetzner yellow of the animation, is too light on white: same hue, darker.
const hetzner = [
  { name: 'cpx22', run: 'hetzner-cpx22-20261030-a1', color: '#A09600' },
  { name: 'ccx13', run: 'hetzner-ccx13-20261030-a1', color: '#A09600' },
];

const ink = '#1F2328';
const muted = '#57606A';
const grid = '#E3E6EA';
const font = "'Helvetica Neue', Helvetica, Arial, sans-serif";
const W = 1200;
const size = { label: 28, tick: 24, panel: 26 };

const jsonl = (file) =>
  readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
const runFile = (p, f) => join(results, p.run, f);

function probe(file) {
  const rows = jsonl(file);
  const ok = rows.filter((r) => r.ack);
  const lat = ok.map((r) => (r.ack - r.sent) / 1e6).sort((a, b) => a - b);
  const ends = [...ok.map((r) => r.ack), Math.max(...rows.map((r) => r.sent))].sort((a, b) => a - b);
  let pause = 0;
  for (let i = 1; i < ends.length; i++) pause = Math.max(pause, (ends[i] - ends[i - 1]) / 1e9);
  return { p50: lat[Math.floor(lat.length * 0.5)], p99: lat[Math.floor(lat.length * 0.99)], pause };
}

function histQuantile(buckets, q) {
  const rank = q * buckets[buckets.length - 1].count;
  let prevCount = 0;
  let prevLe = 0;
  for (const b of buckets) {
    const le = b.le === '+Inf' ? Infinity : Number(b.le);
    if (b.count >= rank) return le === Infinity ? prevLe * 1000 : (prevLe + ((le - prevLe) * (rank - prevCount)) / (b.count - prevCount)) * 1000;
    prevCount = b.count;
    prevLe = le;
  }
}

function walFsync(p, q) {
  const rows = jsonl(runFile(p, 'etcd-metrics.jsonl')).filter((r) => r.wal_fsync);
  let sum = null;
  for (const after of rows.filter((r) => r.phase === 'after')) {
    const before = rows.find((r) => r.phase === 'before' && r.step === after.step && r.zone === after.zone);
    if (!before) continue;
    let d = after.wal_fsync.buckets.map((b, i) => ({ le: b.le, count: b.count - before.wal_fsync.buckets[i].count }));
    // A crashed node starts its counters again, so its whole sample after the step belongs to the step.
    if (d.some((b) => b.count < 0)) d = after.wal_fsync.buckets;
    sum = sum ? sum.map((b, i) => ({ le: b.le, count: b.count + d[i].count })) : d.map((b) => ({ ...b }));
  }
  return histQuantile(sum, q);
}

const zoneShort = (z) => z.replace(/^eu-south-(mil-)?|^it-mil-/, '');
const cityShort = (z) => z.replace(/\d+$/, '').toUpperCase();
const byZone = (a, b) => a.localeCompare(b);

const linear = (d0, d1, r0, r1) => (v) => r0 + ((v - d0) / (d1 - d0)) * (r1 - r0);
const logScale = (d0, d1, r0, r1) => (v) => r0 + ((Math.log(v) - Math.log(d0)) / (Math.log(d1) - Math.log(d0))) * (r1 - r0);
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
const num = (v) => Number(v.toFixed(2));

function text(x, y, s, o = {}) {
  return `<text x="${num(x)}" y="${num(y)}" font-size="${o.size || size.label}" fill="${o.fill || ink}"${
    o.anchor ? ` text-anchor="${o.anchor}"` : ''
  }${o.weight ? ` font-weight="${o.weight}"` : ''} dominant-baseline="central">${esc(s)}</text>`;
}
const line = (x1, y1, x2, y2, stroke, w = 1) =>
  `<line x1="${num(x1)}" y1="${num(y1)}" x2="${num(x2)}" y2="${num(y2)}" stroke="${stroke}" stroke-width="${w}" stroke-linecap="round"/>`;
const dot = (x, y, color) => `<circle cx="${num(x)}" cy="${num(y)}" r="9" fill="${color}" stroke="#ffffff" stroke-width="2"/>`;
const ring = (x, y, color) => `<circle cx="${num(x)}" cy="${num(y)}" r="7.5" fill="#ffffff" stroke="${color}" stroke-width="3.5"/>`;

function bar(x0, x1, y, color, h = 22) {
  const r = Math.min(4, (x1 - x0) / 2);
  const t = y - h / 2;
  return `<path d="M${num(x0)},${num(t)} H${num(x1 - r)} Q${num(x1)},${num(t)} ${num(x1)},${num(t + r)} V${num(t + h - r)} Q${num(x1)},${num(t + h)} ${num(x1 - r)},${num(t + h)} H${num(x0)} Z" fill="${color}"/>`;
}

function legend(y, items) {
  let x = W - 32;
  const parts = [];
  for (const [mark, label] of [...items].reverse()) {
    parts.push(text(x, y, label, { size: size.tick, fill: muted, anchor: 'end' }));
    x -= label.length * size.tick * 0.56 + 20;
    parts.push(mark === 'dot' ? dot(x, y, muted) : ring(x, y, muted));
    x -= 36;
  }
  return parts.join('');
}

// One panel of labelled rows over a shared value axis. Rows come in groups; each group label is
// written once, centred on its rows, and each row may carry its own short label.
function panel(top, o) {
  const rowH = o.rowH || 46;
  const gap = o.groupGap ?? 18;
  const x0 = o.x0;
  const x1 = W - 48;
  const parts = [];
  let y = top;
  if (o.title) {
    parts.push(text(24, y + 16, o.title, { size: size.panel, weight: 600, fill: ink }));
    y += 52;
  }
  const plotTop = y;
  const rows = [];
  o.groups.forEach((g, gi) => {
    if (gi) y += gap;
    const first = y;
    for (const r of g.rows) {
      rows.push({ ...r, y: y + rowH / 2, group: g });
      y += r.height || rowH;
    }
    g.mid = (first + y) / 2;
  });
  const plotBottom = y;
  const x = (o.log ? logScale : linear)(o.domain[0], o.domain[1], x0, x1);
  for (const t of o.ticks) parts.push(line(x(t), plotTop - 6, x(t), plotBottom + 6, grid));
  for (const r of o.refs || []) parts.push(line(x(r), plotTop - 6, x(r), plotBottom + 6, '#C9CED4', 1.5));
  for (const g of o.groups) {
    parts.push(text(24, g.mid, g.label, { size: size.label, fill: ink }));
  }
  for (const r of rows) {
    if (r.label) parts.push(text(o.x0 - 28, r.y, r.label, { size: size.tick, fill: muted, anchor: 'end' }));
    parts.push(o.draw(r, x));
  }
  const axisY = plotBottom + 30;
  for (const t of [...o.ticks, ...(o.refs || [])]) {
    parts.push(text(x(t), axisY, o.fmt ? o.fmt(t) : String(t), { size: size.tick, fill: muted, anchor: 'middle' }));
  }
  if (o.unit) parts.push(text(x1, axisY + 36, o.unit, { size: size.tick, fill: muted, anchor: 'end' }));
  return { svg: parts.join(''), bottom: axisY + (o.unit ? 60 : 26), x };
}

function document(name, height, body) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${Math.ceil(height)}" viewBox="0 0 ${W} ${Math.ceil(
    height,
  )}" font-family="${font}"><rect width="100%" height="100%" fill="#ffffff"/>${body}</svg>\n`;
  const file = join(out, `${name}.svg`);
  writeFileSync(file, svg);
  png(file, Math.ceil(height));
  console.log(file);
}

const chrome = [
  process.env.CHROME,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  ...['google-chrome', 'chromium', 'chromium-browser'].map((b) => {
    try {
      return execFileSync('which', [b], { encoding: 'utf8' }).trim();
    } catch {
      return null;
    }
  }),
].find((b) => b && existsSync(b));

function png(svgFile, height) {
  if (!chrome) return;
  execFileSync(
    chrome,
    [
      '--headless',
      '--disable-gpu',
      '--hide-scrollbars',
      '--force-device-scale-factor=2',
      '--default-background-color=ffffffff',
      `--window-size=${W},${height}`,
      `--screenshot=${svgFile.replace(/\.svg$/, '.png')}`,
      `file://${svgFile}`,
    ],
    { stdio: 'ignore' },
  );
}

function pauses() {
  const faults = [
    ['leader zone isolated', 'partition-leader'],
    ['leader crash', 'crash-leader'],
    ['zone without leader', 'partition-follower'],
  ];
  const groupsFor = (prefix) =>
    milan.map((p) => {
      const values = [1, 2, 3].map((i) => probe(runFile(p, `probe-${prefix}-${i}.jsonl`)).pause);
      return { label: p.name, rows: [{ p, values, height: 62 }] };
    });
  let top = 24;
  const parts = [];
  faults.forEach(([title, prefix], i) => {
    const last = i === faults.length - 1;
    const pnl = panel(top, {
      title,
      x0: 210,
      rowH: 62,
      groupGap: 0,
      domain: [0, 11],
      ticks: [0, 2, 4],
      refs: [6.1, 8.1, 10.1],
      unit: last ? 's' : null,
      groups: groupsFor(prefix),
      draw: (r, x) => {
        const stacks = [];
        for (const v of [...r.values].sort((a, b) => a - b)) {
          const last = stacks[stacks.length - 1];
          if (last && x(v) - x(last[0]) < 18) last.push(v);
          else stacks.push([v]);
        }
        return stacks
          .flatMap((vs) => vs.map((v, j) => dot(x(vs[0]), r.y + (j - (vs.length - 1) / 2) * 17, r.p.color)))
          .join('');
      },
    });
    parts.push(pnl.svg);
    top = pnl.bottom + 20;
  });
  document('1-write-pause', top, parts.join(''));
}

function apiLatency() {
  const groups = milan.map((p) => ({
    label: p.name,
    rows: [...new Set(jsonl(runFile(p, 'disk.jsonl')).map((d) => d.zone))]
      .sort(byZone)
      .map((z) => ({ label: zoneShort(z), p, ...probe(runFile(p, `probe-latency-leader-${z}.jsonl`)) })),
  }));
  const pnl = panel(84, {
    x0: 300,
    domain: [2, 120],
    log: true,
    ticks: [2, 5, 10, 20, 50, 100],
    unit: 'ms, log scale',
    groups,
    draw: (r, x) => line(x(r.p50), r.y, x(r.p99), r.y, r.p.color, 3) + ring(x(r.p99), r.y, r.p.color) + dot(x(r.p50), r.y, r.p.color),
  });
  document('2-api-write-latency', pnl.bottom + 12, legend(40, [['dot', 'p50'], ['ring', 'p99']]) + pnl.svg);
}

function disk() {
  const fio = panel(84, {
    title: 'fio fsync',
    x0: 300,
    domain: [0, 13],
    ticks: [0, 2, 4, 6, 8, 10, 12],
    groups: milan.map((p) => ({
      label: p.name,
      rows: jsonl(runFile(p, 'disk.jsonl'))
        .sort((a, b) => byZone(a.zone, b.zone))
        .map((d) => ({ label: zoneShort(d.zone), p, p50: d.fsync_p50_ms, p99: d.fsync_p99_ms })),
    })),
    draw: (r, x) => line(x(r.p50), r.y, x(r.p99), r.y, r.p.color, 3) + ring(x(r.p99), r.y, r.p.color) + dot(x(r.p50), r.y, r.p.color),
  });
  const wal = panel(fio.bottom + 28, {
    title: 'etcd WAL fsync',
    x0: 300,
    domain: [0, 13],
    ticks: [0, 2, 4, 6, 8, 10, 12],
    unit: 'ms',
    groupGap: 0,
    groups: milan.map((p) => ({ label: p.name, rows: [{ p, p99: walFsync(p, 0.99) }] })),
    draw: (r, x) => ring(x(r.p99), r.y, r.p.color),
  });
  document('3-disk-fsync', wal.bottom + 12, legend(40, [['dot', 'p50'], ['ring', 'p99']]) + fio.svg + wal.svg);
}

function traefikBack(p, run) {
  const events = jsonl(runFile(p, `${run}-timeline.jsonl`));
  const start = events.find((e) => e.event === 'partition').at;
  const down = events.find((e) => e.event === 'traefik' && e.at >= start - 2 && !['200', '404'].includes(e.value));
  const back = down && events.find((e) => e.event === 'traefik' && e.at > down.at && ['200', '404'].includes(e.value));
  return back ? back.at - start : null;
}

function appTimeline() {
  const runs = milan.flatMap((p) => jsonl(runFile(p, 'app-partitions.jsonl')).map((r) => ({ ...r, traefik_back_s: traefikBack(p, r.run) })));
  const span = (k) => {
    const v = runs.map((r) => r[k]).filter((x) => x != null);
    return [Math.min(...v), Math.max(...v)];
  };
  const heal = Math.floor(span('partition_seconds')[0]);
  const lanes = [
    { label: 'requests failing', from: 0, span: span('endpoint_removed_s') },
    { label: 'replica evicted', span: span('evicted_s') },
    { label: 'Traefik unreachable', from: 0, span: span('traefik_back_s') },
    { label: 'metrics-server unreachable', from: 0, span: span('metrics_server_back_s') },
  ];
  const x0 = 32;
  const x1 = W - 48;
  const x = linear(0, 440, x0, x1);
  const solid = '#4B5563';
  const band = '#C3C9D1';
  const parts = [];
  const top = 80;
  const laneH = 104;
  const bottom = top + lanes.length * laneH;
  for (const t of [0, 60, 120, 180, 240, 300, 360]) parts.push(line(x(t), top - 10, x(t), bottom, grid));
  parts.push(line(x(heal), top - 34, x(heal), bottom, ink, 2));
  parts.push(text(x(heal) - 12, top - 40, 'zone back', { size: size.tick, fill: ink, anchor: 'end' }));
  lanes.forEach((l, i) => {
    const y = top + i * laneH;
    parts.push(text(x0, y + 22, l.label, { size: size.label, fill: ink }));
    const by = y + 66;
    const [a, b] = l.span;
    parts.push(`<rect x="${num(x(a))}" y="${by - 11}" width="${num(x(b) - x(a))}" height="22" rx="4" fill="${band}"/>`);
    if (l.from != null) parts.push(`<rect x="${num(x(l.from))}" y="${by - 11}" width="${num(x(a) - x(l.from))}" height="22" rx="4" fill="${solid}"/>`);
    const label = `${Math.round(a)}–${Math.round(b)} s`;
    const after = x(b) + 14;
    const fits = after + label.length * size.tick * 0.56 < x(heal) - 10;
    parts.push(fits ? text(after, by, label, { size: size.tick, fill: muted }) : text(x(b), y + 22, label, { size: size.tick, fill: muted, anchor: 'end' }));
  });
  const axisY = bottom + 30;
  for (const t of [0, 60, 120, 180, 240, 300, 360, heal]) {
    parts.push(text(x(t), axisY, String(t), { size: size.tick, fill: muted, anchor: 'middle' }));
  }
  parts.push(text(x1, axisY + 36, 's after partition', { size: size.tick, fill: muted, anchor: 'end' }));
  document('4-app-zone-loss', axisY + 72, parts.join(''));
}

function hetznerChart() {
  const fsync = panel(24, {
    title: 'fio fsync p50',
    x0: 300,
    domain: [0, 1.4],
    ticks: [0, 0.5, 1],
    unit: 'ms',
    groups: hetzner.map((p) => ({
      label: p.name,
      rows: jsonl(runFile(p, 'disk.jsonl'))
        .sort((a, b) => cityOrder(a.zone) - cityOrder(b.zone))
        .map((d) => ({ label: cityShort(d.zone), p, v: d.fsync_p50_ms })),
    })),
    draw: (r, x) => dot(x(r.v), r.y, r.p.color),
  });
  const bw = panel(fsync.bottom + 28, {
    title: 'FSN–NBG, one stream',
    x0: 300,
    domain: [0, 8],
    ticks: [0, 2, 4, 6, 8],
    unit: 'Gbit/s',
    groupGap: 0,
    groups: hetzner.map((p) => ({
      label: p.name,
      rows: [{ p, v: jsonl(runFile(p, 'net.jsonl')).find((n) => n.from === 'fsn1' && n.to === 'nbg1').tcp_1_stream.sustained_gbps }],
    })),
    draw: (r, x) => bar(x(0), x(r.v), r.y, r.p.color),
  });
  const api = panel(bw.bottom + 28, {
    title: 'API write, by leader city',
    x0: 300,
    domain: [0, 85],
    ticks: [0, 20, 40, 60, 80],
    unit: 'ms',
    groups: hetzner.map((p) => ({
      label: p.name,
      rows: ['fsn1', 'nbg1', 'hel1'].map((z) => ({ label: cityShort(z), p, ...probe(runFile(p, `probe-latency-leader-${z}.jsonl`)) })),
    })),
    draw: (r, x) => line(x(r.p50), r.y, x(r.p99), r.y, r.p.color, 3) + ring(x(r.p99), r.y, r.p.color) + dot(x(r.p50), r.y, r.p.color),
  });
  document('5-hetzner', api.bottom + 12, legend(bw.bottom + 44, [['dot', 'p50'], ['ring', 'p99']]) + fsync.svg + bw.svg + api.svg);
}

const cityOrder = (z) => ['fsn1', 'nbg1', 'hel1'].indexOf(z);

function network() {
  const net = (p) => (p.name === 'AWS' ? jsonl(awsNet) : jsonl(runFile(p, 'net.jsonl')));
  const groups = (pick) =>
    milan.map((p) => ({
      label: p.name,
      rows: net(p)
        .sort((a, b) => byZone(a.from + a.to, b.from + b.to))
        .map((n) => ({ label: `${zoneShort(n.from)}–${zoneShort(n.to)}`, p, v: pick(n) })),
    }));
  const rtt = panel(24, {
    title: 'round trip, p50',
    x0: 300,
    domain: [0, 1.6],
    ticks: [0, 0.4, 0.8, 1.2, 1.6],
    unit: 'ms',
    groups: groups((n) => Number(n.p50_ms)),
    draw: (r, x) => dot(x(r.v), r.y, r.p.color),
  });
  const bw = panel(rtt.bottom + 28, {
    title: 'one stream',
    x0: 300,
    domain: [0, 5.5],
    ticks: [0, 1, 2, 3, 4, 5],
    unit: 'Gbit/s',
    groups: groups((n) => n.tcp_1_stream.sustained_gbps),
    draw: (r, x) => bar(x(0), x(r.v), r.y, r.p.color),
  });
  document('6-network', bw.bottom + 12, rtt.svg + bw.svg);
}

mkdirSync(out, { recursive: true });
if (!chrome) console.error('no Chrome or Chromium found (set CHROME): SVG only');
pauses();
apiLatency();
disk();
appTimeline();
hetznerChart();
if (existsSync(awsNet)) network();
else console.error(`no ${awsNet}: network chart skipped (set AWS_NET)`);
