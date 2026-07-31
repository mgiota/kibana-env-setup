#!/usr/bin/env node
// ============================================================
//  post-pr.mjs — publish a qa-feature run to a GitHub PR.
//
//  GitHub comments can't reference local files, so screenshots
//  are hosted by committing them to an orphan branch on the fork
//  (default: qa-screenshots) and embedding raw.githubusercontent
//  URLs. A single marker-tagged comment is created or updated
//  (idempotent) via the gh CLI.
//
//  USAGE:
//    node post-pr.mjs --run ~/Documents/Development/qa-runs/feature-maintenance-windows-...
//    node post-pr.mjs --run <dir> --pr 12345
//    node post-pr.mjs --run <dir> --checks /path/to/checks-summary.md
//    node post-pr.mjs --run <dir> --dry-run          # build markdown, don't push/post
//
//  Options:
//    --repo <owner/repo>       base repo for the PR         (default: elastic/kibana)
//    --fork-remote <name>      git remote for the fork       (default: origin)
//    --assets-branch <name>    orphan branch for images      (default: qa-screenshots)
//    --kibana-dir <path>       kibana git repo               (default: $KIBANA_DIR or cwd)
//    --pr <number>             PR number (else auto via gh)
//    --checks <file>           markdown/text checks summary to include
//    --dry-run                 print the markdown; skip git push + gh comment
// ============================================================

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { ok, info, warn, err } from './lib/kibana.mjs';

function parseArgs(argv) {
  const a = {
    run: null,
    pr: null,
    repo: 'elastic/kibana',
    forkRemote: 'origin',
    assetsBranch: 'qa-screenshots',
    kibanaDir: process.env.KIBANA_DIR || process.cwd(),
    checks: null,
    dryRun: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--run') a.run = argv[++i];
    else if (t === '--pr') a.pr = argv[++i];
    else if (t === '--repo') a.repo = argv[++i];
    else if (t === '--fork-remote') a.forkRemote = argv[++i];
    else if (t === '--assets-branch') a.assetsBranch = argv[++i];
    else if (t === '--kibana-dir') a.kibanaDir = argv[++i];
    else if (t === '--checks') a.checks = argv[++i];
    else if (t === '--dry-run') a.dryRun = true;
    else if (t === '--help' || t === '-h') {
      console.log('post-pr --run DIR [--pr N] [--repo o/r] [--fork-remote origin] [--checks FILE] [--dry-run]');
      process.exit(0);
    } else {
      err(`Unknown arg: ${t}`);
      process.exit(2);
    }
  }
  return a;
}

function run(cmd, args, opts = {}) {
  const res = spawnSync(cmd, args, { encoding: 'utf8', ...opts });
  if (res.status !== 0) {
    throw new Error(
      `${cmd} ${args.join(' ')} failed (${res.status}): ${(res.stderr || res.stdout || '').trim()}`
    );
  }
  return (res.stdout || '').trim();
}

function tryRun(cmd, args, opts = {}) {
  const res = spawnSync(cmd, args, { encoding: 'utf8', ...opts });
  return { ok: res.status === 0, stdout: (res.stdout || '').trim(), stderr: (res.stderr || '').trim() };
}

// origin URL -> { owner, repo }
function parseGitHubRemote(url) {
  const m = url.match(/github\.com[:/]([^/]+)\/(.+?)(?:\.git)?$/);
  if (!m) throw new Error(`Cannot parse GitHub remote: ${url}`);
  return { owner: m[1], repo: m[2] };
}

function detectPrNumber(kibanaDir, repo) {
  const res = tryRun('gh', ['pr', 'view', '--repo', repo, '--json', 'number', '-q', '.number'], {
    cwd: kibanaDir,
  });
  if (res.ok && res.stdout) return res.stdout;
  throw new Error('Could not auto-detect PR number; pass --pr <number>.');
}

// Commit the run's PNGs onto the orphan assets branch (in an isolated worktree
// so the caller's working tree/index is never touched) and push to the fork.
function publishAssets({ kibanaDir, forkRemote, assetsBranch, fork, pr, stamp, pngFiles }) {
  const worktreeDir = fs.mkdtempSync(path.join(os.tmpdir(), 'qa-assets-'));
  const destRel = path.posix.join(String(pr), stamp);
  try {
    const fetched = tryRun('git', ['-C', kibanaDir, 'fetch', forkRemote, assetsBranch]);
    if (fetched.ok) {
      run('git', ['-C', kibanaDir, 'worktree', 'add', '-B', assetsBranch, worktreeDir, `${forkRemote}/${assetsBranch}`]);
    } else {
      info(`No existing ${assetsBranch} on ${forkRemote} — creating an orphan branch.`);
      // `worktree add --orphan` (git 2.42+) gives a clean, empty working tree.
      // The old `checkout --orphan` + `rm -rf .` dance left the full HEAD tree
      // staged when the `rm` silently failed, committing the entire repo.
      run('git', ['-C', kibanaDir, 'worktree', 'add', '--orphan', '-b', assetsBranch, worktreeDir]);
    }

    const destAbs = path.join(worktreeDir, destRel);
    fs.mkdirSync(destAbs, { recursive: true });
    for (const png of pngFiles) {
      fs.copyFileSync(png, path.join(destAbs, path.basename(png)));
    }

    run('git', ['-C', worktreeDir, 'add', '-A']);
    run('git', ['-C', worktreeDir, 'commit', '-m', `qa-feature screenshots: PR #${pr} @ ${stamp}`]);
    run('git', ['-C', worktreeDir, 'push', forkRemote, `HEAD:${assetsBranch}`]);
    ok(`Pushed ${pngFiles.length} screenshot(s) to ${fork.owner}/${fork.repo}@${assetsBranch}`);

    return destRel; // path prefix on the assets branch
  } finally {
    tryRun('git', ['-C', kibanaDir, 'worktree', 'remove', '--force', worktreeDir]);
    fs.rmSync(worktreeDir, { recursive: true, force: true });
  }
}

