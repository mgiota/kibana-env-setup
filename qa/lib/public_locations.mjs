// ============================================================
//  lib/public_locations.mjs — probe Elastic-managed Synthetics
//  public locations (TLS + service auth) and plan monitor migrations.
// ============================================================

import tls from 'node:tls';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const DEFAULT_MANIFEST_URL = 'https://manifest.synthetics.elastic.dev/v1/manifest.json';
export const DEFAULT_REMOTE_ES_CONFIG = join(homedir(), '.kibana-remote-es.yml');

const SYNC_PROBE_BODY = {
  monitors: [],
  output: { hosts: ['https://example.invalid:443'], api_key: 'probe' },
  stack_version: '9.0.0',
  license_level: 'platinum',
  license_issued_to: 'probe',
};

export function parseServiceCredsFromYaml(yamlPath = DEFAULT_REMOTE_ES_CONFIG) {
  try {
    const text = readFileSync(yamlPath, 'utf8');
    // Match xpack.uptime.service (or a top-level service:) — not elasticsearch credentials.
    const serviceMatch = text.match(
      /service:\s*\n((?:\s{4,}.+\n)+)/m
    );
    const block = serviceMatch?.[1] ?? '';
    const username = block.match(/^\s*username:\s*(\S+)\s*$/m)?.[1];
    const password = block.match(/^\s*password:\s*(\S+)\s*$/m)?.[1];
    if (username && password) {
      return { username, password, source: yamlPath };
    }
  } catch {
    /* optional file */
  }
  return null;
}

export async function fetchManifestLocations(manifestUrl = DEFAULT_MANIFEST_URL) {
  const res = await fetch(manifestUrl);
  if (!res.ok) {
    throw new Error(`manifest ${manifestUrl} -> ${res.status}`);
  }
  const body = await res.json();
  const raw = body.locations ?? body;
  return Object.entries(raw).map(([id, loc]) => ({
    id,
    url: loc.url,
    label: loc.geo?.name ?? id,
  }));
}

export function checkTlsCert(hostname, port = 443) {
  return new Promise((resolve) => {
    const socket = tls.connect(
      { host: hostname, port, servername: hostname, rejectUnauthorized: false },
      () => {
        const cert = socket.getPeerCertificate();
        socket.end();
        if (!cert?.valid_to) {
          resolve({ ok: false, reason: 'no certificate' });
          return;
        }
        const validTo = new Date(cert.valid_to);
        const expired = validTo.getTime() < Date.now();
        resolve({
          ok: !expired,
          reason: expired ? 'certificate expired' : 'ok',
          validTo: validTo.toISOString(),
        });
      }
    );
    socket.setTimeout(15000, () => {
      socket.destroy();
      resolve({ ok: false, reason: 'tls timeout' });
    });
    socket.on('error', (e) => resolve({ ok: false, reason: e.message }));
  });
}

export async function probeServiceAuth(baseUrl, serviceAuth) {
  const url = `${baseUrl.replace(/\/$/, '')}/monitors/sync`;
  const headers = {
    'Content-Type': 'application/json',
    'x-kibana-version': '9.0.0',
    Authorization:
      'Basic ' + Buffer.from(`${serviceAuth.username}:${serviceAuth.password}`).toString('base64'),
  };
  try {
    const res = await fetch(url, { method: 'PUT', headers, body: JSON.stringify(SYNC_PROBE_BODY) });
    const text = await res.text();
    let reason;
    try {
      reason = JSON.parse(text)?.reason;
    } catch {
      reason = text.slice(0, 120);
    }
    // 400 = auth accepted, payload rejected; 401/403 = auth broken.
    if (res.status === 400) {
      return { ok: true, reason: 'auth ok' };
    }
    if (res.status === 401 || res.status === 403) {
      return { ok: false, reason: reason ?? `http ${res.status}` };
    }
    return { ok: true, reason: `http ${res.status}` };
  } catch (e) {
    return { ok: false, reason: e.message };
  }
}

export async function probeLocation(location, serviceAuth) {
  const hostname = new URL(location.url).hostname;
  const tlsResult = await checkTlsCert(hostname);
  if (!tlsResult.ok) {
    return { ...location, healthy: false, issues: [tlsResult.reason], tls: tlsResult };
  }
  const authResult = await probeServiceAuth(location.url, serviceAuth);
  if (!authResult.ok) {
    return {
      ...location,
      healthy: false,
      issues: [authResult.reason],
      tls: tlsResult,
      auth: authResult,
    };
  }
  return { ...location, healthy: true, issues: [], tls: tlsResult, auth: authResult };
}

export async function probeAllLocations(locations, serviceAuth) {
  const results = [];
  for (const loc of locations) {
    results.push(await probeLocation(loc, serviceAuth));
  }
  return results;
}

export function pickFallbackLocation(probedLocations, preferredId) {
  if (preferredId) {
    const preferred = probedLocations.find((l) => l.id === preferredId);
    if (!preferred?.healthy) {
      throw new Error(`fallback location "${preferredId}" is not healthy`);
    }
    return preferred;
  }
  const healthy = probedLocations.filter((l) => l.healthy);
  if (healthy.length === 0) {
    throw new Error('no healthy public locations found in manifest');
  }
  const qa = healthy.find((l) => l.id.includes('qa'));
  return qa ?? healthy[0];
}

export function planMonitorMigrations({
  monitors,
  brokenLocationIds,
  fallbackLocation,
  serviceLocationsById,
}) {
  const broken = new Set(brokenLocationIds);
  const plans = [];

  for (const monitor of monitors) {
    const locations = monitor.locations ?? [];
    const brokenUsed = locations.filter((l) => broken.has(l.id));
    if (brokenUsed.length === 0) continue;

    const kept = locations.filter((l) => !broken.has(l.id));
    const hasServiceManaged = kept.some((l) => l.isServiceManaged);
    const hadOnlyBrokenPublic =
      locations.every((l) => broken.has(l.id) || !l.isServiceManaged) &&
      locations.some((l) => l.isServiceManaged && broken.has(l.id));

    let next = kept;
    if (
      hadOnlyBrokenPublic ||
      (brokenUsed.length > 0 && !kept.some((l) => l.isServiceManaged))
    ) {
      const fallback = serviceLocationsById.get(fallbackLocation.id);
      if (!fallback) {
        plans.push({
          monitor,
          skipped: true,
          reason: `fallback ${fallbackLocation.id} not returned by Kibana locations API`,
        });
        continue;
      }
      if (!next.some((l) => l.id === fallback.id)) {
        next = [...next, fallback];
      }
    }

    if (next.length === 0) {
      plans.push({ monitor, skipped: true, reason: 'monitor would have zero locations' });
      continue;
    }

    plans.push({
      monitor,
      skipped: false,
      before: locations.map((l) => l.id),
      after: next.map((l) => l.id),
      attributes: { locations: next },
    });
  }

  return plans;
}
