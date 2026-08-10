# Plugin evals

Eval cases for hill-climbing the g2g plugin's commands. Each case is a
directory with a fixed shape:

```
plugin/evals/<area>-<slug>/
├── prompt.md              # the exact input given to the model under test
└── graders/
    └── criteria.md        # the rubric a grader model scores the response against
```

The eval harness that runs these cases end-to-end is early access and
not wired into this repo yet (see the top-level README's project
structure note). Until it lands, this directory is committed data and
config: the case shape, the area tags, and the dev/sealed split below
are the contract a harness — or a human — scores against; nothing here
executes automatically, and `tests/plugin_evals.bats` pins only the
directory *structure*, never eval scoring.

## Area tagging convention

Every case directory name is prefixed with its command area, so a
change to one command is scored against its own cases without having
to open every case to find out which command it exercises:

| Prefix | Command area |
|--------|--------------|
| `spec-` | `/g2g:spec` — spec generation quality |
| `build-` | `/g2g:build` — build orchestration decisions |
| `review-` | `/g2g:review` — review finding quality |
| `status-` | `/g2g:status` — status reporting accuracy |

## Cases

| Case | Area | Set |
|------|------|-----|
| `spec-generation` | spec generation quality | dev |
| `build-orchestration-decisions` | build orchestration decisions | dev |
| `build-cap-and-lock-safety` | build orchestration decisions (lock/cap safety path) | **sealed** |
| `review-finding-quality` | review finding quality | dev |
| `status-reporting-accuracy` | status reporting accuracy | dev |

## Dev set vs. sealed holdout

Cases are split into two sets:

- **dev** — free to read, run, and reference from an automated
  `/g2g:improve` cycle while iterating on a command. Fair game for
  hill-climbing.
- **sealed** — run ONLY by a human at the merge gate, and NEVER
  referenced, read, or scored by an automated improve loop. A sealed
  case exists to catch regressions the dev set doesn't cover — with
  suites this small (5-8 cases), a command tuned against every case it
  will ever be graded on gets fitted to the suite within a few dozen
  accepted changes instead of actually improving, the same overfitting
  an ML holdout set exists to catch. `build-cap-and-lock-safety` is
  sealed: it covers the lock/ownership/cap safety paths from
  `plugin/commands/build.md` that CLAUDE.md marks as invariants that
  must never weaken, so it is deliberately kept out of the loop that
  could otherwise learn to satisfy it by narrowing behavior instead of
  fixing it.

When adding a case, decide its set deliberately and record it in the
table above — do not leave a new case undocumented.

## Grader requirement

Every `graders/criteria.md` must score proportionally to how many of
its enumerated criteria hold, with at least 4 checkable criteria so a
response has headroom below a perfect score — no grader may be a
binary pass/fail. Follow the existing cases' pattern: "Score 1.0 only
if ALL of the following hold ...; otherwise score proportionally to
how many hold", then a numbered list.

## Adding a case

1. Pick the area and prefix the directory name accordingly
   (`<area>-<slug>`).
2. Write `prompt.md` — the literal input a model under test receives.
   Keep it self-contained: include any procedure excerpt or data the
   response needs, rather than assuming the harness will supply repo
   or tool access.
3. Write `graders/criteria.md` following the proportional pattern
   above.
4. Add a row to the Cases table, choosing dev or sealed deliberately.
5. Run `make check` — `tests/plugin_evals.bats` asserts the new case
   has both required files and that its grader contains the phrase
   "score proportionally".
