#!/usr/bin/env node
// ============================================================
//  seed-readonly-user.mjs — provision a Synthetics READ-ONLY
//  Kibana user + role for QA of PR elastic/kibana#281894.
//
//  Profiles:
//    minimal   — Kibana uptime:read only (mirrors the PR Scout API test).
//                  Reproduces the MW 403 toasts; may also show unrelated
//                  field_caps errors because there is no ES index read.
//    realistic — uptime:read + read on synthetics-* (and CCS alias) so the
//                  UI can load data views/charts like a typical deployment.
//                  Still omits read-maintenance-window — the MW bug under test.
//
//  USAGE:
//    node seed-readonly-user.mjs --base-url http://localhost:5601
//    node seed-readonly-user.mjs --profile realistic --base-url ...
// ============================================================

import { info, ok, err } from './lib/kibana.mjs';
import { createApi } from './lib/synthetics.mjs';

const PROFILES = {
  minimal: {
    role: 'qa_synthetics_read',
    roUser: 'qa-synthetics-readonly',
    roPass: 'qa-readonly-password',
    elasticsearch: { cluster: [], indices: [], run_as: [] },
  },
  realistic: {
    role: 'qa_synthetics_read_realistic',
    roUser: 'qa-synthetics-readonly-realistic',
    roPass: 'qa-readonly-password',
    elasticsearch: {
      cluster: [],
      indices: [
        {
          names: ['synthetics-*', 'remote_cluster:synthetics-*', '*:synthetics-*'],
          privileges: ['read', 'view_index_metadata'],
        },
      ],
      run_as: [],
    },
  },
};

function parseArgs(argv) {
  const a = {
    baseUrl: process.env.QA_BASE_URL || 'http://localhost:5601',
    user: process.env.QA_ADMIN_USERNAME || 'elastic',
    pass: process.env.QA_ADMIN_PASSWORD || 'changeme',
    profile: 'minimal',
  };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--base-url') a.baseUrl = argv[++i];
    else if (t === '--user') a.user = argv[++i];
    else if (t === '--pass') a.pass = argv[++i];
    else if (t === '--profile') a.profile = argv[++i];
    else if (t === '--role') a.role = argv[++i];
    else if (t === '--ro-user') a.roUser = argv[++i];
    else if (t === '--ro-pass') a.roPass = argv[++i];
    else if (t === '--help' || t === '-h') {
      console.log(
        'seed-readonly-user --base-url URL [--profile minimal|realistic] [--user ADMIN] [--pass ADMIN_PW]'
      );
      process.exit(0);
    } else {
      err(`Unknown arg: ${t}`);
      process.exit(2);
    }
  }
  if (!PROFILES[a.profile]) {
    err(`Unknown profile "${a.profile}" — use minimal or realistic`);
    process.exit(2);
  }
  const defaults = PROFILES[a.profile];
  return {
    ...defaults,
    ...a,
    role: a.role ?? defaults.role,
    roUser: a.roUser ?? defaults.roUser,
    roPass: a.roPass ?? defaults.roPass,
  };
}

const ROLE_HEADERS = { 'elastic-api-version': '2023-10-31' };
const USER_HEADERS = { 'x-elastic-internal-origin': 'kibana' };

async function main() {
  const args = parseArgs(process.argv);
  const request = createApi(args.baseUrl, { username: args.user, password: args.pass });

  info(
    `Seeding ${args.profile} read-only user on ${args.baseUrl} (role=${args.role}, user=${args.roUser}) as ${args.user}`
  );

  await request(`/api/security/role/${encodeURIComponent(args.role)}`, {
    method: 'PUT',
    extraHeaders: ROLE_HEADERS,
    body: {
      elasticsearch: args.elasticsearch,
      kibana: [{ base: [], feature: { uptime: ['read'] }, spaces: ['*'] }],
    },
  });
  ok(`role ${args.role} upserted (uptime: ['read']${args.profile === 'realistic' ? ', synthetics-* read' : ''})`);

  await request(`/internal/security/users/${encodeURIComponent(args.roUser)}`, {
    method: 'POST',
    extraHeaders: USER_HEADERS,
    body: {
      username: args.roUser,
      password: args.roPass,
      roles: [args.role],
      full_name: `QA Synthetics Read Only (${args.profile})`,
    },
  });
  ok(`user ${args.roUser} upserted`);

  ok(`Done. Log in as ${args.roUser} / ${args.roPass}`);
}

main().catch((e) => {
  err(e.stack || e.message || String(e));
  process.exit(1);
});
