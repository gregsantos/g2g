#!/usr/bin/env bash
# tag-release.sh — cut the release tag for the version in plugin.json.
#
# Repo infrastructure, NOT part of the shipped plugin: nothing under
# plugin/ calls this, and it is never installed. It runs from the
# tag-release job in .github/workflows/ci.yml on pushes to the default
# branch, and is a plain script (rather than bash embedded in YAML) so it
# is covered by `make lint` and pinned by tests/tag_release.bats.
#
# The tag TARGET is derived from history, never from HEAD: it is the
# OLDEST first-parent commit carrying the current version, which is the
# commit that introduced it. That single choice is what makes the job
# safe under conditions HEAD-based tagging gets wrong:
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
# Because the target is verifiable rather than incidental, an existing tag
# is CHECKED rather than trusted: a tag on the wrong commit is a corrupted
# release mapping, and this fails loudly instead of exiting 0 forever. A
# mismatched ANNOTATION on the right commit only warns — see
# verify_existing for why that asymmetry is deliberate.
#
# Environment overrides (tests only; CI uses the defaults):
#   TAG_RELEASE_REMOTE    remote to fetch/push (default: origin)
#   TAG_RELEASE_DRY_RUN   1 = create the tag locally, never push
set -euo pipefail

PLUGIN_JSON="plugin/.claude-plugin/plugin.json"
CHANGELOG="CHANGELOG.md"
REMOTE="${TAG_RELEASE_REMOTE:-origin}"
DRY_RUN="${TAG_RELEASE_DRY_RUN:-0}"

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

[[ -f "$PLUGIN_JSON" ]] || die "no ${PLUGIN_JSON} — run from the repository root"

version="$(jq -r '.version // empty' "$PLUGIN_JSON" 2>/dev/null)" || version=""
[[ -n "$version" ]] || die "could not read .version from ${PLUGIN_JSON}"
tag="g2g--v${version}"

# Resolve the version-introducing commit. Walk first-parent from HEAD
# while the version still matches; the last match is the oldest commit
# carrying it. Stop at the first commit that does not, so the walk costs
# one git-show per commit in the current release, not per commit in the
# repository.
target=""
while read -r commit; do
    if [[ "$(read_version_at "$commit")" == "$version" ]]; then
        target="$commit"
    elif [[ -n "$target" ]]; then
        break
    fi
done < <(git rev-list --first-parent HEAD)

[[ -n "$target" ]] || die "HEAD does not carry version ${version}; refusing to guess a tag target"

# Resolve the annotation BEFORE looking at the remote or at existing tags:
# it depends only on the target commit, and a broken paired edit should fail
# the same way whether or not the network is reachable.
changelog="$(git show "${target}:${CHANGELOG}" 2>/dev/null)" || changelog=""
[[ -n "$changelog" ]] || die "commit $(git rev-parse --short "$target") introduces ${version} but has no ${CHANGELOG}.
Bumps and CHANGELOG entries land in the same commit — see CLAUDE.md."

# The version's own section, with blank lines before the body dropped. A
# `### Added` subheading starts with "###", not "##", so it is body, not a
# section terminator.
body="$(awk -v v="$version" '
    $1 == "##" && $2 == v            { inside = 1; next }
    inside && $1 == "##"             { exit }
    inside && !started && NF == 0    { next }
    inside                           { started = 1; print }
' <<<"$changelog")"

# An empty section is as much a broken paired edit as a missing one: it
# means the bump commit carried a heading and no notes.
[[ -n "$body" ]] || die "${CHANGELOG} at $(git rev-parse --short "$target") has no non-empty '## ${version}' section.
Bumps and CHANGELOG entries land in the same commit — see CLAUDE.md."

annotation="$(printf 'g2g %s\n%s' "$version" "$body")"

# Narrow the window between the existence check and the push. Without this
# a tag created by a concurrent job after checkout is invisible here.
if [[ "$DRY_RUN" != "1" ]]; then
    git fetch --quiet --tags "$REMOTE" 2>/dev/null || true
fi

verify_existing() {
    # An existing tag is only acceptable if it points where this run would
    # have put it. Peel it: these are annotated tags, so the tag object's
    # own sha is not the commit sha.
    local existing existing_annotation
    existing="$(git rev-list -n1 "$tag")"
    if [[ "$existing" != "$target" ]]; then
        die "${tag} exists but points at $(git rev-parse --short "$existing"), not the commit that introduced ${version} ($(git rev-parse --short "$target")).
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
Expected the '## ${version}' section verbatim. This is left as-is: a published release tag is never rewritten." >&2
    fi

    echo "tag-release: ${tag} already released at $(git rev-parse --short "$target") — nothing to do"
}

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    verify_existing
    exit 0
fi

git config user.name  "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

# --cleanup=verbatim, because git's default tag cleanup treats a line
# starting with '#' as commentary and DELETES it — which silently ate every
# '### Added'/'### Fixed' subheading in the notes. Verbatim also makes the
# annotation byte-comparable in verify_existing.
printf '%s\n' "$annotation" | git tag -a "$tag" "$target" --cleanup=verbatim -F -
echo "tag-release: created ${tag} at $(git rev-parse --short "$target")"

if [[ "$DRY_RUN" == "1" ]]; then
    echo "tag-release: dry run — not pushing"
    exit 0
fi

if git push "$REMOTE" "$tag"; then
    echo "tag-release: pushed ${tag}"
    exit 0
fi

# Lost a race to another job. Benign by construction — both computed the
# same target — but verify rather than assume before reporting success.
echo "tag-release: push rejected, re-checking ${tag} on ${REMOTE}" >&2
git tag -d "$tag" >/dev/null
git fetch --quiet --tags "$REMOTE"
git rev-parse -q --verify "refs/tags/${tag}" >/dev/null \
    || die "push of ${tag} failed and no such tag exists on ${REMOTE}"
verify_existing
