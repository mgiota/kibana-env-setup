#!/usr/bin/env node
// ============================================================
//  generate-monitors.js — create diverse Synthetics monitors + mock data
//
//  Discovers existing locations (public + private with enrolled agents)
//  and creates ~40 monitors (HTTP, TCP, ICMP, browser) distributed
//  across them. Ingests mock summary data so the Synthetics overview
//  shows realistic up/down/pending statuses.
//
//  Idempotent: safe to re-run — skips monitors that already exist.
//
//  USAGE:
//    node generate-monitors.js \
//      --kibana-url http://localhost:5601 \
//      --kibana-username elastic \
//      --kibana-password changeme \
//      --elasticsearch-host http://localhost:9200 \
//      --elasticsearch-username elastic \
//      --elasticsearch-password changeme
// ============================================================

const http = require('http');
const https = require('https');
const { URL } = require('url');

// ── CLI arg parsing ─────────────────────────────────────────
function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i].replace(/^--/, '').replace(/-/g, '_');
    opts[key] = args[i + 1];
  }
  return {
    kibanaUrl: opts.kibana_url || 'http://localhost:5601',
    kibanaUsername: opts.kibana_username || 'elastic',
    kibanaPassword: opts.kibana_password || 'changeme',
    esHost: opts.elasticsearch_host || 'http://localhost:9200',
    esUsername: opts.elasticsearch_username || opts.kibana_username || 'elastic',
    esPassword: opts.elasticsearch_password || opts.kibana_password || 'changeme',
  };
}

const config = parseArgs();

// ── HTTP helpers ────────────────────────────────────────────
function request(baseUrl, path, method, body, username, password) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, baseUrl);
    const isHttps = url.protocol === 'https:';
    const lib = isHttps ? https : http;
    const auth = `${username}:${password}`;

    const options = {
      hostname: url.hostname,
      port: url.port || (isHttps ? 443 : 80),
      path: url.pathname + url.search,
      method,
      headers: {
        'kbn-xsrf': 'true',
        'elastic-api-version': '2023-10-31',
        'Content-Type': 'application/json',
        Authorization: 'Basic ' + Buffer.from(auth).toString('base64'),
      },
      rejectUnauthorized: false,
    };

    const req = lib.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(data) });
        } catch {
          resolve({ status: res.statusCode, body: data });
        }
      });
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

function kibanaApi(path, method = 'GET', body = null) {
  return request(config.kibanaUrl, path, method, body, config.kibanaUsername, config.kibanaPassword);
}

// ── Logging helpers ─────────────────────────────────────────
const log = (msg) => console.log(`   ${msg}`);
const logSection = (msg) => console.log(`\n▶ ${msg}`);
const logOk = (msg) => console.log(`   ✅ ${msg}`);
const logSkip = (msg) => console.log(`   ⏭  ${msg}`);
const logErr = (msg) => console.log(`   ❌ ${msg}`);
const logWarn = (msg) => console.log(`   ⚠  ${msg}`);

