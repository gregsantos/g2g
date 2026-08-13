#!/usr/bin/env bash
# tag-release.sh — cut the release tags for every version released since the
# automation baseline.
#
# Repo infrastructure, NOT part of the shipped plugin: nothing under
# plugin/ calls this, and it is never installed. It runs from the
# tag-release job in .github/workflows/ci.yml on pushes to the default
# branch, and is a plain script (rather than bash embedded in YAML) so it
# is covered by `make lint` and pinned by tests/tag_release.bats.
#
# The tag TARGET is derived from history, never from HEAD: each version is
# tagged at the OLDEST first-parent commit carrying it, which is the commit
# that introduced it. That single choice is what makes the job safe under
# conditions HEAD-based tagging gets wrong:
#
#   - A push containing several commits whose version bump is not the tip
#     still tags the bump, not the tip.
#   - Two jobs racing at different HEADs compute the SAME target, so the
#     race is benign: whoever pushes second finds the tag already present
#     and pointing where it should. A docs-only push landing first can no
#     longer publish the version tag at the docs commit.
#
# The tag BODY comes from the same place: CHANGELOG.md as it stood AT THE
# TARGET COMMIT, read with git show, never from the working tree. Two
# consequences, both load-bearing:
#
#   - CLAUDE.md's rule that a version bump and its CHANGELOG entry land in
#     the SAME commit becomes enforced rather than assumed. Reading the
#     working tree let a batched push satisfy the guard with a CHANGELOG
#     entry added by a LATER commit, and then tag the bump with notes it
#     did not contain.
#   - The annotation is a function of the target alone, so racing runs at
#     different HEADs generate byte-identical tags, not merely tags on the
#     same commit.
#
# EVERY untagged version is reconciled, not just HEAD's. Reading one version
# off HEAD left two ways to lose a release permanently: a push carrying two
# bumps tagged only the newer, and a run that died before pushing was never
# revisited, because the next run looked only at the version it found at its
# own HEAD. Instead this walks first-parent from an explicit BASELINE and
# tags every version transition it finds, oldest first — so a missed release
# is picked up by the next push to the default branch instead of needing a
# human to notice. The baseline exists because history predating this
# automation contains versions that were never tagged and must stay that
# way; without it a first run would cut a pile of retroactive tags.
#
# The baseline is also the break-glass recovery for a WEDGED history. Every
# run replays every transition since the baseline, so an invalid transition
# already on the default branch — a backwards or malformed version, or a
# bump whose notes are missing at its own commit — fails every future run
# too: no later commit can change what a historical commit contained, and
# reverting only appends more history. Recover by moving
# TAG_RELEASE_BASELINE (set it on the tag-release job in ci.yml) past the
# bad transition, via a normal PR so the override is reviewed and recorded.
# Versions at or before the new baseline leave this job's scope
# permanently; if any of those were legitimately due, tag them by hand once
# — out-of-scope tags are never verified by this script, so a hand tag
# there cannot wedge the job the way an in-scope one would.
#
# Because targets are verifiable rather than incidental, an existing tag is
# CHECKED rather than trusted: a tag on the wrong commit is a corrupted
# release mapping, and this fails loudly instead of exiting 0 forever. A
# mismatched ANNOTATION on the right commit only warns — see verify_existing
# for why that asymmetry is deliberate.
#
# Finally, tagging is not the same as releasing: a merge that changes
# installed plugin behavior WITHOUT bumping the version leaves correct tags
# and unreleased code. scripts/check-version-bump.sh is invoked at the end
# to fail on exactly that, AFTER reconciliation, so a missing bump reports
# loudly without also withholding tags that are legitimately due.
#
# Environment overrides (tests and break-glass recovery; CI uses the defaults):
#   TAG_RELEASE_REMOTE    remote to fetch/push (default: origin)
#   TAG_RELEASE_DRY_RUN   1 = create tags locally, never push
#   TAG_RELEASE_BASELINE  commit-ish; versions introduced at or before it are
#                         out of scope (default: g2g--v0.6.5, the last
#                         release tagged by hand before this job existed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECTION_AWK="${SCRIPT_DIR}/lib/changelog-section.awk"
# shellcheck source=scripts/lib/semver.sh
source "${SCRIPT_DIR}/lib/semver.sh"
PLUGIN_JSON="plugin/.claude-plugin/plugin.json"
CHANGELOG="CHANGELOG.md"
REMOTE="${TAG_RELEASE_REMOTE:-origin}"
DRY_RUN="${TAG_RELEASE_DRY_RUN:-0}"
BASELINE_REF="${TAG_RELEASE_BASELINE:-g2g--v0.6.5}"

die() {
    echo "tag-release: $1" >&2
    exit "${2:-1}"
}

read_version_at() {
    # Version recorded in plugin.json at a given commit, empty if the file
    # is absent there (true for history predating the plugin layout).
    local commit="$1" out
    out="$(git show "${commit}:${PLUGIN_JSON}" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)" || out=""
    printf '%s' "$out"
}

