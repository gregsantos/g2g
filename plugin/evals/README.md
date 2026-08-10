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

## What a case may assume

Cases are scored against the **shipped plugin files**, not against
copies of their rules. A case's `prompt.md` supplies fixture data
inline, but points the model at the real command/skill file by
repo-relative path and requires applying it as written — so a
regression in the shipped file changes the response and therefore the
score. The runtime contract a case may assume: the model under test
runs from the repository root of the candidate checkout, with read
access to the repo's files, and no other tool access. Cases must not
assume network access, subagent dispatch, or a live fixture
repository. Full end-to-end invocation — installing the candidate
plugin into a fixture repo and driving the actual slash command — is
the planned upgrade once the harness supports it; until then,
read-the-shipped-file cases are the floor, and prompts that embed
their own copy of a command's contract are a defect (they measure the
fixture prose, not the plugin).

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
| `build-cap-and-lock-safety` | build orchestration decisions (lock/cap safety path) | dev |
| `review-finding-quality` | review finding quality | dev |
| `status-reporting-accuracy` | status reporting accuracy | dev |

## Dev set vs. sealed holdout

Cases come in two sets, and the boundary between them is *location*,
not prose:

- **dev** — every case committed in this directory. Free to read, run,
  and reference from an automated `/g2g:improve` cycle while iterating
  on a command. Fair game for hill-climbing. **Everything committed
  under `plugin/evals/` is dev by definition**: automated builders have
  full repository read access, so a rule saying "the loop must not read
  this case" is not an isolation boundary — a candidate could inspect
  the exact prompt and grader before the human merge run, which
  invalidates the holdout.
- **sealed** — cases that live **outside this repository**, in an
  operator-owned fixture store (a private repo, a CI secret checkout, a
  directory on the reviewer's machine — anywhere candidate worktrees
  cannot read). Same case shape (`prompt.md` + `graders/criteria.md`).
  Run ONLY by a human at the merge gate. A sealed case exists to catch
  regressions the dev set doesn't cover — with suites this small (5-8
  cases), a command tuned against every case it will ever be graded on
  gets fitted to the suite within a few dozen accepted changes instead
  of actually improving, the same overfitting an ML holdout set exists
  to catch. Sealed-case results may be recorded in `results.json` under
  an opaque case name (e.g. `sealed-01`) so aggregate holdout trends are
  visible without exposing the case itself.

When adding a case here, record it in the table above — do not leave a
new case undocumented. When a case covers behavior the loop must never
tune itself against, keep it out of this directory entirely and add it
to your sealed store instead.

## Grader requirement

Every `graders/criteria.md` must score proportionally to how many of
its enumerated criteria hold, with at least 4 checkable criteria so a
response has headroom below a perfect score — no grader may be a
binary pass/fail. Follow the existing cases' pattern: "Score 1.0 only
if ALL of the following hold ...; otherwise score proportionally to
how many hold", then a numbered list.

## Score ledger (`results.json`)

`plugin/evals/results.json` is the committed score ledger — a sibling
of the tick ledger, seeded as an empty JSON array (`[]`). Nothing
appends to it during a run: a candidate build's eval runs are
read-only against the tracked tree (a tracked write mid-verification
would register as state drift in `g2g-evidence.sh` and block the
proven verdict), with per-run scores landing in an untracked sidecar.
An entry is appended by a **human at the merge gate**, in its own
append-only commit referencing the measured candidate commit — see
the hill-climbing loop in the top-level plugin README. Each entry:

```json
{
  "date": "2026-08-09",
  "case": "spec-generation",
  "scores": [0.85, 0.8, 0.9],
  "model": "claude-sonnet-5",
  "commit": "2506a3a",
  "harness": "plugin-eval/early-access"
}
```

Schema (all six fields required on every entry):

| Field | Type | Meaning |
|-------|------|---------|
| `date` | string, ISO 8601 | when the runs were scored |
| `case` | string | matches a `plugin/evals/<area>-<slug>` directory name (or an opaque `sealed-*` name for holdout cases) |
| `scores` | non-empty array of numbers in `[0, 1]` | the grader's proportional score for **each individual run**, one element per run |
| `model` | string | the model under test |
| `commit` | string | the short SHA of the candidate HEAD these runs measured — ties every measurement to a specific change |
| `harness` | string | the harness version/generation that produced the scores |

Per-run scores are kept raw — never pre-averaged into a single number —
because the selection rule below needs the **spread** across runs, and
a mean plus a run count cannot reconstruct it. Derive what you need:
run count is `scores | length`, the baseline mean is `scores | add /
length`, and the observed spread is `max - min` (or a stddev if you
prefer; the convention just has to be applied consistently on both
sides of a comparison).

Nothing writes to this file automatically today — the harness that
would populate it is early access and not wired into this repo (see
above). This file only pins the *shape* future entries must have.

### Baseline convention

A case's baseline is the **most recent committed entry** for that case
(the last entry with that `case` value, by append order / `date`): its
mean is the baseline score, and its per-run `scores` give the baseline
spread. No entry for a case means no baseline yet — the first entry
committed for that case simply establishes it; there is nothing to
regress against until then.

A comparison is valid only between entries with matching `case`,
`model`, and `harness`, and an equal run count (`scores | length`). A
candidate's gain counts only when it exceeds the observed spread across
its own >= 3 runs — see the hill-climbing loop in the top-level plugin
README for the accept / reject / retest rule this feeds.

### Budget normalization

Scores are comparable only when `model`, `harness`, and the run count
are held constant — a 5-run measurement at `claude-opus` and a 1-run
sample at `claude-haiku` are not the same measurement, which is why
these are schema fields rather than run-harness metadata dropped on
the floor. Whenever the model under test or the harness itself
changes, the baseline must be **re-established**, not carried across:
commit a fresh entry under the new `model`/`harness` and treat it as
the new starting point, rather than diffing it against an older entry
measured under different conditions.

### Future CI use

Once the eval harness is available, CI can pass its `--threshold`
flag with the case's baseline mean (from the most recent entry's
`scores`) as the regression floor — failing the run if the new score
drops below it. That wiring does not exist yet: **no Makefile target, CI
workflow, or `make check` step invokes the eval harness today**, and
this ledger's only job right now is to exist with the right shape so
baseline and trend have somewhere to live once it does.

## Adding a case

1. Pick the area and prefix the directory name accordingly
   (`<area>-<slug>`).
2. Write `prompt.md` — the literal input a model under test receives.
   Cases run from the repository root with file read access (see "What
   a case may assume" above). Fixture *data* (repo states, command
   outputs, candidate findings) goes inline in the prompt; the
   *behavioral contract* must come from the shipped file the case
   exercises — instruct the model to read it by path. NEVER paste a
   copy or summary of a command's rules into the prompt: a case whose
   prompt carries its own copy of the contract scores the copy, not
   the shipped file, so regressions in the command can never move the
   score.
3. Write `graders/criteria.md` following the proportional pattern
   above.
4. Add a row to the Cases table, choosing dev or sealed deliberately.
5. Run `make check` — `tests/plugin_evals.bats` asserts the new case
   has both required files and that its grader contains the phrase
   "score proportionally".
