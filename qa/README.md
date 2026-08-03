# QA — Kibana screenshot tooling

Two complementary modes, because they answer different questions:

| Tool | Question it answers | When to use |
|---|---|---|
| `qa-shots.mjs` (**visual regression**) | "Did anything on existing pages change unexpectedly?" | Refactors, shared-component edits, EUI/dependency bumps, backwards-compat. Compares `feat` vs `main` and pixel-diffs. |
| `qa-feature.mjs` (**feature acceptance**) | "Does this new feature work, and what does it look like?" | Additive features where comparing against `main` is meaningless (main doesn't have the feature yet). Drives the feature with Playwright, screenshots key states, records breakages, and can post to the PR. |

**Why not always diff against `main`?** A `feat`-vs-`main` pixel diff is a *negative*
check — it proves nothing visible changed. For a brand-new feature (e.g. a new bulk
action + flyout that only appear after interaction) that's the wrong model: the new
UI doesn't exist on `main`, so the diff is either empty (static page unchanged) or a
guaranteed "FAIL" (the new UI). For those, use feature-acceptance mode and, once
merged, treat the captured screenshots as the golden baseline for future runs.

## Visual regression — `qa-shots.mjs`

A deterministic screenshot + visual-diff tool. It captures the same set of routes
across one or more Kibana instances (e.g. `kibana-main` vs `kibana-feat`), pixel-diffs
each pair against a baseline, and writes a self-contained `report.html` for
human-in-the-loop review.

Deterministic by design — the agent isn't in the loop. The pixel diff flags what
changed; **you** open the report and decide whether it's a real regression. (An
optional agent-judged pass over the flagged diffs can be layered on later.)

## What it produces

```
~/Documents/Development/qa-runs/<timestamp>/
├── main/        slo-list.png, synthetics-monitors.png, ...
├── feat/        slo-list.png, synthetics-monitors.png, ...
├── diff/        feat__vs__main__slo-list.png, ...   (magenta = changed pixels)
├── report.html  ← open this
└── summary.json ← machine-readable results
```

## Setup (one time)

```bash
cd qa
npm install
npx playwright install chromium
```

Or just run `./run.sh` — it does both on first use.

## Run

```bash
./run.sh                              # all instances + routes in config.json
./run.sh --only slo-list              # one route
./run.sh --instances feat             # capture a single instance (no compare)
./run.sh --no-compare                 # screenshots only, skip diff
./run.sh --headed                     # watch the browser run
./run.sh --out ~/somewhere/qa-runs    # custom output dir
```

Then open the printed `report.html`. Exit code is `0` if every compared route is
within the threshold, `1` if any route exceeds it — so this can drop into a git
hook or CI later.

## Configuration — `config.json`

| Key | Meaning |
|---|---|
| `instances[]` | `{ label, baseUrl }` for each Kibana to capture. Default: `main` (:5602) and `feat` (:5601). |
| `auth` | Kibana login — defaults to `elastic` / `changeme` (local dev). |
| `routes[]` | `{ name, path, waitForSelector?, mask? }`. `name` is the screenshot filename; `path` is appended to each `baseUrl`. |
| `routes[].waitForSelector` | CSS selector to wait for before screenshotting (comma = "any of"). Non-fatal if missing — falls back to `settleMs`. |
| `routes[].mask` | Selectors painted over before capture, so dynamic content (charts, timestamps) doesn't trip the diff. |
| `viewport` | Screenshot size. Fixed size keeps diffs comparable. |
| `settleMs` | Extra wait after load for charts/animations to settle. |
| `fullPage` | `true` to capture the whole scroll height (heights are padded before diffing). Default `false` (viewport only — more stable). |
| `compare.baseline` | Which instance label is the reference (default `main`). |
| `compare.diffThresholdPct` | % of changed pixels above which a route is a regression (`FAIL`). |
| `compare.pixelmatchThreshold` | Per-pixel colour sensitivity (0–1, lower = stricter). |

### Adapting routes / selectors

`waitForSelector` and `mask` values are best-effort guesses at Kibana's
`data-test-subj` attributes and may need tweaking per version. They're non-fatal:
if a `waitForSelector` never appears, the script warns and screenshots after
`settleMs` anyway. To find the right selector, run `--headed`, open devtools on
the page, and grab the `data-test-subj` of a stable element.

## How instances stay isolated

Each instance is captured in its own Playwright **browser context** — a separate
cookie jar — so login/session state from one instance can't leak into another,
regardless of whether they share a hostname or only differ by port.

## Prerequisites

- Both target Kibana instances running (e.g. via `dev-start.sh`) and reachable at
  the `baseUrl`s in `config.json`.
- Comparable data seeded in each (e.g. `run-data slo`, `run-data synthetics`),
  otherwise empty-state pages just compare against empty-state pages.
