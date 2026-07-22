---
description: One-off G2G task — branch-first, implement, verify, commit; --pr to open a PR
argument-hint: '"<what to do>" [--pr]'
model: sonnet
---
# /g2g:go — one-off task

Execute this one-off task autonomously: $ARGUMENTS

Procedure — deviations are failures:
1. Preflight: `git status` must be clean; you must NOT be on the default
   branch when committing. Create `g2g/go-<slug>` (slug: lowercase task
   summary, hyphenated, ≤5 words) from the current HEAD.
2. Implement the task fully. No stubs. Follow repo conventions (CLAUDE.md).
   Never weaken tests, lint, or CI.
3. Verify: if `.claude/g2g.json` exists and has `verificationCommands`,
   run them all and show real output. Otherwise run the repo's documented
   test/lint commands. Failures = fix and re-verify, don't report success.
4. Commit `feat: <summary>` (or `fix:`/`chore:` as appropriate). No
   attribution lines in the commit message. If `--pr` will be used, the PR
   title and body must also contain no attribution lines (no 'Generated
   with Claude Code', no Co-Authored-By trailers). DO NOT push.
5. Only if `--pr` was passed: push the branch once (`git push -u origin
   <branch>`) and `gh pr create` with a body summarizing what/why/how
   verified. Never merge.
6. Report: branch name, commit sha, verification output summary, PR URL if
   created. If you could not complete the task, say exactly what's missing —
   never claim partial work as done.
