// ============================================================
//  lib/synthetics.mjs — shared Synthetics seeding helpers
//
//  Reused by the seed-*.mjs scripts so the request wrapper,
//  enablement, private-location, and monitor-creation logic
//  live in one place instead of being copy-pasted per feature.
// ============================================================

import { ok, basicAuthHeaders } from './kibana.mjs';

export const PUBLIC_API_HEADERS = { 'elastic-api-version': '2023-10-31' };
// The project push/delete routes are versioned public routes; the internal-origin
// header lets them resolve without the caller pinning an api version.
export const PROJECT_HEADERS = {
  'elastic-api-version': '2023-10-31',
  'x-elastic-internal-origin': 'kibana',
};

// ── request wrapper: basic-auth JSON fetch that throws on non-2xx ─
export const createApi = (baseUrl, auth) => {
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

export async function ensureEnabled(request) {
  await request('/internal/synthetics/service/enablement', { method: 'PUT' });
  ok('synthetics enabled');
}

// Returns the first existing private location, or creates one (with a fresh
// Fleet agent policy) if none exist. `labelPrefix` names the created policy.
export async function ensurePrivateLocation(request, labelPrefix = 'qa') {
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
      name: `${labelPrefix}-policy-${Date.now()}`,
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

// List ui-origin monitors whose name matches `query` (a name prefix works).
export async function listMonitors(request, query = '') {
  const data = await request(
    `/api/synthetics/monitors?perPage=1000${query ? `&query=${encodeURIComponent(query)}` : ''}`,
    { extraHeaders: PUBLIC_API_HEADERS }
  );
  return data?.monitors ?? [];
}

// List the seed's monitors, i.e. those named `<namePrefix>-monitor-N`. Filters
// client-side on the exact structured name: the server `query` param does a
// broad fuzzy match (returns unrelated monitors), so it can't be trusted for
// existence checks — using it caused seeds to wrongly report "N already present"
// and skip creation.
export async function listSeededMonitors(request, namePrefix) {
  const monitors = await listMonitors(request);
  return monitors.filter((m) => (m.name ?? '').startsWith(`${namePrefix}-monitor-`));
}

// Ensure at least `count` ui-origin HTTP monitors named `<namePrefix>-monitor-N`
// exist on `location`. Idempotent by exact name prefix. When `maintenanceWindows`
// (an array of ids) is given, the created monitors have them attached.
export async function ensureUiMonitors(
  request,
  { location, count, namePrefix, maintenanceWindows }
) {
  const existing = await listSeededMonitors(request, namePrefix);
  if (existing.length >= count) {
    ok(`${existing.length} ${namePrefix} monitors already present`);
    return existing;
  }
  for (let i = existing.length; i < count; i++) {
    await createUiMonitor(request, {
      name: `${namePrefix}-monitor-${i + 1}`,
      url: `https://example.com/${i + 1}`,
      locationId: location.id,
      maintenanceWindows,
    });
  }
  return listSeededMonitors(request, namePrefix);
}

// Clear maintenance windows from the seed's monitors (named `<namePrefix>-monitor-N`).
// The edit route merges the request body over the stored monitor and *replaces*
// (not deep-merges) non-metadata keys, so PUT-ing `[]` removes all attached windows.
// Idempotent: monitors already window-free are skipped to avoid needless Fleet
// re-syncs (each edit bumps the revision and pushes to the service). Returns the
// number actually cleared.
export async function clearMonitorMaintenanceWindows(request, namePrefix) {
  const monitors = await listSeededMonitors(request, namePrefix);
  let cleared = 0;
  for (const m of monitors) {
    const id = m.config_id ?? m.id;
    const current = m.maintenance_windows;
    if (Array.isArray(current) && current.length === 0) continue;
    await request(`/api/synthetics/monitors/${id}`, {
      method: 'PUT',
      extraHeaders: PUBLIC_API_HEADERS,
      body: { maintenance_windows: [] },
    });
    cleared++;
  }
  ok(`cleared maintenance windows on ${cleared}/${monitors.length} ${namePrefix} monitor(s)`);
  return cleared;
}

// Create a single ui-origin HTTP monitor on the given private location.
// `maintenanceWindows` (optional) attaches maintenance-window ids at creation
// time so read views (e.g. the monitor details panel) can surface them.
export async function createUiMonitor(
  request,
  { name, url, locationId, enabled = true, maintenanceWindows }
) {
  await request('/api/synthetics/monitors', {
    method: 'POST',
    extraHeaders: PUBLIC_API_HEADERS,
    body: {
      type: 'http',
      name,
      urls: url,
      private_locations: [locationId],
      enabled,
      alert: { status: { enabled: true } },
      ...(maintenanceWindows?.length ? { maintenance_windows: maintenanceWindows } : {}),
    },
  });
  ok(
    `created ui monitor ${name} (enabled=${enabled}` +
      `${maintenanceWindows?.length ? `, mws=${maintenanceWindows.length}` : ''})`
  );
}

// Push a set of project monitors. Re-pushing the same journey ids updates them
// in place, so this is naturally idempotent. `monitors` follows the project
// (@elastic/synthetics) monitor shape; `privateLocations` matches by label or id.
export async function pushProjectMonitors(request, project, monitors, { spaceId } = {}) {
  const base = `${spaceId ? `/s/${spaceId}` : ''}/api/synthetics/project/${project}/monitors`;
  await request(`${base}/_bulk_update`, {
    method: 'PUT',
    extraHeaders: PROJECT_HEADERS,
    body: { monitors },
  });
  ok(`pushed ${monitors.length} project monitor(s) under project "${project}"`);
  return monitors;
}

// Delete project monitors by journey id.
export async function deleteProjectMonitors(request, project, ids, { spaceId } = {}) {
  const base = `${spaceId ? `/s/${spaceId}` : ''}/api/synthetics/project/${project}/monitors`;
  await request(`${base}/_bulk_delete`, {
    method: 'DELETE',
    extraHeaders: PROJECT_HEADERS,
    body: { monitors: ids },
  });
  ok(`deleted ${ids.length} project monitor(s) from project "${project}"`);
}