// ============================================================
//  DISCOVER AVAILABLE LOCATIONS
// ============================================================
async function discoverLocations() {
  logSection('Discovering available locations...');

  const locations = []; // { id, label, isServiceManaged }

  // 1. Fetch private locations
  const privateResp = await kibanaApi('/api/synthetics/private_locations');
  const privateLocations = Array.isArray(privateResp.body) ? privateResp.body : [];

  // Check which private locations have enrolled agents
  for (const loc of privateLocations) {
    const agentPolicyId = loc.agentPolicyId;
    if (!agentPolicyId) continue;

    const agentsResp = await kibanaApi(
      `/api/fleet/agents?kuery=policy_id:"${agentPolicyId}"&perPage=1`
    );
    const agentCount = agentsResp.body?.total || 0;

    if (agentCount > 0) {
      locations.push({
        id: loc.id,
        label: loc.label,
        isServiceManaged: false,
      });
      logOk(`Private: "${loc.label}" (${agentCount} agent(s))`);
    } else {
      logWarn(`Private: "${loc.label}" — skipped (no enrolled agents)`);
    }
  }

  // 2. Fetch public (service-managed) locations
  //    The /internal/uptime/service/locations endpoint returns ALL locations
  //    (both public and private), so we must filter by isServiceManaged.
  const svcResp = await kibanaApi('/internal/uptime/service/locations');
  const allSvcLocations = svcResp.body?.locations || [];
  const publicLocations = allSvcLocations.filter((l) => l.isServiceManaged === true);

  for (const loc of publicLocations) {
    locations.push({
      id: loc.id,
      label: loc.label,
      isServiceManaged: true,
    });
  }

  if (publicLocations.length > 0) {
    logOk(`Public: found ${publicLocations.length} service-managed location(s)`);
    for (const loc of publicLocations) {
      log(`   • ${loc.label} (${loc.id})`);
    }
  } else {
    logWarn('No public locations found (Synthetics service may not be enabled)');
    // Try enabling the Synthetics service
    log('   Attempting to enable Synthetics service...');
    const enableResp = await kibanaApi('/internal/synthetics/service/enablement', 'PUT');
    if (enableResp.status === 200) {
      logOk('Synthetics service enabled — retrying public locations...');
      const retryResp = await kibanaApi('/internal/uptime/service/locations');
      const retryAll = retryResp.body?.locations || [];
      const retryPublic = retryAll.filter((l) => l.isServiceManaged === true);
      for (const loc of retryPublic) {
        locations.push({
          id: loc.id,
          label: loc.label,
          isServiceManaged: true,
        });
      }
      if (retryPublic.length > 0) {
        logOk(`Public: found ${retryPublic.length} service-managed location(s) after enabling`);
      }
    }
  }

  if (locations.length === 0) {
    logErr('No usable locations found. Run "run-data synthetics" first to create a private location with an agent.');
  } else {
    log(`\n   Total usable locations: ${locations.length}`);
  }

  return locations;
}

