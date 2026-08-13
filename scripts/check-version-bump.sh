#!/usr/bin/env bash
# check-version-bump.sh — enforce CLAUDE.md's rule that a change to
# installed plugin behavior carries a version bump and a CHANGELOG entry.
#
# Repo infrastructure, NOT part of the shipped plugin. Two modes, ONE
# definition of "release-sensitive", because the rule has to mean the same
# thing before and after the merge:
#
#   --base <ref>      PR mode, run by the version-bump job on pull requests.
#                     If anything release-sensitive changed in
#                     <ref>...HEAD, the version must differ from <ref>'s and
#                     CHANGELOG.md must carry a non-empty section for it.
#                     Blocks the bad merge instead of reporting it after.
#
#   --since <commit>  Post-merge mode, run by tag-release.sh. <commit> is
#                     where the CURRENT version was introduced, so anything
#                     release-sensitive after it is shipped-but-unreleased:
#                     the release tag exists and points at a commit without
#                     that code, and consumers installing the plugin cannot
#                     see it. Before this check the tag job exited 0 green in
#                     exactly that state, which is what made the failure
#                     silent.
#
# Exit 0 clean, 1 violation, 2 usage or environment error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECTION_AWK="${SCRIPT_DIR}/lib/changelog-section.awk"
# shellcheck source=scripts/lib/semver.sh
source "${SCRIPT_DIR}/lib/semver.sh"
PLUGIN_JSON="plugin/.claude-plugin/plugin.json"
CHANGELOG="CHANGELOG.md"

# Everything under plugin/ is installed behavior EXCEPT these. Deliberately
# an EXCLUDE list rather than an include list: a plugin subdirectory added
# later is release-sensitive by default, so nobody can weaken this guard by
# forgetting to register a new directory with it. plugin/workflows/ and the
# .md files under plugin/commands/ and plugin/skills/ are behavior, not
# documentation, despite their extensions — commands are procedures.
DOCS_ONLY=(
    "plugin/README.md"
    "plugin/evals/"
)

die() {
    echo "check-version-bump: $1" >&2
    exit "${2:-1}"
}

usage() {
    echo "usage: check-version-bump.sh --base <ref> | --since <commit>" >&2
    exit 2
}

# Release-sensitive paths changed across a git diff range, one per line.
# Uses the NET diff on purpose: a change made and then reverted within the
# range leaves the installed plugin identical and needs no bump.
#
# --no-renames is load-bearing, not tidiness. Git detects renames by default
# and reports only the DESTINATION path, so renaming an installed file into
# an excluded directory (plugin/commands/x.md -> plugin/evals/x.md) surfaced
# only the excluded path and passed the guard — while the installed command
# was in fact deleted. With --no-renames the same change is a deletion plus
# an addition, so the release-sensitive source path is still seen.
#
# -z because a path may contain whitespace or newlines; entries are read
# NUL-delimited so classification is exact. (The newline-separated output is
# for display only — detection is on whether anything survived the filter.)
release_sensitive_changes() {
    local path prefix excluded
    while IFS= read -r -d '' path; do
        [[ -n "$path" ]] || continue
        excluded=0
        for prefix in "${DOCS_ONLY[@]}"; do
            if [[ "$path" == "$prefix" || "$path" == "$prefix"* ]]; then
                excluded=1
                break
            fi
        done
        (( excluded )) || printf '%s\n' "$path"
    done < <(git diff --no-renames --name-only -z "$@" -- plugin)
}

version_at() {
    git show "${1}:${PLUGIN_JSON}" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true
}

mode=""
ref=""
case "${1:-}" in
    --base|--since) mode="$1"; ref="${2:-}" ;;
    *) usage ;;
esac
[[ -n "$ref" ]] || usage
[[ -f "$PLUGIN_JSON" ]] || die "no ${PLUGIN_JSON} — run from the repository root" 2
git rev-parse --verify -q "${ref}^{commit}" >/dev/null \
    || die "cannot resolve ${ref} to a commit" 2

if [[ "$mode" == "--since" ]]; then
    # Validated here as well as in tag-release.sh, so this mode is safe to
    # run standalone rather than trusting its only current caller.
    since_version="$(version_at HEAD)"
    [[ -n "$since_version" ]] || die "could not read .version from ${PLUGIN_JSON}" 2
    semver_valid "$since_version" || die "version ${since_version} is not MAJOR.MINOR.PATCH."

    changed="$(release_sensitive_changes "$ref" HEAD)"
    if [[ -n "$changed" ]]; then
        die "installed plugin behavior changed after the commit that introduced version ${since_version}, with no version bump.

$(printf '  %s\n' "$changed")