function rawUrl(fork, assetsBranch, relPath) {
  return `https://raw.githubusercontent.com/${fork.owner}/${fork.repo}/${assetsBranch}/${relPath}`;
}

function buildMarkdown({ summary, marker, checksMd, imageBaseUrl }) {
  const lines = [];
  lines.push(marker);
  lines.push(`## Feature QA — ${summary.title}`);
  lines.push('');
  lines.push(
    `Automated feature-acceptance run against \`${summary.instance.label}\` (${summary.instance.baseUrl}) at \`${summary.stamp}\`.`
  );
  lines.push('');

  if (checksMd) {
    lines.push('### Baseline checks');
    lines.push('');
    lines.push(checksMd.trim());
    lines.push('');
  }

  const stepFail = summary.failed > 0;
  lines.push('### Result');
  lines.push('');
  if (stepFail) {
    lines.push(`\u274c ${summary.failed} required step(s) failed.`);
  } else if ((summary.breakages || []).length > 0) {
    lines.push(`\u26a0\ufe0f All steps passed, but ${summary.breakages.length} breakage(s) were captured.`);
  } else {
    lines.push('\u2705 All steps passed, no breakages captured.');
  }
  lines.push('');

  lines.push('### Screenshots');
  lines.push('');
  for (const shot of summary.screenshots || []) {
    lines.push(`**${shot.caption}**`);
    lines.push('');
    lines.push(`![${shot.caption}](${imageBaseUrl}/${shot.file})`);
    lines.push('');
  }

  lines.push('### Breakages (console errors / failed / 5xx requests)');
  lines.push('');
  if ((summary.breakages || []).length === 0) {
    lines.push('_None captured._');
  } else {
    lines.push('| kind | detail |');
    lines.push('|---|---|');
    for (const b of summary.breakages) {
      lines.push(`| ${b.kind} | \`${b.text.replace(/\|/g, '\\|')}\` |`);
    }
  }
  lines.push('');
  lines.push('<sub>Generated by qa/qa-feature.mjs + qa/post-pr.mjs</sub>');
  return lines.join('\n');
}

function upsertComment({ repo, pr, marker, bodyFile }) {
  const listRaw = run('gh', [
    'api',
    '--paginate',
    `repos/${repo}/issues/${pr}/comments`,
    '-q',
    '.[] | {id: .id, body: .body}',
  ]);
  let existingId = null;
  for (const line of listRaw.split('\n').filter(Boolean)) {
    try {
      const c = JSON.parse(line);
      if (typeof c.body === 'string' && c.body.includes(marker)) {
        existingId = c.id;
        break;
      }
    } catch {
      /* ignore */
    }
  }

  if (existingId) {
    run('gh', [
      'api',
      '-X',
      'PATCH',
      `repos/${repo}/issues/comments/${existingId}`,
      '-F',
      `body=@${bodyFile}`,
    ]);
    ok(`Updated existing PR comment (${existingId}).`);
  } else {
    run('gh', ['api', `repos/${repo}/issues/${pr}/comments`, '-F', `body=@${bodyFile}`]);
    ok('Created PR comment.');
  }
}

function main() {
  const args = parseArgs(process.argv);
  if (!args.run) {
    err('Missing --run DIR');
    process.exit(2);
  }
  const runDir = path.resolve(args.run);
  const summaryPath = path.join(runDir, 'summary.json');
  if (!fs.existsSync(summaryPath)) {
    err(`No summary.json in ${runDir}`);
    process.exit(2);
  }
  const summary = JSON.parse(fs.readFileSync(summaryPath, 'utf8'));
  const marker = `<!-- qa-feature-report:${summary.scenario} -->`;

  const shotDir = path.join(runDir, summary.instance.label);
  const pngFiles = (summary.screenshots || [])
    .map((s) => path.join(shotDir, s.file))
    .filter((p) => fs.existsSync(p));

  const forkUrl = run('git', ['-C', args.kibanaDir, 'remote', 'get-url', args.forkRemote]);
  const fork = parseGitHubRemote(forkUrl);
  const pr = args.pr || detectPrNumber(args.kibanaDir, args.repo);
  const checksMd = args.checks && fs.existsSync(args.checks) ? fs.readFileSync(args.checks, 'utf8') : null;

  info(`PR #${pr} on ${args.repo}; fork ${fork.owner}/${fork.repo}; ${pngFiles.length} screenshot(s)`);

  let imageBaseUrl = '(screenshots not uploaded — dry run)';
  if (!args.dryRun && pngFiles.length > 0) {
    const relPrefix = publishAssets({
      kibanaDir: args.kibanaDir,
      forkRemote: args.forkRemote,
      assetsBranch: args.assetsBranch,
      fork,
      pr,
      stamp: summary.stamp,
      pngFiles,
    });
    imageBaseUrl = rawUrl(fork, args.assetsBranch, relPrefix);
  }

  const md = buildMarkdown({ summary, marker, checksMd, imageBaseUrl });
  const bodyFile = path.join(runDir, 'pr-comment.md');
  fs.writeFileSync(bodyFile, md);
  ok(`Wrote ${bodyFile}`);

  if (args.dryRun) {
    console.log('\n----- PR comment (dry run) -----\n');
    console.log(md);
    return;
  }

  upsertComment({ repo: args.repo, pr, marker, bodyFile });
}

try {
  main();
} catch (e) {
  err(e.stack || e.message || String(e));
  process.exit(1);
}
