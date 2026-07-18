#!/usr/bin/env node
// ============================================================
//  qa-feature.mjs — feature-acceptance QA for Kibana.
//
//  Unlike qa-shots.mjs (which pixel-diffs feat vs main to prove
//  nothing changed), this drives a NEW feature through an
//  interactive Playwright scenario on a single instance, captures
//  key-state screenshots, and records breakages (console errors +
//  failed / 5xx requests) for human-in-the-loop PR review.
//
//  Use it for additive features where "compare against main" is
//  the wrong model (main doesn't have the feature yet).
//
//  USAGE:
//    node qa-feature.mjs --scenario scenarios/maintenance-windows.json
//    node qa-feature.mjs --scenario ... --base-url http://kibana-feat.local:5601
//    node qa-feature.mjs --scenario ... --headed
//    node qa-feature.mjs --scenario ... --out ~/Documents/Development/qa-runs
//    node qa-feature.mjs --scenario ... --fail-on-breakage
//
//  Exit code: 0 on success, 1 if a required step failed (or any
//  breakage when --fail-on-breakage is set).
// ============================================================

import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { ok, info, warn, err, login, waitForKibana } from './lib/kibana.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const a = {
    scenario: null,
    baseUrl: null,
    out: null,
    headed: false,
    failOnBreakage: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--scenario') a.scenario = argv[++i];
    else if (t === '--base-url') a.baseUrl = argv[++i];
    else if (t === '--out') a.out = argv[++i];
    else if (t === '--headed') a.headed = true;
    else if (t === '--fail-on-breakage') a.failOnBreakage = true;
    else if (t === '--help' || t === '-h') {
      console.log(
        'qa-feature --scenario FILE [--base-url URL] [--out DIR] [--headed] [--fail-on-breakage]'
      );
      process.exit(0);
    } else {
      err(`Unknown arg: ${t}`);
      process.exit(2);
    }
  }
  return a;
}

const testSubj = (v) => `[data-test-subj="${v}"]`;

// Resolve a Playwright locator from a step's target description.
function resolveLocator(page, step, scope) {
  const root = scope ?? page;
  if (step.testSubj) return root.locator(testSubj(step.testSubj));
  if (step.selector) return root.locator(step.selector);
  if (step.text) return root.locator(`text=${step.text}`);
  throw new Error('step target requires one of: testSubj, selector, text');
}

function resolveWaitTarget(page, waitFor) {
  if (typeof waitFor === 'string') return page.locator(testSubj(waitFor));
  if (waitFor.testSubj) return page.locator(testSubj(waitFor.testSubj));
  if (waitFor.selector) return page.locator(waitFor.selector);
  if (waitFor.text) return page.locator(`text=${waitFor.text}`);
  throw new Error('waitFor requires testSubj, selector or text');
}

async function takeScreenshot(page, cfg, dir, step, results) {
  const shotPath = path.join(dir, `${step.name}.png`);
  const mask = (cfg.masks || []).map((sel) => page.locator(sel));
  await page.screenshot({ path: shotPath, mask, animations: 'disabled', caret: 'hide' });
  results.push({ name: step.name, caption: step.caption || step.name, file: path.basename(shotPath) });
  ok(`screenshot ${step.name}`);
}

async function runStep(page, cfg, dir, step, screenshots) {
  const timeout = step.timeoutMs ?? cfg.navTimeoutMs;
  switch (step.action) {
    case 'goto': {
      await page.goto(`${cfg.instance.baseUrl}${step.path}`, {
        waitUntil: 'domcontentloaded',
        timeout,
      });
      if (step.waitFor) {
        await resolveWaitTarget(page, step.waitFor).first().waitFor({ state: 'visible', timeout });
      }
      await page.waitForTimeout(cfg.settleMs ?? 1000);
      break;
    }
    case 'waitFor': {
      await resolveWaitTarget(page, step).first().waitFor({ state: 'visible', timeout });
      await page.waitForTimeout(cfg.settleMs ?? 500);
      break;
    }
    case 'click': {
      const loc = resolveLocator(page, step).first();
      await loc.waitFor({ state: 'visible', timeout });
      await loc.click();
      await page.waitForTimeout(step.settleMs ?? 500);
      break;
    }
    case 'fill': {
      const loc = resolveLocator(page, step).first();
      await loc.fill(step.value ?? '');
      break;
    }
    case 'comboBoxSelect': {
      const scope = step.within ? page.locator(testSubj(step.within)) : page;
      const input = scope.locator('[data-test-subj="comboBoxSearchInput"]').first();
      await input.waitFor({ state: 'visible', timeout });
      await input.click();
      if (step.optionText) {
        await page.locator(`[role="option"]:has-text("${step.optionText}")`).first().click();
      } else {
        await page.locator('[role="option"]').nth(step.index ?? 0).click();
      }
      await page.waitForTimeout(step.settleMs ?? 400);
      break;
    }
    case 'buttonGroupSelect': {
      const scope = step.within ? page.locator(testSubj(step.within)) : page;
      await scope.locator(`text=${step.label}`).first().click();
      break;
    }
    case 'screenshot': {
      await takeScreenshot(page, cfg, dir, step, screenshots);
      break;
    }
    case 'sleep': {
      await page.waitForTimeout(step.ms ?? 1000);
      break;
    }
    default:
      throw new Error(`Unknown step action: ${step.action}`);
  }
}

