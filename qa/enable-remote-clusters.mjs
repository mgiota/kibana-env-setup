#!/usr/bin/env node
// ============================================================
//  enable-remote-clusters.mjs — make remote (CCS) monitors show.
//
//  Remote monitors are OFF by default in Synthetics: the overview
//  only searches remote `*:synthetics-*` indices when the
//  multi-space setting `useAllRemoteClusters` (Settings → Remote
//  clusters) is on (get_synthetics_indices.ts). This flips it via
//  the Kibana API — no ES access needed.
//
//  Preflight: warns if the target isn't a remote (oblt-cli) setup,
//  since there'll be no remote data to show regardless.
//
//  Auth/target default to the qa-feature `setup` env
//  (QA_BASE_URL / QA_KIBANA_USERNAME / QA_KIBANA_PASSWORD).
//
//  USAGE:
//    node enable-remote-clusters.mjs --base-url http://localhost:5602
//    node enable-remote-clusters.mjs --clusters remote_cluster   (select specific)
// ============================================================

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { info, ok, warn, err } from './lib/kibana.mjs';
import { createApi } from './lib/synthetics.mjs';

const MULTI_SPACE_SETTINGS = '/internal/synthetics/settings_multi_space';
// Internal routes are versioned and gated on the internal-origin header.
const INTERNAL_HEADERS = { 'x-elastic-internal-origin': 'kibana', 'elastic-api-version': '1' };

function parseArgs(argv) {
  const a = {
    baseUrl: process.env.QA_BASE_URL || 'http://localhost:5602',
    user: process.env.QA_KIBANA_USERNAME || 'elastic',
    pass: process.env.QA_KIBANA_PASSWORD || 'changeme',
    clusters: null, // comma-separated → selectedRemoteClusters; null → useAllRemoteClusters
    kibanaDir: process.env.QA_KIBANA_DIR || path.join(os.homedir(), 'Documents/Development/kibana'),
  };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--base-url') a.baseUrl = argv[++i];
    else if (t === '--user') a.user = argv[++i];
    else if (t === '--pass') a.pass = argv[++i];
    else if (t === '--clusters') a.clusters = argv[++i];
    else if (t === '--kibana-dir') a.kibanaDir = argv[++i];
    else if (t === '--help' || t === '-h') {
      console.log(
        'enable-remote-clusters --base-url URL [--clusters a,b] [--kibana-dir DIR] [--user U] [--pass P]'
      );
      process.exit(0);
    } else {
      err(`Unknown arg: ${t}`);
      process.exit(2);
    }
  }
  return a;
}

// Whether Kibana reads a remote (non-localhost) ES — that's the only case where
// remote monitors can exist. Prefer the real ES host from kibana.dev.yml; fall
// back to the Kibana URL if the config can't be read.
function isRemoteEsSetup(kibanaDir, baseUrl) {
  const cfgPath = path.join(kibanaDir, 'config', 'kibana.dev.yml');
  try {
    const host = fs.readFileSync(cfgPath, 'utf8').match(/^\s*hosts:\s*(\S+)/m)?.[1];
    if (host) return !/localhost|127\.0\.0\.1/.test(host);
  } catch {
    /* fall through to the Kibana URL heuristic */
  }
  return !/localhost|127\.0\.0\.1/.test(baseUrl);
}

async function main() {
  const args = parseArgs(process.argv);
  const request = createApi(args.baseUrl, { username: args.user, password: args.pass });

  // Preflight: is this a remote (CCS) setup at all? If Kibana reads local ES
  // there won't be any remote monitors to reveal, so flipping the setting is a
  // no-op in practice. Checked against the real ES host from kibana.dev.yml.
  if (!isRemoteEsSetup(args.kibanaDir, args.baseUrl)) {
    warn(
      'Kibana appears to read LOCAL ES — there are no remote monitors to reveal. ' +
        'Use a remote setup: `dev-start.sh --remote` (defaults to the edge-oblt CCS cluster).'
    );
  }

  const body = args.clusters
    ? { useAllRemoteClusters: false, selectedRemoteClusters: args.clusters.split(',').map((c) => c.trim()) }
    : { useAllRemoteClusters: true, selectedRemoteClusters: [] };
  // Share the setting across all spaces so the overview honours it everywhere.
  body.spaces = ['*'];

  try {
    const saved = await request(MULTI_SPACE_SETTINGS, {
      method: 'PUT',
      extraHeaders: INTERNAL_HEADERS,
      body,
    });
    ok(
      args.clusters
        ? `selected remote clusters: ${args.clusters}`
        : 'enabled all remote clusters (useAllRemoteClusters=true)'
    );
    info(`settings: ${JSON.stringify({ useAllRemoteClusters: saved?.useAllRemoteClusters, selectedRemoteClusters: saved?.selectedRemoteClusters })}`);
  } catch (e) {
    // 404 => serverless (CCS unavailable) or route gated off; treat as non-fatal.
    if (/-> 404/.test(String(e.message))) {
      warn('multi-space settings route returned 404 (serverless / CCS unavailable) — skipping.');
      return;
    }
    throw e;
  }
}

main().catch((e) => {
  err(e.stack || e.message || String(e));
  process.exit(1);
});