// ============================================================
//  MONITOR DEFINITIONS
// ============================================================
function buildMonitorDefinitions(locations) {
  // Sort locations: private first, then public, for predictable assignment
  const privateLocs = locations.filter((l) => !l.isServiceManaged);
  const publicLocs = locations.filter((l) => l.isServiceManaged);
  const allLocs = [...privateLocs, ...publicLocs];

  // Helper: pick N locations from the available pool (round-robin style)
  const pick = (count, startOffset = 0) => {
    if (allLocs.length === 0) return [];
    const result = [];
    for (let i = 0; i < Math.min(count, allLocs.length); i++) {
      const idx = (startOffset + i) % allLocs.length;
      result.push(allLocs[idx]);
    }
    return result;
  };

  // For monitors that specifically need a private location
  const pickPrivate = (count) => privateLocs.slice(0, count);
  // For monitors that specifically need a public location
  const pickPublic = (count) => publicLocs.slice(0, count);

  // Use all available locations
  const all = () => [...allLocs];

  return [
    // ── HTTP Monitors ──────────────────────────────────────
    {
      type: 'http', name: 'Homepage — elastic.co', urls: 'https://www.elastic.co',
      schedule: { number: '3', unit: 'm' }, tags: ['production', 'website', 'critical'],
      locations: all(),
      alert: { status: { enabled: true }, tls: { enabled: true } },
    },
    {
      type: 'http', name: 'Docs site', urls: 'https://www.elastic.co/docs',
      schedule: { number: '5', unit: 'm' }, tags: ['production', 'docs'],
      locations: pick(2, 0),
    },
    {
      type: 'http', name: 'Kibana Login Page', urls: 'https://kibana.example.com/login',
      schedule: { number: '3', unit: 'm' }, tags: ['internal', 'kibana', 'critical'],
      locations: pick(3, 1),
      alert: { status: { enabled: true } },
    },
    {
      type: 'http', name: 'API Gateway — /healthz', urls: 'https://api.example.com/healthz',
      schedule: { number: '1', unit: 'm' }, tags: ['api', 'infrastructure', 'critical'],
      locations: all(),
      alert: { status: { enabled: true } },
    },
    {
      type: 'http', name: 'Auth Service', urls: 'https://auth.example.com/status',
      schedule: { number: '3', unit: 'm' }, tags: ['api', 'auth', 'critical'],
      locations: pick(2, 2),
      alert: { status: { enabled: true } },
    },
    {
      type: 'http', name: 'Payment Gateway', urls: 'https://payments.example.com/health',
      schedule: { number: '1', unit: 'm' }, tags: ['api', 'payments', 'pci', 'critical'],
      locations: pick(3, 0),
      alert: { status: { enabled: true }, tls: { enabled: true } },
    },
    {
      type: 'http', name: 'CDN Origin — US', urls: 'https://cdn-origin-us.example.com/probe',
      schedule: { number: '5', unit: 'm' }, tags: ['cdn', 'infrastructure'],
      locations: pick(1, 0),
    },
    {
      type: 'http', name: 'CDN Origin — EU', urls: 'https://cdn-origin-eu.example.com/probe',
      schedule: { number: '5', unit: 'm' }, tags: ['cdn', 'infrastructure'],
      locations: pick(1, 1),
    },
    {
      type: 'http', name: 'CDN Origin — APAC', urls: 'https://cdn-origin-apac.example.com/probe',
      schedule: { number: '5', unit: 'm' }, tags: ['cdn', 'infrastructure'],
      locations: pick(1, 2),
    },
    {
      type: 'http', name: 'Status Page', urls: 'https://status.example.com',
      schedule: { number: '3', unit: 'm' }, tags: ['production', 'status-page'],
      locations: pick(2, 0),
    },
    {
      type: 'http', name: 'Blog', urls: 'https://www.elastic.co/blog',
      schedule: { number: '10', unit: 'm' }, tags: ['production', 'content'],
      locations: pick(1, 3),
    },
    {
      type: 'http', name: 'Partner Portal', urls: 'https://partners.example.com/api/v1/health',
      schedule: { number: '5', unit: 'm' }, tags: ['partner', 'api'],
      locations: pick(2, 1),
    },
    {
      type: 'http', name: 'Search API', urls: 'https://search.example.com/api/health',
      schedule: { number: '3', unit: 'm' }, tags: ['api', 'search'],
      locations: pick(3, 2),
      alert: { status: { enabled: true } },
    },
    {
      type: 'http', name: 'Webhook Receiver', urls: 'https://hooks.example.com/health',
      schedule: { number: '5', unit: 'm' }, tags: ['api', 'webhooks'],
      locations: pick(1, 4),
    },
    {
      type: 'http', name: 'GraphQL Gateway', urls: 'https://graphql.example.com/.well-known/health',
      schedule: { number: '3', unit: 'm' }, tags: ['api', 'graphql'],
      locations: pick(2, 0),
    },
    {
      type: 'http', name: 'Notifications Service', urls: 'https://notify.example.com/health',
      schedule: { number: '5', unit: 'm' }, tags: ['api', 'notifications'],
      locations: pick(1, 5),
    },

    // ── TCP Monitors ───────────────────────────────────────
    {
      type: 'tcp', name: 'PostgreSQL Primary', hosts: 'db-primary.example.com:5432',
      schedule: { number: '3', unit: 'm' }, tags: ['database', 'postgres', 'critical'],
      locations: pick(2, 0),
      alert: { status: { enabled: true } },
    },
    {
      type: 'tcp', name: 'PostgreSQL Replica', hosts: 'db-replica.example.com:5432',
      schedule: { number: '5', unit: 'm' }, tags: ['database', 'postgres', 'replica'],
      locations: pick(1, 1),
    },
    {
      type: 'tcp', name: 'Redis Cluster', hosts: 'redis.example.com:6379',
      schedule: { number: '3', unit: 'm' }, tags: ['cache', 'redis', 'critical'],
      locations: pick(2, 2),
      alert: { status: { enabled: true } },
    },
    {
      type: 'tcp', name: 'Kafka Broker 1', hosts: 'kafka-1.example.com:9092',
      schedule: { number: '5', unit: 'm' }, tags: ['messaging', 'kafka'],
      locations: pick(1, 0),
    },
    {
      type: 'tcp', name: 'Kafka Broker 2', hosts: 'kafka-2.example.com:9092',
      schedule: { number: '5', unit: 'm' }, tags: ['messaging', 'kafka'],
      locations: pick(1, 3),
    },
    {
      type: 'tcp', name: 'SMTP Relay', hosts: 'smtp.example.com:587',
      schedule: { number: '10', unit: 'm' }, tags: ['email', 'infrastructure'],
      locations: pick(1, 4),
    },
    {
      type: 'tcp', name: 'Elasticsearch Ingest', hosts: 'es-ingest.example.com:9243',
      schedule: { number: '3', unit: 'm' }, tags: ['elasticsearch', 'ingest', 'critical'],
      locations: pick(3, 0),
      alert: { status: { enabled: true } },
    },
    {
      type: 'tcp', name: 'MongoDB', hosts: 'mongo.example.com:27017',
      schedule: { number: '5', unit: 'm' }, tags: ['database', 'mongodb'],
      locations: pick(1, 2),
    },

    // ── ICMP Monitors ──────────────────────────────────────
    {
      type: 'icmp', name: 'DC Gateway — Primary', hosts: 'gw-primary.example.com',
      schedule: { number: '5', unit: 'm' }, tags: ['network', 'gateway'],
      locations: pick(1, 0),
    },
    {
      type: 'icmp', name: 'DC Gateway — Secondary', hosts: 'gw-secondary.example.com',
      schedule: { number: '5', unit: 'm' }, tags: ['network', 'gateway'],
      locations: pick(1, 1),
    },
    {
      type: 'icmp', name: 'DC Gateway — DR', hosts: 'gw-dr.example.com',
      schedule: { number: '5', unit: 'm' }, tags: ['network', 'gateway', 'dr'],
      locations: pick(1, 2),
    },
    {
      type: 'icmp', name: 'Load Balancer — Frontend', hosts: 'lb-frontend.example.com',
      schedule: { number: '3', unit: 'm' }, tags: ['network', 'load-balancer'],
      locations: pick(2, 0),
    },
    {
      type: 'icmp', name: 'Load Balancer — Backend', hosts: 'lb-backend.example.com',
      schedule: { number: '3', unit: 'm' }, tags: ['network', 'load-balancer'],
      locations: pick(2, 1),
    },
    {
      type: 'icmp', name: 'VPN Endpoint', hosts: 'vpn.example.com',
      schedule: { number: '3', unit: 'm' }, tags: ['network', 'vpn', 'critical'],
      locations: pick(2, 0),
      alert: { status: { enabled: true } },
    },
    {
      type: 'icmp', name: 'DNS Primary', hosts: 'dns1.example.com',
      schedule: { number: '3', unit: 'm' }, tags: ['network', 'dns', 'critical'],
      locations: all(),
      alert: { status: { enabled: true } },
    },
    {
      type: 'icmp', name: 'DNS Secondary', hosts: 'dns2.example.com',
      schedule: { number: '5', unit: 'm' }, tags: ['network', 'dns'],
      locations: pick(2, 1),
    },

    // ── Browser Monitors ───────────────────────────────────
    {
      type: 'browser', name: 'Login Flow',
      schedule: { number: '10', unit: 'm' }, tags: ['e2e', 'auth', 'critical'],
      locations: pick(2, 0),
      alert: { status: { enabled: true } },
      'source.inline.script': `
step('Go to login page', async () => {
  await page.goto('https://app.example.com/login');
});
step('Verify login form renders', async () => {
  await page.waitForSelector('[data-testid="login-form"]');
});`,
    },
    {
      type: 'browser', name: 'Dashboard Load',
      schedule: { number: '10', unit: 'm' }, tags: ['e2e', 'dashboard'],
      locations: pick(1, 1),
      'source.inline.script': `
step('Navigate to dashboard', async () => {
  await page.goto('https://app.example.com/dashboard');
});
step('Verify dashboard loads', async () => {
  await page.waitForSelector('[data-testid="dashboard-container"]');
});`,
    },
    {
      type: 'browser', name: 'Search E2E',
      schedule: { number: '15', unit: 'm' }, tags: ['e2e', 'search'],
      locations: pick(2, 2),
      'source.inline.script': `
step('Open search page', async () => {
  await page.goto('https://app.example.com/search');
});
step('Type search query', async () => {
  await page.fill('[data-testid="search-input"]', 'test query');
});
step('Verify results appear', async () => {
  await page.waitForSelector('[data-testid="search-results"]');
});`,
    },
    {
      type: 'browser', name: 'Checkout Flow',
      schedule: { number: '10', unit: 'm' }, tags: ['e2e', 'checkout', 'critical'],
      locations: pick(2, 0),
      alert: { status: { enabled: true } },
      'source.inline.script': `
step('Go to cart', async () => {
  await page.goto('https://shop.example.com/cart');
});
step('Verify cart page loads', async () => {
  await page.waitForSelector('[data-testid="cart-items"]');
});`,
    },
    {
      type: 'browser', name: 'User Profile Page',
      schedule: { number: '15', unit: 'm' }, tags: ['e2e', 'profile'],
      locations: pick(1, 3),
      'source.inline.script': `
step('Navigate to profile', async () => {
  await page.goto('https://app.example.com/profile');
});
step('Verify profile renders', async () => {
  await page.waitForSelector('[data-testid="user-profile"]');
});`,
    },
    {
      type: 'browser', name: 'Documentation Navigation',
      schedule: { number: '15', unit: 'm' }, tags: ['e2e', 'docs'],
      locations: pick(2, 1),
      'source.inline.script': `
step('Open docs', async () => {
  await page.goto('https://docs.example.com');
});
step('Verify table of contents', async () => {
  await page.waitForSelector('[data-testid="toc"]');
});`,
    },
  ];
}