function attachBreakageListeners(page, breakages) {
  page.on('console', (msg) => {
    if (msg.type() === 'error') {
      breakages.push({ kind: 'console', text: msg.text().slice(0, 500) });
    }
  });
  page.on('pageerror', (e) => {
    breakages.push({ kind: 'pageerror', text: String(e.message || e).slice(0, 500) });
  });
  page.on('requestfailed', (req) => {
    const failure = req.failure()?.errorText || 'failed';
    // Playwright reports aborted navigations as failed; ignore those.
    if (failure === 'net::ERR_ABORTED') return;
    breakages.push({ kind: 'requestfailed', text: `${req.method()} ${req.url()} — ${failure}` });
  });
  page.on('response', (res) => {
    if (res.status() >= 500) {
      breakages.push({ kind: 'http5xx', text: `${res.status()} ${res.request().method()} ${res.url()}` });
    }
  });
}

function buildReport(cfg, meta, screenshots, breakages, steps) {
  const esc = (s) =>
    String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  const shots = screenshots
    .map(
      (s) => `<figure><a href="${esc(s.file)}" target="_blank"><img src="${esc(s.file)}" loading="lazy"></a>
      <figcaption>${esc(s.caption)}</figcaption></figure>`
    )
    .join('\n');

  const breakRows = breakages.length
    ? breakages
        .map((b) => `<tr><td class="kind">${esc(b.kind)}</td><td><code>${esc(b.text)}</code></td></tr>`)
        .join('\n')
    : '<tr><td colspan="2" class="none">No console errors or 5xx/failed requests captured.</td></tr>';

  const stepRows = steps
    .map(
      (s) =>
        `<tr class="${s.status}"><td>${esc(s.action)}</td><td>${esc(s.label)}</td><td>${esc(
          s.status
        )}</td><td>${esc(s.note || '')}</td></tr>`
    )
    .join('\n');

  const banner =
    meta.failed > 0
      ? `<div class="summary fail">${meta.failed} required step(s) failed — review needed.</div>`
      : breakages.length > 0
      ? `<div class="summary warn">All steps passed, but ${breakages.length} breakage(s) were captured — review below.</div>`
      : `<div class="summary pass">All steps passed, no breakages captured.</div>`;

  return `<!doctype html><html><head><meta charset="utf-8"><title>Kibana Feature QA — ${esc(
    cfg.title
  )}</title>
<style>
  body { font: 14px -apple-system, system-ui, sans-serif; margin: 0; background: #0f1115; color: #e6e6e6; }
  header { padding: 18px 24px; background: #161a22; border-bottom: 1px solid #2a2f3a; }
  h1 { margin: 0 0 4px; font-size: 18px; }
  h2 { margin: 24px 24px 8px; font-size: 15px; }
  .meta { color: #9aa4b2; font-size: 12px; }
  .meta code { color: #cbd5e1; }
  .summary { margin: 16px 24px; padding: 12px 16px; border-radius: 8px; font-weight: 600; }
  .summary.pass { background: #10261a; color: #7ee2a8; border: 1px solid #1d4d33; }
  .summary.warn { background: #2a2410; color: #f0c674; border: 1px solid #5a4d1d; }
  .summary.fail { background: #2a1416; color: #ff9aa2; border: 1px solid #5a2329; }
  .gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); gap: 16px; padding: 0 24px; }
  figure { margin: 0; }
  figure img { width: 100%; border: 1px solid #2a2f3a; border-radius: 6px; background: #fff; }
  figcaption { margin-top: 6px; font-size: 12px; color: #9aa4b2; }
  table { border-collapse: collapse; width: calc(100% - 48px); margin: 8px 24px 24px; }
  th, td { border: 1px solid #2a2f3a; padding: 8px; text-align: left; font-size: 12px; vertical-align: top; }
  th { background: #161a22; }
  td.kind { white-space: nowrap; color: #f0c674; }
  td.none { color: #7ee2a8; }
  tr.failed td { background: #2a1416; }
  code { color: #cbd5e1; word-break: break-all; }
</style></head><body>
<header>
  <h1>Feature QA — ${esc(cfg.title)}</h1>
  <div class="meta">Run <code>${esc(meta.stamp)}</code> · instance <code>${esc(
    cfg.instance.label
  )}</code> (<code>${esc(cfg.instance.baseUrl)}</code>)</div>
</header>
${banner}
<h2>Screenshots</h2>
<div class="gallery">
${shots}
</div>
<h2>Steps</h2>
<table><thead><tr><th>action</th><th>target</th><th>status</th><th>note</th></tr></thead><tbody>
${stepRows}
</tbody></table>
<h2>Breakages (console errors / failed / 5xx requests)</h2>
<table><thead><tr><th>kind</th><th>detail</th></tr></thead><tbody>
${breakRows}
</tbody></table>
</body></html>`;
}

