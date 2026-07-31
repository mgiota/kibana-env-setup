#!/usr/bin/env node
// ============================================================
//  seed-heartbeat-monitors.mjs — fake autodiscovery monitors
//  WITHOUT minikube/agent.
//
//  The Synthetics overview classifies a monitor as
//  `origin: 'heartbeat'` purely from ping shape: a summary ping
//  in a LOCAL synthetics-* index, with no matching saved object
//  and carrying NEITHER `config_id` NOR `meta.space_id`. So we
//  bulk-index a handful of such pings straight into the synthetics
//  data stream — no agent, no Docker.
//
//  ES host + credentials are read from a Kibana dev config
//  (config/kibana.dev.yml): `elasticsearch.hosts` for the URL and
//  the `loginAssistanceMessage` (admin / <pw>) for a superuser.
//  Falls back to elastic/changeme for local ES.
//
//  USAGE:
//    node seed-heartbeat-monitors.mjs --kibana-dir ~/Documents/Development/kibana
//    node seed-heartbeat-monitors.mjs --count 4 --type tcp
//    (or set QA_KIBANA_DIR; override ES directly with --es-host/--es-user/--es-pass)
// ============================================================

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { info, ok, warn, err } from './lib/kibana.mjs';

function parseArgs(argv) {
  const a = {
    kibanaDir: process.env.QA_KIBANA_DIR || path.join(os.homedir(), 'Documents/Development/kibana'),
    esHost: process.env.QA_ES_HOST || null,
    esUser: process.env.QA_ES_USERNAME || null,
    esPass: process.env.QA_ES_PASSWORD || null,
    count: 4,
    type: 'http',
    pingsPerMonitor: 3,
  };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--kibana-dir') a.kibanaDir = argv[++i];
    else if (t === '--es-host') a.esHost = argv[++i];
    else if (t === '--es-user') a.esUser = argv[++i];
    else if (t === '--es-pass') a.esPass = argv[++i];
    else if (t === '--count') a.count = Number(argv[++i]);
    else if (t === '--type') a.type = argv[++i];
    else if (t === '--pings') a.pingsPerMonitor = Number(argv[++i]);
    else if (t === '--help' || t === '-h') {
      console.log(
        'seed-heartbeat-monitors [--kibana-dir DIR] [--count N] [--type http|tcp] [--pings N] [--es-host URL --es-user U --es-pass P]'
      );
      process.exit(0);
    } else {
      err(`Unknown arg: ${t}`);
      process.exit(2);
    }
  }
  return a;
}

// Minimal, dependency-free extraction of the few values we need from
// kibana.dev.yml — a full YAML parser is overkill for host + one message line.
function readEsConfig(kibanaDir) {
  const cfgPath = path.join(kibanaDir, 'config', 'kibana.dev.yml');
  if (!fs.existsSync(cfgPath)) {
    throw new Error(`kibana.dev.yml not found at ${cfgPath} (pass --kibana-dir or --es-host)`);
  }
  const text = fs.readFileSync(cfgPath, 'utf8');
  const host = text.match(/^\s*hosts:\s*(\S+)/m)?.[1];
  if (!host) throw new Error(`Could not find elasticsearch.hosts in ${cfgPath}`);
  const creds = text.match(/Credentials:\s*(\S+)\s*\/\s*([^'\s]+)/);
  const isLocal = /localhost|127\.0\.0\.1/.test(host);
  const username = creds?.[1] ?? (isLocal ? 'elastic' : 'admin');
  const password = creds?.[2] ?? 'changeme';
  return { host, username, password };
}

const iso = (d) => new Date(d).toISOString();

// A location-less autodiscovery summary ping. The critical bits for the overview
// to treat it as `origin: 'heartbeat'`: summary.final_attempt=true, and NO
// `config_id` / `meta.space_id` / saved object. `observer` is omitted so it lands
// under the "Heartbeat" placeholder location.
function summaryPing({ monitorId, name, type, url, timestamp }) {
  const start = new Date(new Date(timestamp).getTime() - 10 * 60 * 1000);
  return {
    '@timestamp': iso(timestamp),
    summary: { up: 1, down: 0, final_attempt: true },
    monitor: {
      id: monitorId,
      name,
      type,
      status: 'up',
      check_group: `${monitorId}-${new Date(timestamp).getTime()}`,
      duration: { us: 123456 },
      timespan: { gte: iso(start), lt: iso(timestamp) },
    },
    url: { full: url, domain: name },
    agent: { type: 'heartbeat', name: 'qa-seed', version: '8.6.0' },
    ecs: { version: '8.0.0' },
    data_stream: { namespace: 'default', type: 'synthetics', dataset: type },
    event: { type: 'heartbeat/summary', dataset: type },
    state: { up: 1, down: 0, status: 'up', checks: 1 },
  };
}

async function main() {
  const args = parseArgs(process.argv);
  const es =
    args.esHost && args.esUser
      ? { host: args.esHost, username: args.esUser, password: args.esPass ?? '' }
      : readEsConfig(args.kibanaDir);

  const dataStream = `synthetics-${args.type}-default`;
  info(`Seeding ${args.count} heartbeat monitor(s) → ${dataStream} on ${es.host}`);

  const auth = 'Basic ' + Buffer.from(`${es.username}:${es.password}`).toString('base64');
  const now = Date.now();

  const lines = [];
  for (let m = 1; m <= args.count; m++) {
    const monitorId = `qa-hb-${args.type}-${m}`;
    const name = `qa-heartbeat-${args.type}-${m}`;
    const url = `${args.type === 'tcp' ? 'tcp' : 'http'}://qa-heartbeat-${m}.svc.cluster.local:8080`;
    for (let p = 0; p < args.pingsPerMonitor; p++) {
      const timestamp = now - p * 5 * 60 * 1000; // one every 5 min, most-recent first
      lines.push(JSON.stringify({ create: { _index: dataStream } }));
      lines.push(JSON.stringify(summaryPing({ monitorId, name, type: args.type, url, timestamp })));
    }
  }
  const body = lines.join('\n') + '\n';

  const res = await fetch(`${es.host}/_bulk?refresh=wait_for`, {
    method: 'POST',
    headers: { Authorization: auth, 'Content-Type': 'application/x-ndjson' },
    body,
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`_bulk -> ${res.status}: ${JSON.stringify(json).slice(0, 400)}`);
  }
  if (json.errors) {
    const firstErr = json.items?.find((it) => it.create?.error)?.create?.error;
    throw new Error(`_bulk reported errors: ${JSON.stringify(firstErr).slice(0, 400)}`);
  }
  ok(`indexed ${args.count * args.pingsPerMonitor} heartbeat ping(s) for ${args.count} monitor(s)`);
  info('These surface under "Heartbeat monitors" in the overview once refreshed.');
}

main().catch((e) => {
  err(e.stack || e.message || String(e));
  process.exit(1);
});
