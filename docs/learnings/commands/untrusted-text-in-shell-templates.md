---
id: L-004
title: Untrusted text never enters shell source in command prose — helpers read it from a file
date: 2026-09-17
track: bug
area: commands
severity: medium
tags: [shell-injection, untrusted-text, slug, spec-project, command-templates, g2g-slug]
sourceFinding: F-035
commits: [2df7192, 0052886]
symptoms: The branch name, spec filename, commit message, and PR title were derived from the spec's project field by an informal "lowercase, hyphenated form" rule with no charset, and the field was interpolated verbatim into git and gh command text.
rootCause: Command prose asked the model to compose shell commands around spec-controlled text; a project value carrying "..", "/", a ".lock" suffix, a leading "-", or a "$(...)" substitution reached git checkout -b and gh pr create with nothing between the text and the shell, and the first fix's own template ("g2g-slug.sh \"<project>\"") re-created the hole by pasting the value into a double-quoted argument that Bash expands before any helper runs.
resolution: PR #35 added plugin/scripts/g2g-slug.sh as the sole slug derivation and made every caller read the value from a file — build.md and spec.md via the --spec form on JSON, go.md via a single-quoted model-composed literal — with bats pins that fail on any double-quoted paste template.
---

# L-004: Untrusted text never enters shell source in command prose — helpers read it from a file

## Context
Review finding F-035 (`review-output/findings.json`) observed that
`/g2g:build` derived its work branch from the spec's `project` field
under an informal "lowercase, hyphenated form" rule with no character
whitelist, interpolated the same field verbatim into a commit message
and PR titles, and that `/g2g:spec` derived its output filename the
same way. The project name is untrusted: it is lifted from a prompt, a
requirements file, or review-finding text, and the improve flywheel
feeds finding text into specs by design. A value carrying `..`, `/`, a
`.lock` suffix, a leading `-`, or shell metacharacters could yield an
unexpected git ref or, when the executing model composes the git or gh
command as a shell string, argument or command injection.

## Root Cause
The command files are procedures a model executes by composing shell
commands, so any template of the form "run X with <value>" invites the
model to paste the value into the command text. Once the value is in
the command text, Bash evaluates `$(…)` and backticks inside a
double-quoted argument before any helper runs, so a sanitizer called
that way sees text that has already executed. A charset rule stated in
prose does not close this: the first fix on PR #35 added the helper
but showed it as `g2g-slug.sh "<project>"`, and adversarial review
demonstrated a project name carrying a command substitution executing
before the helper received it. A related trap sits in the same
procedure: shell variables do not survive between Bash tool calls, so
"capture the value once, reuse it later" silently degrades to the
model carrying the value in its own context and pasting it.

## Resolution
PR #35 (commits 2df7192 and 0052886) landed three things:
- `plugin/scripts/g2g-slug.sh` is the sole implementation of the slug
  rule: ASCII-lowercase, every run outside `[a-z0-9]` becomes one
  hyphen, ends trimmed, cut to 60 characters, exit 2 on nothing
  slug-worthy. Its output always begins and ends with a lowercase
  letter or digit and contains only lowercase letters, digits, and
  hyphens, which `git check-ref-format` accepts as a ref component. It takes either a text argument or
  `--spec <path>`, which reads the `.project` field from JSON so the
  value never appears in shell source.
- Every caller reads the value from a file, not from pasted text.
  `plugin/commands/build.md` Phase 1 step 3 uses the `--spec` form on
  the spec path and, wherever the project name enters a commit message
  or PR title, reads it with `jq` INSIDE the same Bash command that
  uses it, passed as one quoted argument. `plugin/commands/spec.md`
  step 4 writes the draft spec to a `mktemp -d` directory outside the
  checkout, slugs it with `--spec`, then moves it into place.
  `plugin/commands/go.md` step 1 shows a single-quoted literal for its
  model-composed summary, with a charset that cannot end the literal
  early — single quotes are the one form Bash never expands.
- Pins in `tests/commands.bats` require the `--spec` form in spec.md
  and the single-quoted form in go.md, and fail if any command file
  shows a double-quoted `g2g-slug.sh "…"` template; `tests/plugin_slug.bats`
  runs a hostile-input set through `git check-ref-format` and feeds
  `--spec` a project containing command substitutions, asserting
  nothing evaluated.

## Evidence
- `plugin/scripts/g2g-slug.sh` — header documents the rule, the two
  input forms, and the exit codes.
- `plugin/commands/build.md` Phase 1 step 3; `plugin/commands/spec.md`
  step 4; `plugin/commands/go.md` step 1 — the three call sites.
- `tests/plugin_slug.bats` and the three slug pins in
  `tests/commands.bats`.
- Commits 2df7192 (helper and call sites) and 0052886 (paste-template
  fix), merged as PR #35.
- The same mechanism, in two other interpreters: every spec string
  `plugin/scripts/g2g-evidence.sh` prints passes through
  `gsub("[[:cntrl:]]"; " ")` so spec text cannot forge a verdict line
  (PR #33), and the Stop hook's PR gate in `plugin/scripts/g2g-stop.sh`
  rejects `gh pr create --dry-run` because a preview echoes a body the
  model controls (PR #37).

## Implication
When writing or changing a command procedure, treat any value that
originates in a spec, a finding, a requirements file, or a prompt as
untrusted, and never show a template that places it inside a shell
argument — not double-quoted, not "escaped", not "just this once". The
executable helpers read such values from a file or JSON (`--spec`), and
the procedure names the file, not the value. A model-composed value may
appear as a single-quoted literal only when the procedure also
restricts its charset so the literal cannot end early. Shell variables
do not persist between Bash tool calls, so any capture-then-use must
happen inside one command. Any new line a script prints from spec text
must strip control characters, or it can forge a line the Stop hook
trusts. A double-quoted `g2g-slug.sh "…"` in any command file fails
`make check`; keep that pin, and add the same shape of pin whenever a
new helper starts taking untrusted text.
