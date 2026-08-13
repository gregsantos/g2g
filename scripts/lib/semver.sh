# shellcheck shell=bash
# Version-string rules for g2g releases. SOLE definition, shared by
# scripts/check-version-bump.sh and scripts/tag-release.sh, so the pre-merge
# gate and the tag job can never disagree about what a valid version is.
#
# Deliberately plain MAJOR.MINOR.PATCH with no pre-release or build suffix:
# every version this project has shipped is that shape, the tag scheme
# (g2g--v<version>) and the CHANGELOG heading (## <version>) both assume it,
# and admitting suffixes is a release-policy decision to make on purpose
# rather than by accident. Leading zeros are rejected, per semver.

SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

semver_valid() {
    [[ "$1" =~ $SEMVER_RE ]]
}

# True when $1 is strictly greater than $2. Compares components numerically
# rather than shelling out to `sort -V`, whose availability and semantics
# differ between GNU and BSD userland.
semver_gt() {
    local -a left right
    IFS=. read -r -a left <<<"$1"
    IFS=. read -r -a right <<<"$2"
    local i
    for i in 0 1 2; do
        (( 10#${left[i]} > 10#${right[i]} )) && return 0
        (( 10#${left[i]} < 10#${right[i]} )) && return 1
    done
    return 1
}