// ============================================================
//  CREATE MONITORS (idempotent)
// ============================================================
async function createMonitors(locations) {
  logSection('Creating monitors...');

  // Fetch existing monitors
  const existingResp = await kibanaApi('/api/synthetics/monitors?perPage=200');
  const existingNames = new Set(
    (existingResp.body?.monitors || []).map((m) => m.name)
  );

  const monitors = buildMonitorDefinitions(locations);
  let created = 0;
  let skipped = 0;
  let failed = 0;

  for (const monitor of monitors) {
    if (existingNames.has(monitor.name)) {
      logSkip(`"${monitor.name}" (${monitor.type})`);
      skipped++;
      continue;
    }

    // Build the payload — trim inline scripts
    const payload = { ...monitor };
    if (payload['source.inline.script']) {
      payload['source.inline.script'] = payload['source.inline.script'].trim();
    }

    const resp = await kibanaApi('/api/synthetics/monitors', 'POST', payload);
    if (resp.status === 200 && (resp.body?.id || resp.body?.config_id)) {
      const id = resp.body.id || resp.body.config_id;
      logOk(`Created "${monitor.name}" (${monitor.type}) → ${id}`);
      created++;
    } else {
      logErr(`Failed "${monitor.name}": ${JSON.stringify(resp.body?.message || resp.body).substring(0, 200)}`);
      failed++;
    }
  }

  log(`\n   Summary: ${created} created, ${skipped} skipped, ${failed} failed`);
  return monitors.length;
}

