// ============================================================
//  lib/kibana.mjs — shared helpers for the qa/ tools
//
//  Extracted from qa-shots.mjs so the visual-diff tool
//  (qa-shots.mjs) and the feature-acceptance tool
//  (qa-feature.mjs) share the same logger, login, and
//  readiness logic instead of duplicating it.
// ============================================================

// ── tiny coloured logger ──────────────────────────────────
export const C = {
  g: '\x1b[32m',
  r: '\x1b[31m',
  y: '\x1b[33m',
  b: '\x1b[34m',
  d: '\x1b[2m',
  x: '\x1b[0m',
};
export const ok = (m) => console.log(`${C.g}\u2713${C.x} ${m}`);
export const info = (m) => console.log(`${C.b}\u2192${C.x} ${m}`);
export const warn = (m) => console.log(`${C.y}!${C.x} ${m}`);
export const err = (m) => console.log(`${C.r}\u2717${C.x} ${m}`);

// ── API login: set the session cookie directly on the browser context ─
// Preferred over driving the form — it is immune to the login page failing to
// render (e.g. CSP blocking its inline bootstrap script in headless Chromium).
// The APIRequestContext from `context.request` shares the cookie jar with the
// context's pages, so a successful call authenticates subsequent navigations.
export async function apiLogin(request, baseUrl, auth) {
  try {
    const res = await request.post(`${baseUrl}/internal/security/login`, {
      headers: {
        'kbn-xsrf': 'true',
        'Content-Type': 'application/json',
        'x-elastic-internal-origin': 'kibana',
      },
      data: {
        providerType: 'basic',
        providerName: 'basic',
        currentURL: `${baseUrl}/login`,
        params: { username: auth.username, password: auth.password },
      },
    });
    return res.ok();
  } catch {
    return false;
  }
}

// ── login once per instance (form-based Kibana security login) ─
export async function login(page, baseUrl, auth, timeout) {
  await page.goto(`${baseUrl}/login?next=%2F`, { waitUntil: 'domcontentloaded', timeout });
  const userField = page.locator('[data-test-subj="loginUsername"]');
  try {
    await userField.waitFor({ state: 'visible', timeout: 15000 });
  } catch {
    return false; // no login form → security disabled or already authenticated
  }
  await userField.fill(auth.username);
  await page.locator('[data-test-subj="loginPassword"]').fill(auth.password);
  await page.locator('[data-test-subj="loginSubmit"]').click();
  try {
    await page.waitForURL((u) => !u.pathname.endsWith('/login'), { timeout });
  } catch {
    warn('Login submitted but did not navigate away from /login — check credentials.');
  }
  return true;
}

// ── poll /api/status until Kibana reports available ──────────
export async function waitForKibana(request, baseUrl, auth, timeout) {
  const deadline = Date.now() + timeout;
  const headers = {
    Authorization: 'Basic ' + Buffer.from(`${auth.username}:${auth.password}`).toString('base64'),
  };
  while (Date.now() < deadline) {
    try {
      const res = await request.get(`${baseUrl}/api/status`, { headers, timeout: 10000 });
      if (res.ok()) {
        const body = await res.json().catch(() => null);
        const level = body?.status?.overall?.level;
        if (!level || level === 'available') return true;
      }
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 4000));
  }
  return false;
}

// ── Basic-auth header for direct Kibana API calls (data seeding) ─
export function basicAuthHeaders(auth, extra = {}) {
  return {
    Authorization: 'Basic ' + Buffer.from(`${auth.username}:${auth.password}`).toString('base64'),
    'kbn-xsrf': 'true',
    'Content-Type': 'application/json',
    ...extra,
  };
}
