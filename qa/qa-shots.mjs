#!/usr/bin/env node
// ============================================================
//  qa-shots.mjs — deterministic Kibana screenshot + visual-diff QA
//
//  Captures the same set of routes across one or more Kibana
//  instances (e.g. main vs feature worktree), pixel-diffs the
//  pairs against a baseline, and writes a self-contained HTML
//  report for human-in-the-loop review.
//
//  USAGE:
//    node qa-shots.mjs                          # uses ./config.json
//    node qa-shots.mjs --config other.json
//    node qa-shots.mjs --out ~/Documents/Development/qa-runs
//    node qa-shots.mjs --only slo-list,synthetics-monitors
//    node qa-shots.mjs --instances feat         # capture only, no compare
//    node qa-shots.mjs --no-compare             # screenshots only
//    node qa-shots.mjs --headed                 # watch the browser
//
//  Exit code: 0 if all routes within threshold, 1 if any regression
//  (so it can be used in a git hook / CI later).
// ============================================================

import { chromium } from 'playwright';
import { PNG } from 'pngjs';
import pixelmatch from 'pixelmatch';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { ok, info, warn, err, login, waitForKibana } from './lib/kibana.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ── arg parsing ───────────────────────────────────────────
function parseArgs(argv) {
  const a = { config: path.join(__dirname, 'config.json'), out: null, only: null, instances: null, compare: true, headed: false };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--config') a.config = argv[++i];
    else if (t === '--out') a.out = argv[++i];
    else if (t === '--only') a.only = argv[++i].split(',').map((s) => s.trim()).filter(Boolean);
    else if (t === '--instances') a.instances = argv[++i].split(',').map((s) => s.trim()).filter(Boolean);
    else if (t === '--no-compare') a.compare = false;
    else if (t === '--headed') a.headed = true;
    else if (t === '--help' || t === '-h') { printHelp(); process.exit(0); }
    else { err(`Unknown arg: ${t}`); printHelp(); process.exit(2); }
  }
  return a;
}
function printHelp() {
  console.log(`qa-shots — Kibana screenshot + visual-diff QA

  node qa-shots.mjs [--config FILE] [--out DIR] [--only r1,r2]
                    [--instances i1,i2] [--no-compare] [--headed]`);
}

// ── PNG padding so two differently-sized shots can be diffed ─
function padTo(src, width, height) {
  if (src.width === width && src.height === height) return src;
  const dst = new PNG({ width, height });
  dst.data.fill(0);
  PNG.bitblt(src, dst, 0, 0, src.width, src.height, 0, 0);
  return dst;
}

function diffPair(basePath, candPath, outPath, pmThreshold) {
  const a = PNG.sync.read(fs.readFileSync(basePath));
  const b = PNG.sync.read(fs.readFileSync(candPath));
  const width = Math.max(a.width, b.width);
  const height = Math.max(a.height, b.height);
  const ap = padTo(a, width, height);
  const bp = padTo(b, width, height);
  const out = new PNG({ width, height });
  const numDiff = pixelmatch(ap.data, bp.data, out.data, width, height, {
    threshold: pmThreshold,
    alpha: 0.4,
    diffColor: [255, 0, 255],
  });
  fs.writeFileSync(outPath, PNG.sync.write(out));
  const total = width * height;
  return { numDiff, total, pct: total ? (100 * numDiff) / total : 0, dimsDiffer: a.width !== b.width || a.height !== b.height };
}

async function captureInstance(browser, inst, cfg, routes, runDir) {
  const label = inst.label;
  const dir = path.join(runDir, label);
  fs.mkdirSync(dir, { recursive: true });

  // isolated context => its own cookie jar (host/port-independent isolation)
  const context = await browser.newContext({ viewport: cfg.viewport, ignoreHTTPSErrors: true });
  const results = {};
  try {
    info(`[${label}] waiting for Kibana at ${inst.baseUrl} ...`);
    const up = await waitForKibana(context.request, inst.baseUrl, cfg.auth, cfg.readinessTimeoutMs);
    if (!up) { warn(`[${label}] Kibana never reported available — capturing anyway.`); }

    const page = await context.newPage();
    const didLogin = await login(page, inst.baseUrl, cfg.auth, cfg.navTimeoutMs);
    ok(`[${label}] ${didLogin ? 'logged in' : 'no login required'}`);

    for (const route of routes) {
      const url = `${inst.baseUrl}${route.path}`;
      const shotPath = path.join(dir, `${route.name}.png`);
      try {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: cfg.navTimeoutMs });
        if (route.waitForSelector) {
          try {
            await page.locator(route.waitForSelector).first().waitFor({ state: 'visible', timeout: cfg.navTimeoutMs });
          } catch {
            warn(`[${label}] ${route.name}: waitForSelector not found, screenshotting after settle anyway.`);
          }
        }
        await page.waitForTimeout(cfg.settleMs);
        const mask = (route.mask || []).map((sel) => page.locator(sel));
        await page.screenshot({ path: shotPath, fullPage: !!cfg.fullPage, mask, animations: 'disabled', caret: 'hide' });
        results[route.name] = { ok: true, file: path.relative(runDir, shotPath) };
        ok(`[${label}] ${route.name}`);
      } catch (e) {
        results[route.name] = { ok: false, error: String(e.message || e) };
        err(`[${label}] ${route.name}: ${e.message || e}`);
      }
    }
  } finally {
    await context.close();
  }
  return results;
}

