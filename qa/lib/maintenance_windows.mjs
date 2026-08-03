// ============================================================
//  lib/maintenance_windows.mjs — shared maintenance-window seeding helpers
//
//  Extracted from the seed-*.mjs scripts so the internal-origin headers,
//  prefix-scoped listing, and idempotent creation live in one place instead
//  of being copy-pasted per feature.
// ============================================================

import { ok } from './kibana.mjs';

// The internal alerting maintenance_window endpoints are versioned and gated on
// the internal-origin header (same as the Synthetics flyout's useMaintenanceWindows()).
export const MW_HEADERS = {
  'elastic-api-version': '2023-10-31',
  'x-elastic-internal-origin': 'kibana',
};

// List maintenance windows created by the seeds, i.e. titled `<prefix>-window-N`.
// Matching the structured suffix (not a bare prefix) keeps a shorter prefix like
// `qa-mw` from swallowing a longer one's windows (`qa-mwd-window-1`).
export async function listMaintenanceWindows(request, prefix = '') {
  const data = await request('/internal/alerting/rules/maintenance_window/_find?per_page=100', {
    method: 'GET',
    extraHeaders: MW_HEADERS,
  }).catch(() => undefined);
  const items = data?.data ?? data?.maintenance_windows ?? [];
  if (!prefix) return items;
  return items.filter((w) => (w.title ?? '').startsWith(`${prefix}-window-`));
}

// Ensure at least `count` maintenance windows named `<prefix>-window-N` exist.
// Idempotent: only creates the missing ones. Returns exactly `count` windows.
export async function ensureMaintenanceWindows(request, { count, prefix }) {
  const existing = await listMaintenanceWindows(request, prefix);
  if (existing.length >= count) {
    ok(`${existing.length} ${prefix} maintenance windows already present`);
    return existing.slice(0, count);
  }
  for (let i = existing.length; i < count; i++) {
    const title = `${prefix}-window-${i + 1}`;
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
  const all = await listMaintenanceWindows(request, prefix);
  return all.slice(0, count);
}
