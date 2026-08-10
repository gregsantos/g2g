Read `plugin/commands/build.md` — the shipped `/g2g:build` orchestrator
procedure in this repository — and answer as that orchestrator,
reasoning about its checkout-lock and ownership-safety rules: the
OWNERSHIP LOST path, the Phase 4 rebase-conflict path, the Phase 5
terminal partial-PR path, and the preflight lock-acquire outcomes.
These are frozen safety invariants, and every rule you apply must come
from `build.md` as it exists on disk — not from memory and not from
this prompt: this case exists to detect regressions or weakenings in
the shipped safety text.

Given each of the following four independent scenarios, state exactly
what the orchestrator does, in order, and — just as importantly — what
it must NOT do. Cite the governing phase/step of `build.md` for each.
Answer scenario-by-scenario (label your answers 1-4).

1. Mid-Phase-3, the ownership-checked heartbeat refresh at the top of
   the turn exits 5 (`ownership-lost`). Three tasks had already been
   marked `passes: true` earlier in this build.

2. Phase 4 step 5's rebase onto the default branch produces a merge
   conflict.

3. In Phase 5, `git push -u origin <branch>` succeeds but the
   subsequent `gh pr create` call fails with an API error.

4. Preflight step 1's lock acquire call returns exit 4 (`live-owner`),
   printing a heartbeat timestamp from two minutes ago.