const stepLabel = (step) =>
  step.name || step.testSubj || step.selector || step.text || step.path || step.action;

async function main() {
  const args = parseArgs(process.argv);
  if (!args.scenario) {
    err('Missing --scenario FILE');
    process.exit(2);
  }
  const scenarioPath = path.isAbsolute(args.scenario)
    ? args.scenario
    : path.join(__dirname, args.scenario);
  if (!fs.existsSync(scenarioPath)) {
    err(`Scenario not found: ${scenarioPath}`);
    process.exit(2);
  }
  const cfg = JSON.parse(fs.readFileSync(scenarioPath, 'utf8'));
  cfg.viewport ??= { width: 1440, height: 900 };
  cfg.settleMs ??= 1000;
  cfg.navTimeoutMs ??= 90000;
  cfg.readinessTimeoutMs ??= 180000;
  cfg.auth ??= { username: 'elastic', password: 'changeme' };
  if (args.baseUrl) cfg.instance.baseUrl = args.baseUrl;

  const stamp = new Date().toISOString().replace(/[:.]/g, '-').replace('T', '_').slice(0, 19);
  const outBase =
    args.out || cfg.outDir || path.join(os.homedir(), 'Documents', 'Development', 'qa-runs');
  const runDir = path.join(outBase, `feature-${cfg.name}-${stamp}`);
  const shotDir = path.join(runDir, cfg.instance.label);
  fs.mkdirSync(shotDir, { recursive: true });
  info(`Run dir: ${runDir}`);
  info(`Scenario: ${cfg.title} against ${cfg.instance.baseUrl}`);

  const browser = await chromium.launch({ headless: !args.headed });
  const context = await browser.newContext({ viewport: cfg.viewport, ignoreHTTPSErrors: true });
  const breakages = [];
  const screenshots = [];
  const stepResults = [];
  let failed = 0;

  try {
    info(`waiting for Kibana at ${cfg.instance.baseUrl} ...`);
    const up = await waitForKibana(
      context.request,
      cfg.instance.baseUrl,
      cfg.auth,
      cfg.readinessTimeoutMs
    );
    if (!up) warn('Kibana never reported available — continuing anyway.');

    const page = await context.newPage();
    attachBreakageListeners(page, breakages);

    const didLogin = await login(page, cfg.instance.baseUrl, cfg.auth, cfg.navTimeoutMs);
    ok(didLogin ? 'logged in' : 'no login required');

    for (const step of cfg.steps) {
      const label = stepLabel(step);
      try {
        await runStep(page, cfg, shotDir, step, screenshots);
        stepResults.push({ action: step.action, label, status: 'passed', note: '' });
      } catch (e) {
        const note = String(e.message || e).split('\n')[0].slice(0, 200);
        if (step.optional) {
          warn(`optional step "${label}" failed (continuing): ${note}`);
          stepResults.push({ action: step.action, label, status: 'skipped', note });
        } else {
          err(`step "${label}" failed: ${note}`);
          stepResults.push({ action: step.action, label, status: 'failed', note });
          failed++;
          break; // required step failed — stop the scenario
        }
      }
    }
  } finally {
    await context.close();
    await browser.close();
  }

  const meta = { stamp, failed };
  fs.writeFileSync(
    path.join(runDir, 'report.html'),
    buildReport(cfg, meta, screenshots, breakages, stepResults)
  );
  fs.writeFileSync(
    path.join(runDir, 'summary.json'),
    JSON.stringify(
      { stamp, scenario: cfg.name, title: cfg.title, instance: cfg.instance, failed, screenshots, breakages, steps: stepResults },
      null,
      2
    )
  );

  console.log('');
  ok(`Report: ${path.join(runDir, 'report.html')}`);
  if (breakages.length) warn(`${breakages.length} breakage(s) captured — see report.`);

  if (failed > 0) {
    err(`${failed} required step(s) failed.`);
    process.exit(1);
  }
  if (args.failOnBreakage && breakages.length > 0) {
    err(`Breakages captured and --fail-on-breakage set.`);
    process.exit(1);
  }
  process.exit(0);
}

main().catch((e) => {
  err(e.stack || e.message || String(e));
  process.exit(1);
});
