#!/usr/bin/env node
// ============================================================
//  seed-maintenance-windows.mjs — deterministic data for the
//  Synthetics "Manage maintenance windows" feature-acceptance run.
//
//  Ensures the target Kibana has what the flyout needs:
//    - Synthetics enabled
//    - a private location
//    - a few ui-origin HTTP monitors on that location
//    - a couple of maintenance windows (so the flyout combobox
//      actually has options to pick)
//
//  Idempotent-ish: monitors/windows are matched by a name prefix
//  and only created when missing.
//
//  USAGE:
//    node seed-maintenance-windows.mjs --base-url http://kibana-feat.local:5601
//    node seed-maintenance-windows.mjs --base-url ... --monitors 4 --windows 2
//    (auth defaults to elastic/changeme; override with --user/--pass)
// ============================================================

import { ok, info, warn, err, basicAuthHeaders } from './lib/kibana.mjs';

const PUBLIC_API_HEADERS = { 'elastic-api-version': '2023-10-31' };
// Internal alerting maintenance_window endpoints are versioned and gated on the
// internal-origin header.
const MW_HEADERS = { 'elastic-api-version': '2023-10-31', 'x-elastic-internal-origin': 'kibana' };
const NAME_PREFIX = 'qa-mw';

function parseArgs(argv) {
  const a = {
    baseUrl: 'http://kibana-feat.local:5601',
    user: 'elastic',
    pass: 'changeme',
    monitors: 3,
    windows: 2,
  };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--base-url') a.baseUrl = argv[++i];
    else if (t === '--user') a.user = argv[++i];
    else if (t === '--pass') a.pass = argv[++i];
    else if (t === '--monitors') a.monitors = Number(argv[++i]);
    else if (t === '--windows') a.windows = Number(argv[++i]);
    else if (t === '--help' || t === '-h') {
      console.log(
        'seed-maintenance-windows --base-url URL [--monitors N] [--windows N] [--user U] [--pass P]'
      );
      process.exit(0);
    } else {
      err(`Unknown arg: ${t}`);
      process.exit(2);
    }
  }
  return a;
}

const api = (baseUrl, auth) => {
  const headers = basicAuthHeaders(auth);
  return async (path, { method = 'GET', body, extraHeaders } = {}) => {
    const res = await fetch(`${baseUrl}${path}`, {
      method,
      headers: { ...headers, ...extraHeaders },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    let json;
    try {
      json = text ? JSON.parse(text) : undefined;
    } catch {
      json = text;
    }
    if (!res.ok) {
      throw new Error(`${method} ${path} -> ${res.status}: ${text.slice(0, 400)}`);
    }
    return json;
  };
};

async function ensureEnabled(request) {
  await request('/internal/synthetics/service/enablement', { method: 'PUT' });
  ok('synthetics enabled');
}

async function ensurePrivateLocation(request) {
  const existing = await request('/api/synthetics/private_locations', {
    extraHeaders: PUBLIC_API_HEADERS,
  });
  if (Array.isArray(existing) && existing.length > 0) {
    ok(`private location exists: ${existing[0].label}`);
    return { id: existing[0].id, label: existing[0].label };
  }
  const policy = await request('/api/fleet/agent_policies', {
    method: 'POST',
    extraHeaders: PUBLIC_API_HEADERS,
    body: {
      name: `qa-mw-policy-${Date.now()}`,
      namespace: 'default',
      monitoring_enabled: ['logs', 'metrics'],
    },
  });
  const agentPolicyId = policy.item.id;
  const loc = await request('/api/synthetics/private_locations', {
    method: 'POST',
    extraHeaders: PUBLIC_API_HEADERS,
    body: { label: 'QA private location', agentPolicyId, geo: { lat: 0, lon: 0 } },
  });
  ok(`created private location: ${loc.label}`);
  return { id: loc.id, label: loc.label };
}

async function listMonitors(request) {
  const data = await request(
    '/api/synthetics/monitors?perPage=1000&query=' + encodeURIComponent(NAME_PREFIX),
    { extraHeaders: PUBLIC_API_HEADERS }
  );
  return data?.monitors ?? [];
}

async function ensureMonitors(request, location, count) {
  const existing = await listMonitors(request);
  const have = existing.length;
  if (have >= count) {
    ok(`${have} qa monitors already present`);
    return existing;
  }
  for (let i = have; i < count; i++) {
    const name = `${NAME_PREFIX}-monitor-${i + 1}`;
    await request('/api/synthetics/monitors', {
      method: 'POST',
      extraHeaders: PUBLIC_API_HEADERS,
      body: {
        type: 'http',
        name,
        urls: `https://example.com/${i + 1}`,
        private_locations: [location.id],
        alert: { status: { enabled: true } },
      },
    });
    ok(`created monitor ${name}`);
  }
  return listMonitors(request);
}

async function listMaintenanceWindows(request) {
  // internal find endpoint used by the Synthetics flyout's useMaintenanceWindows()
  const data = await request('/internal/alerting/rules/maintenance_window/_find?per_page=100', {
    method: 'GET',
    extraHeaders: MW_HEADERS,
  }).catch(() => undefined);
  const items = data?.data ?? data?.maintenance_windows ?? [];
  return items.filter((w) => (w.title ?? '').startsWith(NAME_PREFIX));
}

async function ensureMaintenanceWindows(request, count) {
  const existing = await listMaintenanceWindows(request);
  if (existing.length >= count) {
    ok(`${existing.length} qa maintenance windows already present`);
    return existing;
  }
  for (let i = existing.length; i < count; i++) {
    const title = `${NAME_PREFIX}-window-${i + 1}`;
    await request('/internal/alerting/rules/maintenance_window', {
      method: 'POST',
      extraHeaders: MW_HEADERS,
      body: {
        title,
        duration: 60 * 60 * 1000,
        r_rule: { dtstart: new Date().toISOString(), tzid: 'UTC', freq: 0, count: 1 },
        category_ids: ['observability'],
      },
    });
    ok(`created maintenance window ${title}`);
  }
  return listMaintenanceWindows(request);
}

async function main() {
  const args = parseArgs(process.argv);
  const auth = { username: args.user, password: args.pass };
  const request = api(args.baseUrl, auth);

  info(`Seeding ${args.baseUrl} (monitors=${args.monitors}, windows=${args.windows})`);

  try {
    await ensureEnabled(request);
  } catch (e) {
    warn(`enablement call failed (may already be enabled): ${e.message}`);
  }

  const location = await ensurePrivateLocation(request);
  const monitors = await ensureMonitors(request, location, args.monitors);
  const windows = await ensureMaintenanceWindows(request, args.windows);

  ok(`Done. ${monitors.length} monitors, ${windows.length} maintenance windows ready.`);
}

main().catch((e) => {
  err(e.stack || e.message || String(e));
  process.exit(1);
});