# The release notes for $2 as they stood at commit $1. Empty when that
# commit has no CHANGELOG.md or no non-empty section for the version —
# callers treat both as the same broken paired edit.
changelog_body_at() {
    local commit="$1" v="$2" content
    content="$(git show "${commit}:${CHANGELOG}" 2>/dev/null)" || content=""
    [[ -n "$content" ]] || return 0
    awk -v v="$v" -f "$SECTION_AWK" <<<"$content"
}

verify_existing() {
    # An existing tag is only acceptable if it points where this run would
    # have put it. Peel it: these are annotated tags, so the tag object's
    # own sha is not the commit sha.
    local tag="$1" want_commit="$2" v="$3" annotation="$4" existing existing_annotation
    existing="$(git rev-list -n1 "$tag")"
    if [[ "$existing" != "$want_commit" ]]; then
        die "${tag} exists but points at $(git rev-parse --short "$existing"), not the commit that introduced ${v} ($(git rev-parse --short "$want_commit")).
A release tag on the wrong commit is a corrupted release mapping and will not be replaced automatically.
Delete the tag locally and on ${REMOTE}, then re-run, or correct plugin.json/CHANGELOG.md if the version is wrong."
    fi

    # The annotation is checked too, but only WARNS, while a wrong target
    # dies. The asymmetry is the point: the target is the release mapping,
    # so a wrong one is corrupt data with no reading that is correct. The
    # annotation is derived notes, and every legitimate way it can drift
    # leads somewhere this script must not go — the tags predating this
    # automation carry hand-written summaries rather than full sections,
    # and the only "repair" is deleting a published tag, which the design
    # above refuses to do. Failing here would convert cosmetic drift into a
    # permanently red default branch. Note that racing runs can no longer
    # be the cause: both derive the body from the same target commit.
    existing_annotation="$(git tag -l --format='%(contents)' "$tag")"
    if [[ "$existing_annotation" != "$annotation" ]]; then
        echo "tag-release: WARNING — ${tag} points at the correct commit but its annotation does not match ${CHANGELOG} at that commit.
Expected the '## ${v}' section verbatim. This is left as-is: a published release tag is never rewritten." >&2
    fi

    echo "tag-release: ${tag} already released at $(git rev-parse --short "$want_commit") — nothing to do"
}

create_and_push() {
    local tag="$1" commit="$2" v="$3" annotation="$4"
    git config user.name  "${GIT_AUTHOR_NAME:-github-actions[bot]}"
    git config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

    # --cleanup=verbatim, because git's default tag cleanup treats a line
    # starting with '#' as commentary and DELETES it — which silently ate
    # every '### Added'/'### Fixed' subheading in the notes. Verbatim also
    # makes the annotation byte-comparable in verify_existing.
    printf '%s\n' "$annotation" | git tag -a "$tag" "$commit" --cleanup=verbatim -F -
    echo "tag-release: created ${tag} at $(git rev-parse --short "$commit")"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "tag-release: dry run — not pushing"
        return 0
    fi

    if git push "$REMOTE" "$tag"; then
        echo "tag-release: pushed ${tag}"
        return 0
    fi

    # Lost a race to another job. Benign by construction — both computed the
    # same target and the same body — but verify rather than assume before
    # reporting success.
    echo "tag-release: push rejected, re-checking ${tag} on ${REMOTE}" >&2
    git tag -d "$tag" >/dev/null
    git fetch --quiet --tags "$REMOTE"
    git rev-parse -q --verify "refs/tags/${tag}" >/dev/null \
        || die "push of ${tag} failed and no such tag exists on ${REMOTE}"
    verify_existing "$tag" "$commit" "$v" "$annotation"
}

# Tag one version at the commit that introduced it, or verify the tag that
# is already there.
process_release() {
    local v="$1" commit="$2" body annotation
    local tag="g2g--v${v}"
    # Direct pushes to the default branch never pass the pre-merge gate, so
    # the format rule is re-checked here rather than assumed. A junk version
    # would otherwise publish a junk tag, which is unpushable to undo.
    semver_valid "$v" || die "$(git rev-parse --short "$commit") introduces version ${v}, which is not MAJOR.MINOR.PATCH.
Refusing to publish g2g--v${v} — see scripts/lib/semver.sh."
    body="$(changelog_body_at "$commit" "$v")"
    [[ -n "$body" ]] || die "${CHANGELOG} at $(git rev-parse --short "$commit") has no non-empty '## ${v}' section.
That commit introduces ${v}, so its notes belong to it. Bumps and CHANGELOG
entries land in the same commit — see CLAUDE.md. If that commit is already
on the default branch, no follow-up commit can fix it: recover by moving
TAG_RELEASE_BASELINE past it — see this script's header."
    annotation="$(printf 'g2g %s\n%s' "$v" "$body")"

    if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
        verify_existing "$tag" "$commit" "$v" "$annotation"
        return 0
    fi
    create_and_push "$tag" "$commit" "$v" "$annotation"
}

[[ -f "$PLUGIN_JSON" ]] || die "no ${PLUGIN_JSON} — run from the repository root"
[[ -f "$SECTION_AWK" ]] || die "missing ${SECTION_AWK}"

