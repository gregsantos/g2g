---
paths:
  - "scripts/**"
  - "CHANGELOG.md"
  - ".github/workflows/**"
  - "plugin/.claude-plugin/plugin.json"
---
# Release mechanics: version bumps and release tags

Moved here from the root `CLAUDE.md` so it loads only when working on the
release machinery. The root file keeps the rule itself (bump once per PR,
CHANGELOG in the same commit, forward-only versions, tags cut by CI and
never by hand); this file is the why and the how.

- **Version bumps: one per PR that changes the plugin.** Bump
  `plugin/.claude-plugin/plugin.json` whenever anything under `plugin/`
  changes installed behavior (commands, agents, skills, scripts, hooks,
  templates, routines, config schema) and add the matching
  `CHANGELOG.md` entry in the same commit; docs-only edits need
  neither. Bump exactly once per PR, never per commit — in a multi-task
  spec, assign the bump to ONE task and tell the other builders it is
  taken, or every fresh context reads this rule and bumps again. This rule
  is ENFORCED, not remembered: `scripts/check-version-bump.sh` fails the
  `version-bump` CI job on any PR that changes installed behavior without a
  bump, and `tag-release.sh` fails the same way post-merge for direct
  pushes. Release-sensitive paths are defined there as everything under
  `plugin/` EXCEPT `plugin/README.md` and `plugin/evals/` — an exclude list
  on purpose, so a plugin subdirectory added later is covered by default
  rather than escaping the guard until someone registers it. A bump must also
  move FORWARD: versions are plain `MAJOR.MINOR.PATCH`
  (`scripts/lib/semver.sh`, the sole definition, no suffixes and no leading
  zeros), strictly greater than the base's, and not already carried by a
  release tag. Merely differing from the base is not a bump — a downgrade to
  an already-released version passes a naive check, merges, and then wedges
  the tag job on a tag it must not move, leaving the default branch red and
  the change released nowhere. `tag-release.sh` re-checks format AND ordering
  across the whole transition sequence before creating any tag, because a
  direct push to the default branch never sees the pre-merge gate and a
  published tag cannot be taken back. Diffs are taken with `--no-renames -z`:
  git reports only a rename's destination, so moving an installed file into
  an excluded path once read as docs-only while deleting behavior, and a
  path git has to quote stopped matching the exclude prefixes.
- **Release tags are cut by CI, never by hand.** `scripts/tag-release.sh`
  (run by the `tag-release` job in `.github/workflows/ci.yml` on every push
  to the default branch) tags `g2g--v<version>` from
  `plugin/.claude-plugin/plugin.json`, with the tag body lifted from that
  version's `CHANGELOG.md` section. Six properties are load-bearing and
  pinned by `tests/tag_release.bats`: the target is the OLDEST first-parent
  commit carrying the version — derived from history, never from HEAD, so a
  batched push whose bump is not the tip still tags the bump, and two
  concurrent runs at different HEADs compute the same commit; the body is
  read from `CHANGELOG.md` AS OF THAT TARGET COMMIT (`git show`), never from
  the working tree, so a bump whose notes arrive in a LATER commit fails
  instead of being tagged with notes it did not contain — that is what makes
  the paired-edit rule above enforced rather than remembered, and it is also
  what makes racing runs produce byte-identical tags rather than merely
  same-commit ones; an EXISTING tag's target is verified rather than
  trusted, failing loudly when it points somewhere else, because a release
  tag on the wrong commit is a corrupted mapping no silent exit-0 should
  preserve; a missing or EMPTY `## <version>` section FAILS rather than
  cutting a tag with no notes; EVERY untagged version transition since the
  baseline is reconciled, oldest first, not just HEAD's — so a push carrying
  two bumps tags both, and a release a failed run missed is backfilled by
  the next push instead of waiting for a human to notice; and the run FAILS
  when installed plugin behavior changed after the current version's commit
  with no bump, since correct tags plus unreleased code was the one broken
  state the job used to call green. That last check runs AFTER tagging, so a
  missing bump never also withholds a tag that was legitimately due. The
  baseline (`TAG_RELEASE_BASELINE`, default `g2g--v0.6.5` — the last release
  tagged by hand) bounds what the job owns: pre-automation history contains
  versions that were never tagged and must stay that way, and it is why
  `g2g--v0.6.5` and older are out of scope rather than perpetually
  re-verified. Moving the baseline is also the break-glass recovery when an
  invalid transition is already on the default branch and wedges the job —
  no follow-up commit can fix one; see the script header for the procedure.
  An existing tag's annotation is compared too
  but only WARNS — the pre-automation tags carry hand-written summaries, and
  the only "repair" would be deleting a published tag, so failing there
  would trade cosmetic drift for a permanently red default branch. The job
  runs in no concurrency group on purpose: a group cancels a pending run
  when a third enters, which could leave a middle release untagged forever,
  and the script needs no serialization. Never create a release tag
  manually and never add a second tag scheme — a hand-cut tag on the wrong
  commit now wedges the job by design. Tagging was a manual post-merge step
  until 0.6.5 and lapsed for four straight releases (0.6.2–0.6.5 were
  tagged retroactively); that is the failure this automation prevents.