function buildReport(runDir, cfg, captured, diffs, meta) {
  const labels = meta.instanceLabels;
  const baseline = cfg.compare?.baseline;
  const threshold = cfg.compare?.diffThresholdPct ?? 1.0;
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  const rows = cfg.routes.map((route) => {
    const cells = labels.map((label) => {
      const r = captured[label]?.[route.name];
      if (r?.ok) return `<td><a href="${esc(r.file)}" target="_blank"><img src="${esc(r.file)}" loading="lazy"></a><div class="cap">${esc(label)}</div></td>`;
      return `<td class="missing"><div class="cap">${esc(label)}<br><span class="err">${esc(r?.error || 'not captured')}</span></div></td>`;
    }).join('');

    let diffCell = '<td class="na">—</td>';
    const d = diffs[route.name];
    if (d) {
      if (d.error) {
        diffCell = `<td class="na">${esc(d.error)}</td>`;
      } else {
        const pass = d.pct <= threshold;
        const badge = pass ? '<span class="pass">PASS</span>' : '<span class="fail">FAIL</span>';
        const dimsNote = d.dimsDiffer ? '<div class="cap warn">⚠ dimensions differ (padded)</div>' : '';
        diffCell = `<td><a href="${esc(d.file)}" target="_blank"><img src="${esc(d.file)}" loading="lazy"></a><div class="cap">${badge} ${d.pct.toFixed(3)}% changed</div>${dimsNote}</td>`;
      }
    }
    const routeFail = d && !d.error && d.pct > threshold;
    return `<tr class="${routeFail ? 'rowfail' : ''}"><th>${esc(route.name)}<div class="path">${esc(route.path)}</div></th>${cells}${diffCell}</tr>`;
  }).join('\n');

  const headCells = labels.map((l) => `<th>${esc(l)}${l === baseline ? ' <span class="base">baseline</span>' : ''}</th>`).join('');
  const totalFail = Object.values(diffs).filter((d) => d && !d.error && d.pct > threshold).length;
  const banner = totalFail > 0
    ? `<div class="summary fail">${totalFail} route(s) exceed the ${threshold}% threshold — review needed.</div>`
    : `<div class="summary pass">All compared routes within the ${threshold}% threshold.</div>`;

  return `<!doctype html><html><head><meta charset="utf-8"><title>Kibana QA — ${esc(meta.stamp)}</title>
<style>
  body { font: 14px -apple-system, system-ui, sans-serif; margin: 0; background: #0f1115; color: #e6e6e6; }
  header { padding: 18px 24px; background: #161a22; border-bottom: 1px solid #2a2f3a; }
  h1 { margin: 0 0 4px; font-size: 18px; }
  .meta { color: #9aa4b2; font-size: 12px; }
  .meta code { color: #cbd5e1; }
  .summary { margin: 16px 24px; padding: 12px 16px; border-radius: 8px; font-weight: 600; }
  .summary.pass { background: #10261a; color: #7ee2a8; border: 1px solid #1d4d33; }
  .summary.fail { background: #2a1416; color: #ff9aa2; border: 1px solid #5a2329; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border: 1px solid #2a2f3a; padding: 8px; vertical-align: top; text-align: left; }
  th { background: #161a22; font-size: 12px; white-space: nowrap; }
  td img { max-width: 360px; width: 100%; height: auto; border: 1px solid #2a2f3a; border-radius: 4px; display: block; background:#fff; }
  .cap { margin-top: 6px; font-size: 12px; color: #9aa4b2; }
  .cap.warn { color: #f0c674; }
  .path { font-weight: 400; color: #6b7280; font-size: 11px; }
  .pass { color: #7ee2a8; font-weight: 700; }
  .fail { color: #ff9aa2; font-weight: 700; }
  .base { color: #7aa2f7; font-weight: 400; font-size: 11px; }
  .missing, .na { background: #14171d; color: #6b7280; }
  .err { color: #ff9aa2; }
  tr.rowfail th { box-shadow: inset 3px 0 0 #ff5b66; }
</style></head><body>
<header>
  <h1>Kibana QA — visual comparison</h1>
  <div class="meta">Run <code>${esc(meta.stamp)}</code> · baseline <code>${esc(baseline || '—')}</code> ·
  threshold <code>${esc(threshold)}%</code> · instances ${labels.map((l) => `<code>${esc(l)}</code>`).join(' ')}</div>
</header>
${banner}
<table>
  <thead><tr><th>route</th>${headCells}<th>diff vs ${esc(baseline || 'baseline')}</th></tr></thead>
  <tbody>
${rows}
  </tbody>
</table>
</body></html>`;
}