Those changes are released nowhere: $(git rev-parse --short "$ref") is what the
release tag points at, and it does not contain them. Bump
${PLUGIN_JSON} and add the matching ${CHANGELOG} section — see CLAUDE.md's
one-bump-per-PR rule. Any release tags that were missing have already been
cut by this run; only this invariant failed."
    fi
    echo "check-version-bump: no unreleased plugin changes since $(git rev-parse --short "$ref")"
    exit 0
fi

# --base: PR mode. Validates the FINAL tree — in CI, HEAD is GitHub's
# refs/pull/N/merge, the PR merged into its current base — which is exactly
# the tree a merge commit or a squash lands on the default branch, so what
# passes here is what tag-release.sh later walks. Rebase integration is the
# one method this cannot model: it replays the branch's commits one by one,
# so a bump whose CHANGELOG section arrives in a later commit, or a branch
# carrying several bumps, lands intermediate states this gate never saw.
# tag-release.sh still fails closed on the bad ones (a transition without
# its notes at the transition commit is refused, never tagged empty) — but
# post-merge, with the default branch red. CLAUDE.md already mandates merge
# commits for g2g/* PRs; prefer them for anything that bumps the version.
base="$(git merge-base "$ref" HEAD)"
changed="$(release_sensitive_changes "${ref}...HEAD")"
if [[ -z "$changed" ]]; then
    echo "check-version-bump: no release-sensitive plugin changes in this branch — no bump required"
    exit 0
fi

head_version="$(version_at HEAD)"
base_version="$(version_at "$base")"
[[ -n "$head_version" ]] || die "could not read .version from ${PLUGIN_JSON}" 2

semver_valid "$head_version" || die "version ${head_version} is not MAJOR.MINOR.PATCH.
The tag scheme (g2g--v<version>) and the ${CHANGELOG} heading both assume that
shape; pre-release and build suffixes are a release-policy change to make
deliberately, not by typo."

# A "bump" has to move FORWARD. Merely differing from the base let a
# downgrade through — and a downgrade to an already-released version passes
# the CHANGELOG check below on the old section, merges, and then wedges the
# tag job on the existing tag, leaving main red and the change unreleased.
# When the base version is missing or malformed the ordering cannot be
# judged; that is history this branch did not create, so it is skipped rather
# than blamed on the PR. The checks that do not need a base still apply.
if [[ -z "$base_version" ]] || ! semver_valid "$base_version"; then
    echo "check-version-bump: base version ${base_version:-none} is unusable — skipping the ordering check" >&2
elif [[ "$head_version" == "$base_version" ]]; then
    die "this branch changes installed plugin behavior but leaves the version at ${head_version}.

$(printf '  %s\n' "$changed")

Bump ${PLUGIN_JSON} and add the matching ${CHANGELOG} section in the same
commit — see CLAUDE.md's one-bump-per-PR rule. Docs-only edits under plugin/
need neither, but these paths are installed behavior."
elif ! semver_gt "$head_version" "$base_version"; then
    die "version goes BACKWARDS on this branch: ${base_version} -> ${head_version}.
A release version only ever increases. Going back re-points a version at new
code, and if ${head_version} was already released the tag job will refuse to
move its tag — the merge would leave the default branch red and these changes
released nowhere."
fi

# Reusing a released version is the same corruption seen from the other side:
# the tag exists at the commit that first shipped it and is never moved, so
# the new code would have no release of its own.
#
# What this does NOT catch: two OPEN PRs claiming the same version. Tags are
# created only after a merge, so while both are open neither branch can see
# the clash — no pre-merge script can. Once the first PR merges and its tag
# exists, this check fails the second — but only if the second PR's checks
# re-run, and GitHub forces that re-run only under an up-to-date-branches
# rule or a merge queue (this repo has neither, and supports direct pushes
# to the default branch by design). If the stale PR merges anyway, the tag
# job's --since check fails that push loudly: its plugin changes carry no
# new version transition, so they are shipped-but-unreleased until a
# follow-up bump. Late, but never silent.
if git rev-parse -q --verify "refs/tags/g2g--v${head_version}" >/dev/null; then
    die "${head_version} is already released: tag g2g--v${head_version} exists at $(git rev-parse --short "g2g--v${head_version}^{commit}").
Release tags are never moved, so this version cannot describe new code. Pick
the next unused version — and check whether another branch already claimed
this one."
fi

# The paired-edit half of the same rule, checked here so it is caught before
# the merge rather than by tag-release.sh after it.
if [[ -z "$(awk -v v="$head_version" -f "$SECTION_AWK" "$CHANGELOG")" ]]; then
    die "version is bumped to ${head_version} but ${CHANGELOG} has no non-empty '## ${head_version}' section.
Bumps and CHANGELOG entries land in the same commit — see CLAUDE.md."
fi

echo "check-version-bump: ${base_version:-none} -> ${head_version} with a ${CHANGELOG} section"