// ============================================================
//  MOCK SUMMARY DATA
// ============================================================
async function ingestMockData() {
  logSection('Ingesting mock summary data...');

  // Fetch all monitors to get their IDs and config
  const monitorsResp = await kibanaApi('/api/synthetics/monitors?perPage=200');
  const monitors = monitorsResp.body?.monitors || [];

  if (monitors.length === 0) {
    logErr('No monitors found — skipping mock data ingestion.');
    return;
  }

  const now = Date.now();
  const bulkLines = [];

  // Status distribution: ~70% up, ~15% down, ~15% pending (no data)
  function pickStatus(index) {
    // Deterministic based on index so re-runs produce same results
    const roll = (index * 37 + 13) % 100;
    if (roll < 70) return 'up';
    if (roll < 85) return 'down';
    return 'pending';
  }

  for (let i = 0; i < monitors.length; i++) {
    const m = monitors[i];
    const monitorStatus = pickStatus(i);

    // Skip pending — they just have no data
    if (monitorStatus === 'pending') continue;

    const configId = m.config_id || m.id;
    const monitorName = m.name;
    const monitorType = m.type;
    const monitorLocations = m.locations || [];

    for (const location of monitorLocations) {
      // Generate summary docs for the last 30 minutes (a few check cycles)
      const checkCount = monitorStatus === 'up' ? 5 : 3;
      for (let c = 0; c < checkCount; c++) {
        const ts = new Date(now - c * 3 * 60 * 1000).toISOString();
        const isUp = monitorStatus === 'up' || (monitorStatus === 'down' && c > 0);
        const durationUs = isUp
          ? Math.floor(100000 + Math.random() * 400000)   // 100-500ms
          : Math.floor(5000000 + Math.random() * 5000000); // 5-10s (timeout)

        // Determine URL for the doc
        const monitorUrl = m.urls || m.hosts || '';

        const doc = {
          '@timestamp': ts,
          monitor: {
            id: configId,
            name: monitorName,
            type: monitorType,
            status: isUp ? 'up' : 'down',
            duration: { us: durationUs },
            check_group: `${configId}-${location.id || location.label}-${c}-${Date.now()}`,
            timespan: {
              gte: ts,
              lt: new Date(now - (c - 1) * 3 * 60 * 1000).toISOString(),
            },
          },
          summary: {
            up: isUp ? 1 : 0,
            down: isUp ? 0 : 1,
            final_attempt: true,
          },
          observer: {
            name: location.label || location.id,
            geo: {
              name: location.label || location.id,
            },
          },
          config_id: configId,
          meta: {
            space_id: 'default',
          },
        };

        // Add URL info if available
        if (monitorUrl) {
          doc.url = {
            full: monitorUrl,
            domain: monitorUrl.replace(/https?:\/\//, '').split('/')[0].split(':')[0],
          };
        }

        // Add error info for down monitors
        if (!isUp) {
          doc.error = {
            message: monitorType === 'http'
              ? 'received status code 503'
              : monitorType === 'tcp'
                ? 'connection refused'
                : monitorType === 'icmp'
                  ? 'request timeout'
                  : 'journey did not finish within timeout',
            type: 'io',
          };
        }

        // Data stream naming: synthetics-{type}-default
        const indexTarget = `synthetics-${monitorType}-default`;

        bulkLines.push(JSON.stringify({ create: { _index: indexTarget } }));
        bulkLines.push(JSON.stringify(doc));
      }
    }
  }

  if (bulkLines.length === 0) {
    logSkip('No mock data to ingest (all monitors may be pending).');
    return;
  }

  // Send bulk request in batches of 500 lines (250 docs)
  const batchSize = 500;
  let totalIndexed = 0;
  let totalErrors = 0;

  for (let i = 0; i < bulkLines.length; i += batchSize) {
    const batch = bulkLines.slice(i, i + batchSize).join('\n') + '\n';

    // Send raw NDJSON body for bulk (can't use JSON.stringify wrapper)
    const bulkResp = await new Promise((resolve, reject) => {
      const url = new URL('/_bulk', config.esHost);
      const isHttps = url.protocol === 'https:';
      const lib = isHttps ? https : http;
      const auth = `${config.esUsername}:${config.esPassword}`;

      const options = {
        hostname: url.hostname,
        port: url.port || (isHttps ? 443 : 80),
        path: '/_bulk',
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-ndjson',
          Authorization: 'Basic ' + Buffer.from(auth).toString('base64'),
        },
        rejectUnauthorized: false,
      };

      const req = lib.request(options, (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          try {
            resolve(JSON.parse(data));
          } catch {
            resolve({ errors: true, message: data });
          }
        });
      });
      req.on('error', reject);
      req.write(batch);
      req.end();
    });

    if (bulkResp.errors) {
      const errorItems = (bulkResp.items || []).filter((item) => {
        const op = item.create || item.index;
        return op && op.error;
      });
      totalErrors += errorItems.length;
      const successItems = (bulkResp.items || []).length - errorItems.length;
      totalIndexed += successItems;
      if (errorItems.length > 0) {
        const firstError = errorItems[0].create?.error || errorItems[0].index?.error;
        log(`Batch warning: ${errorItems.length} error(s). First: ${JSON.stringify(firstError).substring(0, 200)}`);
      }
    } else {
      totalIndexed += (bulkResp.items || []).length;
    }
  }

  logOk(`Ingested ${totalIndexed} summary doc(s) across ${monitors.length} monitors (${totalErrors} errors)`);
}

// ============================================================
//  MAIN
// ============================================================
async function main() {
  console.log('🔧  generate-monitors.js — Synthetics monitor generator');
  console.log(`   Kibana: ${config.kibanaUrl}`);
  console.log(`   ES:     ${config.esHost}`);
  console.log('');

  // 1. Discover available locations (public + private with agents)
  const locations = await discoverLocations();
  if (locations.length === 0) {
    logErr('No usable locations. Run "run-data synthetics" first to create a private location.');
    process.exit(1);
  }

  // 2. Create monitors distributed across available locations
  await createMonitors(locations);

  // 3. Ingest mock data
  await ingestMockData();

  console.log('\n✅  Done! Open Synthetics overview to see your monitors.');
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