// ── main ──────────────────────────────────────────────────
async function main() {
  const args = parseArgs(process.argv);
  if (!fs.existsSync(args.config)) { err(`Config not found: ${args.config}`); process.exit(2); }
  const cfg = JSON.parse(fs.readFileSync(args.config, 'utf8'));

  // defaults
  cfg.viewport ??= { width: 1440, height: 900 };
  cfg.settleMs ??= 2500;
  cfg.navTimeoutMs ??= 90000;
  cfg.readinessTimeoutMs ??= 180000;
  cfg.compare ??= { baseline: cfg.instances?.[0]?.label, diffThresholdPct: 1.0, pixelmatchThreshold: 0.12 };

  let instances = cfg.instances || [];
  if (args.instances) instances = instances.filter((i) => args.instances.includes(i.label));
  if (!instances.length) { err('No instances selected.'); process.exit(2); }

  let routes = cfg.routes || [];
  if (args.only) routes = routes.filter((r) => args.only.includes(r.name));
  if (!routes.length) { err('No routes selected.'); process.exit(2); }

  const stamp = new Date().toISOString().replace(/[:.]/g, '-').replace('T', '_').slice(0, 19);
  const outBase = args.out || cfg.outDir || path.join(os.homedir(), 'Documents', 'Development', 'qa-runs');
  const runDir = path.join(outBase, stamp);
  fs.mkdirSync(runDir, { recursive: true });
  info(`Run dir: ${runDir}`);
  info(`Instances: ${instances.map((i) => i.label).join(', ')} · Routes: ${routes.map((r) => r.name).join(', ')}`);

  const browser = await chromium.launch({ headless: !args.headed });
  const captured = {};
  try {
    for (const inst of instances) {
      captured[inst.label] = await captureInstance(browser, inst, cfg, routes, runDir);
    }
  } finally {
    await browser.close();
  }

  // ── compare ──
  const diffs = {};
  const baseline = cfg.compare?.baseline;
  const doCompare = args.compare && instances.length > 1 && baseline && instances.some((i) => i.label === baseline);
  if (doCompare) {
    const diffDir = path.join(runDir, 'diff');
    fs.mkdirSync(diffDir, { recursive: true });
    const candidates = instances.map((i) => i.label).filter((l) => l !== baseline);
    for (const route of routes) {
      // (first candidate only is shown in the simple report; extend here for >2 instances)
      const cand = candidates[0];
      const basePath = path.join(runDir, baseline, `${route.name}.png`);
      const candPath = path.join(runDir, cand, `${route.name}.png`);
      if (!fs.existsSync(basePath) || !fs.existsSync(candPath)) {
        diffs[route.name] = { error: 'missing screenshot(s) — capture failed' };
        continue;
      }
      const outPath = path.join(diffDir, `${cand}__vs__${baseline}__${route.name}.png`);
      try {
        const res = diffPair(basePath, candPath, outPath, cfg.compare.pixelmatchThreshold ?? 0.12);
        res.file = path.relative(runDir, outPath);
        res.candidate = cand;
        diffs[route.name] = res;
        const pass = res.pct <= (cfg.compare.diffThresholdPct ?? 1.0);
        (pass ? ok : warn)(`diff ${route.name}: ${res.pct.toFixed(3)}% changed ${pass ? '(within threshold)' : '(REGRESSION)'}`);
      } catch (e) {
        diffs[route.name] = { error: String(e.message || e) };
        err(`diff ${route.name}: ${e.message || e}`);
      }
    }
  } else if (args.compare && instances.length > 1) {
    warn(`Baseline "${baseline}" not in selected instances — skipping comparison.`);
  }

  // ── write report + summary ──
  const meta = { stamp, instanceLabels: instances.map((i) => i.label) };
  const reportPath = path.join(runDir, 'report.html');
  fs.writeFileSync(reportPath, buildReport(runDir, cfg, captured, diffs, meta));
  fs.writeFileSync(path.join(runDir, 'summary.json'), JSON.stringify({ stamp, captured, diffs, threshold: cfg.compare?.diffThresholdPct }, null, 2));

  console.log('');
  ok(`Report: ${reportPath}`);

  const regressions = Object.values(diffs).filter((d) => d && !d.error && d.pct > (cfg.compare?.diffThresholdPct ?? 1.0)).length;
  if (regressions > 0) { err(`${regressions} route(s) exceeded threshold.`); process.exit(1); }
  process.exit(0);
}

main().catch((e) => { err(e.stack || e.message || String(e)); process.exit(1); });
