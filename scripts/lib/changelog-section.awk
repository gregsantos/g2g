# Print the body of CHANGELOG.md's "## <v>" section. Pass the version with
# -v v=<version>. Blank lines between the heading and the first line of body
# are dropped; a "### Added" subheading starts with "###", not "##", so it is
# body rather than a section terminator.
#
# SOLE definition of how a release's notes are extracted. Both
# scripts/tag-release.sh (which lifts the notes into the tag annotation) and
# scripts/check-version-bump.sh (which only asks whether they exist) read it
# from here, so the two can never disagree about what counts as a section.

$1 == "##" && $2 == v         { inside = 1; next }
inside && $1 == "##"          { exit }
inside && !started && NF == 0 { next }
inside                        { started = 1; print }
