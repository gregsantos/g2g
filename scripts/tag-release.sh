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
# Because the target is verifiable rather than incidental, an existing tag
# is CHECKED rather than trusted: a tag on the wrong commit is a corrupted
# release mapping, and this fails loudly instead of exiting 0 forever.
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

# Narrow the window between the existence check and the push. Without this
# a tag created by a concurrent job after checkout is invisible here.
if [[ "$DRY_RUN" != "1" ]]; then
    git fetch --quiet --tags "$REMOTE" 2>/dev/null || true
fi

verify_existing() {
    # An existing tag is only acceptable if it points where this run would
    # have put it. Peel it: these are annotated tags, so the tag object's
    # own sha is not the commit sha.
    local existing
    existing="$(git rev-list -n1 "$tag")"
    if [[ "$existing" == "$target" ]]; then
        echo "tag-release: ${tag} already released at $(git rev-parse --short "$target") — nothing to do"
        return 0
    fi
    die "${tag} exists but points at $(git rev-parse --short "$existing"), not the commit that introduced ${version} ($(git rev-parse --short "$target")).
A release tag on the wrong commit is a corrupted release mapping and will not be replaced automatically.
Delete the tag locally and on ${REMOTE}, then re-run, or correct plugin.json/CHANGELOG.md if the version is wrong."
}

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    verify_existing
    exit 0
fi

# A version bump with no CHANGELOG entry means the paired-edit rule in
# CLAUDE.md was broken. Fail rather than cut a tag with an empty body.
if ! awk -v v="$version" '$1 == "##" && $2 == v { found = 1 } END { exit !found }' "$CHANGELOG"; then
    die "plugin.json is at ${version} but ${CHANGELOG} has no '## ${version}' heading.
Bumps and CHANGELOG entries land in the same commit — see CLAUDE.md."
fi

# Tag body is that version's CHANGELOG section, so release notes are never
# written twice.
body="$(awk -v v="$version" '
    $1 == "##" && $2 == v { inside = 1; next }
    inside && $1 == "##"  { exit }
    inside                { print }
' "$CHANGELOG")"

git config user.name  "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

printf 'g2g %s\n%s\n' "$version" "$body" | git tag -a "$tag" "$target" -F -
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