version="$(jq -r '.version // empty' "$PLUGIN_JSON" 2>/dev/null)" || version=""
[[ -n "$version" ]] || die "could not read .version from ${PLUGIN_JSON}"
semver_valid "$version" || die "version '${version}' in ${PLUGIN_JSON} is not MAJOR.MINOR.PATCH.
Checked on the RAW value before it is used for anything — see scripts/lib/semver.sh."

# Where the CURRENT version was introduced. Walk first-parent from HEAD
# while the version still matches; the last match is the oldest commit
# carrying it. Stop at the first commit that does not, so the walk costs one
# git-show per commit in the current release, not per commit in the
# repository. Needed independently of the reconciliation below, because the
# unreleased-changes check at the end applies even when the current version
# predates the baseline.
current_target=""
while read -r commit; do
    if [[ "$(read_version_at "$commit")" == "$version" ]]; then
        current_target="$commit"
    elif [[ -n "$current_target" ]]; then
        break
    fi
done < <(git rev-list --first-parent HEAD)

[[ -n "$current_target" ]] || die "HEAD does not carry version ${version}; refusing to guess a tag target"

baseline="$(git rev-parse --verify -q "${BASELINE_REF}^{commit}")" \
    || die "cannot resolve baseline ${BASELINE_REF} to a commit.
The baseline bounds which versions this job is responsible for; guessing it
would risk retroactively tagging pre-automation releases. Fetch tags, or set
TAG_RELEASE_BASELINE."

# Every version transition on first-parent since the baseline, oldest first.
# A transition is a commit whose version differs from its first parent's, so
# this finds each version's introducing commit without assuming anything
# about HEAD — which is what lets a later push backfill a release an earlier
# run failed to tag.
#
# Version and commit go into PARALLEL ARRAYS, never one packed string. A
# packed "<version> <commit>" split on the first space silently truncated a
# version containing whitespace down to a different, valid-looking one, and
# then published g2g--v<truncated> for a commit whose manifest said something
# else. Every raw value is validated here, before anything is used.
transition_versions=()
transition_commits=()
baseline_version="$(read_version_at "$baseline")"
prev_version="$baseline_version"
while read -r commit; do
    commit_version="$(read_version_at "$commit")"
    if [[ -n "$commit_version" && "$commit_version" != "$prev_version" ]]; then
        semver_valid "$commit_version" \
            || die "$(git rev-parse --short "$commit") sets the version to '${commit_version}', which is not MAJOR.MINOR.PATCH.
No tags were created. See scripts/lib/semver.sh for the format. If that
commit is already on the default branch, recover by moving
TAG_RELEASE_BASELINE past it — see this script's header."
        transition_versions+=("$commit_version")
        transition_commits+=("$commit")
    fi
    prev_version="$commit_version"
done < <(git rev-list --first-parent --reverse "${baseline}..HEAD")

# Narrow the window between the existence check and the push. Without this
# a tag created by a concurrent job after checkout is invisible here.
if [[ "$DRY_RUN" != "1" ]]; then
    git fetch --quiet --tags "$REMOTE" 2>/dev/null || true
fi

if [[ "${#transition_versions[@]}" -eq 0 ]]; then
    echo "tag-release: no version transitions since ${BASELINE_REF} ($(git rev-parse --short "$baseline")) — nothing to tag"
else
    # Releases only ever move forward, and that is verified across the WHOLE
    # sequence BEFORE any tag is created. A direct push to the default branch
    # never passes the pre-merge gate, so this is the only place the ordering
    # invariant is enforced for one — and a published tag cannot be taken
    # back, so discovering the problem after the first push is too late.
    #
    # Contrast the per-release CHANGELOG check below, which is deliberately
    # NOT preflighted: a missing section invalidates that one release while
    # the earlier ones remain legitimately due, whereas a backwards version
    # means the sequence itself is corrupt and no tag in it can be trusted.
    ordering_prev="$baseline_version"
    semver_valid "$ordering_prev" || ordering_prev=""
    for index in "${!transition_versions[@]}"; do
        candidate="${transition_versions[index]}"
        if [[ -n "$ordering_prev" ]] && ! semver_gt "$candidate" "$ordering_prev"; then
            die "version goes BACKWARDS at $(git rev-parse --short "${transition_commits[index]}"): ${ordering_prev} -> ${candidate}.
Release tags are immutable, so a lower version cannot describe newer code.
No tags were created by this run. If that commit is already on the default
branch, no follow-up bump can fix it: recover by moving
TAG_RELEASE_BASELINE past it — see this script's header."
        fi
        ordering_prev="$candidate"
    done

    # Chronological on purpose. A malformed older release stops the run
    # loudly rather than being skipped, so fixing it releases the rest;
    # that loud stop is the difference between this and the silent skip
    # that left four releases untagged.
    for index in "${!transition_versions[@]}"; do
        process_release "${transition_versions[index]}" "${transition_commits[index]}"
    done
fi

# Correct tags do not mean the code is released. Run last: any tag that was
# genuinely due has been cut by now, so this failure reports a missing bump
# without also withholding those tags.
"${SCRIPT_DIR}/check-version-bump.sh" --since "$current_target"