- Node 18+ (the repo's `.nvmrc` Node is fine).

---

# Feature acceptance — `qa-feature.mjs`

Drives a **new feature** through an interactive Playwright scenario on a single
instance (the `feat` worktree), captures key-state screenshots, and records
**breakages** (console errors + failed / 5xx requests) for human review. Optionally
publishes the result to the PR.

```
~/Documents/Development/qa-runs/feature-<scenario>-<timestamp>/
├── feat/        01-monitors-selected.png, 02-bulk-menu-open.png, ...
├── report.html  ← screenshots gallery + step log + breakages
├── summary.json ← machine-readable
└── pr-comment.md (after post-pr.mjs)
```

## Layout

| File | Purpose |
|---|---|
| `qa-feature.mjs` | The scenario runner. |
| `scenarios/*.json` | Declarative scenarios (the codified "recipe"). |
| `recipes/*.md` | Human-readable recipe: confirmed selectors + step order + screenshot points. |
| `seed-*.mjs` | Deterministic data seeding for a scenario. |
| `post-pr.mjs` | Hosts screenshots on a fork branch and posts/updates a PR comment. |
| `lib/kibana.mjs` | Shared login / readiness / logger helpers (also used by `qa-shots.mjs`). |

## Run

```bash
# 1. Seed deterministic data on the feat instance (monitors + maintenance windows)
node seed-maintenance-windows.mjs --base-url http://localhost:5601

# 2. Drive the feature and capture screenshots + breakages
node qa-feature.mjs --scenario scenarios/maintenance-windows.json \
                    --base-url http://localhost:5601
#   --headed             watch the browser
#   --fail-on-breakage   exit 1 if any console error / failed request is captured

# 3. (optional) smoke-check the plumbing on any instance/branch
node qa-feature.mjs --scenario scenarios/monitors-smoke.json --base-url http://localhost:5601

# 4. Publish the latest run to the PR (hosts images on a fork branch, posts a comment)
node post-pr.mjs --run ~/Documents/Development/qa-runs/feature-maintenance-windows-<stamp> \
                 --kibana-dir <path-to-kibana-worktree> --pr <number>
#   --dry-run            build the markdown, don't push/comment
#   --checks FILE        include a baseline-checks summary (run-checks.sh output) in the comment
```

Exit code: `0` on success, `1` if a required step failed (or any breakage with
`--fail-on-breakage`).

## Scenario format

A scenario is JSON: an `instance`, `masks` (selectors for dynamic regions), and
ordered `steps`. Each step is one action.

**Masks are invisible by default** in feature-acceptance runs — these screenshots
are for human review, not pixel-diffing, so mask overlays never obscure the UI
(no magenta boxes). Set `"maskColor"` on the scenario (any CSS color, e.g.
`"rgba(255,0,255,1)"`) only if you deliberately want a visible overlay.

| action | fields | notes |
|---|---|---|
| `goto` | `path`, `waitFor?` | navigate, optionally wait for a target |
| `waitFor` | `testSubj` \| `selector` \| `text`, `timeoutMs?` | wait for visible |
| `click` | `testSubj` \| `selector` \| `text` | |
| `fill` | target + `value` | |
| `comboBoxSelect` | `within?`, `index?` \| `optionText?` | EUI combobox pick |
| `buttonGroupSelect` | `within?`, `label` | EUI button group |
| `screenshot` | `name`, `caption?` | masked screenshot |
| `sleep` | `ms` | |

Add `"optional": true` to a step to continue (recorded as `skipped`) instead of
failing the run if it can't complete.

## Posting to the PR (image hosting)

GitHub comments can't reference local files, so `post-pr.mjs` commits the run's
PNGs to an orphan branch on your **fork** (default `qa-screenshots`, path
`<pr>/<stamp>/`) in an isolated `git worktree` (your working tree is never
touched), pushes it, and embeds `raw.githubusercontent.com` URLs. The comment is
tagged with a hidden marker (`<!-- qa-feature-report:<scenario> -->`) so re-runs
**update** the same comment instead of stacking new ones.

## Piloting a feature (e.g. maintenance windows)

1. Point the `feat` instance at the feature branch and start it
   (`dev-start.sh switch <branch>` / `restart feat`).
2. `node seed-maintenance-windows.mjs --base-url <feat-url>`.
3. `node qa-feature.mjs --scenario scenarios/maintenance-windows.json --base-url <feat-url> --headed`.
4. Review `report.html`; when happy, `node post-pr.mjs --run <dir> --kibana-dir <worktree> --pr <n>`.

The same feature is also covered by an in-repo Scout UI test
(`test/scout/ui/tests/bulk_edit_maintenance_windows.spec.ts`) which is the durable,
CI-gated version of the same recipe.
