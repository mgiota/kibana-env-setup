#!/usr/bin/env node
// ============================================================
//  seed-private-locations.mjs — deterministic setup for the
//  private-location / Fleet space-awareness qa-feature scenarios.
//
//  Scoped to the DELTA that `run-data.sh synthetics` does NOT do:
//    - ensure a non-default space (default: `naims`)
//    - ensure an agent policy the flyout can select (reuses an
//      existing private location's policy if one is present, else
//      creates a PLAIN Fleet agent policy via the API — no Docker
//      agent, because the add-private-location flyout validation
//      only reads the policy's `space_ids`, not a live agent)
//    - --enable-space-awareness : the one-way Fleet migration
//    - --precreate-share        : Rohan's SO-sharing workaround
//    - prints agentPolicyId + space_ids for the scenario assertions
//
//  It intentionally does NOT enroll an agent or create monitors.
//  For an agent-backed location run `run-data synthetics` first;
//  this script will then reuse that location's agent policy.
//
//  USAGE:
//    node seed-private-locations.mjs --base-url http://kibana-feat.local:5601
//    node seed-private-locations.mjs --base-url ... --space naims
//    node seed-private-locations.mjs --base-url ... --enable-space-awareness
//    node seed-private-locations.mjs --base-url ... --precreate-share
//    (auth defaults to elastic/changeme; override with --user/--pass)
// ============================================================

import { info, warn, err, ok } from './lib/kibana.mjs';
import { createApi, ensureEnabled, PUBLIC_API_HEADERS } from './lib/synthetics.mjs';

const PRIVATE_LOCATION_SO_TYPE = 'synthetics-private-location';
// Internal Fleet routes are versioned and gated on the internal-origin header.
const INTERNAL_HEADERS = { 'x-elastic-internal-origin': 'kibana', 'elastic-api-version': '1' };
const NAME_PREFIX = 'qa-pl';

function parseArgs(argv) {
  const a = {
    baseUrl: 'http://kibana-feat.local:5601',
    user: 'elastic',
    pass: 'changeme',
    space: 'naims',
    enableSpaceAwareness: false,
    precreateShare: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--base-url') a.baseUrl = argv[++i];
    else if (t === '--user') a.user = argv[++i];
    else if (t === '--pass') a.pass = argv[++i];
    else if (t === '--space') a.space = argv[++i];
    else if (t === '--enable-space-awareness') a.enableSpaceAwareness = true;
    else if (t === '--precreate-share') a.precreateShare = true;
    else if (t === '--help' || t === '-h') {
      console.log(
        'seed-private-locations --base-url URL [--space ID] [--enable-space-awareness] [--precreate-share] [--user U] [--pass P]'
      );
      process.exit(0);
    } else {
      err(`Unknown arg: ${t}`);
      process.exit(2);
    }
  }
  return a;
}

async function ensureSpace(request, spaceId) {
  const existing = await request(`/api/spaces/space/${spaceId}`).catch(() => undefined);
  if (existing?.id) {
    ok(`space "${spaceId}" already exists`);
    return existing;
  }
  const space = await request('/api/spaces/space', {
    method: 'POST',
    body: { id: spaceId, name: spaceId },
  });
  ok(`created space "${spaceId}"`);
  return space;
}

// Reuse an existing private location's agent policy if present (e.g. from
// `run-data synthetics`), otherwise create a plain agent policy via the API.
async function ensureAgentPolicy(request) {
  const locations = await request('/api/synthetics/private_locations', {
    extraHeaders: PUBLIC_API_HEADERS,
  }).catch(() => []);
  const existingLoc = Array.isArray(locations)
    ? locations.find((l) => !l.isServiceManaged && l.agentPolicyId)
    : undefined;
  if (existingLoc) {
    ok(`reusing agent policy ${existingLoc.agentPolicyId} from location "${existingLoc.label}"`);
    return existingLoc.agentPolicyId;
  }
  const policy = await request('/api/fleet/agent_policies', {
    method: 'POST',
    extraHeaders: PUBLIC_API_HEADERS,
    body: {
      name: `${NAME_PREFIX}-policy-${Date.now()}`,
      namespace: 'default',
      monitoring_enabled: ['logs', 'metrics'],
    },
  });
  const agentPolicyId = policy.item.id;
  ok(`created agent policy ${agentPolicyId}`);
  return agentPolicyId;
}

async function readAgentPolicySpaceIds(request, agentPolicyId) {
  const res = await request(`/api/fleet/agent_policies/${agentPolicyId}`, {
    extraHeaders: PUBLIC_API_HEADERS,
  }).catch(() => undefined);
  // `space_ids` is only present once Fleet is space-aware; [] / undefined means off.
  return res?.item?.space_ids;
}

async function enableSpaceAwareness(request) {
  info('enabling Fleet space awareness (one-way migration) ...');
  await request('/internal/fleet/enable_space_awareness', {
    method: 'POST',
    extraHeaders: INTERNAL_HEADERS,
  }).catch((e) => warn(`enable_space_awareness call returned: ${e.message}`));

  const deadline = Date.now() + 120000;
  while (Date.now() < deadline) {
    const settings = await request('/internal/fleet/settings', {
      extraHeaders: INTERNAL_HEADERS,
    }).catch(() => undefined);
    const status = settings?.item?.use_space_awareness_migration_status;
    if (status === 'success') {
      ok('Fleet space awareness migration: success');
      return true;
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  warn('space-awareness migration did not report success within 120s');
  return false;
}

// Rohan's workaround: create the location in `default`, then share the SO into
// the target space via the core Spaces API (no agent-policy move involved).
async function precreateAndShare(request, agentPolicyId, spaceId) {
  const loc = await request('/api/synthetics/private_locations', {
    method: 'POST',
    extraHeaders: PUBLIC_API_HEADERS,
    body: { label: `${NAME_PREFIX}-shared`, agentPolicyId, geo: { lat: 0, lon: 0 } },
  });
  ok(`created private location "${loc.label}" (${loc.id}) in default`);

  await request('/api/spaces/_update_objects_spaces', {
    method: 'POST',
    body: {
      objects: [{ type: PRIVATE_LOCATION_SO_TYPE, id: loc.id }],
      spacesToAdd: [spaceId],
      spacesToRemove: [],
    },
  });
  ok(`shared location ${loc.id} into space "${spaceId}" via _update_objects_spaces`);
  return loc;
}

async function main() {
  const args = parseArgs(process.argv);
  const auth = { username: args.user, password: args.pass };
  const request = createApi(args.baseUrl, auth);

  info(`Seeding ${args.baseUrl} (space=${args.space})`);

  try {
    await ensureEnabled(request);
  } catch (e) {
    warn(`synthetics enablement call failed (may already be enabled): ${e.message}`);
  }

  await ensureSpace(request, args.space);

  if (args.enableSpaceAwareness) {
    await enableSpaceAwareness(request);
  }

  const agentPolicyId = await ensureAgentPolicy(request);
  const spaceIds = await readAgentPolicySpaceIds(request, agentPolicyId);

  if (args.precreateShare) {
    await precreateAndShare(request, agentPolicyId, args.space);
  }

  ok('Done.');
  info(`agentPolicyId=${agentPolicyId}`);
  info(`space_ids=${spaceIds === undefined ? '(absent → non-space-aware)' : JSON.stringify(spaceIds)}`);
}

main().catch((e) => {
  err(e.stack || e.message || String(e));
  process.exit(1);
});
