#!/usr/bin/env bats

# Tests for plugin/scripts/g2g-slug.sh — the sole implementation of the
# slug derivation that turns a spec's `project` field (or a task summary)
# into a git-ref-safe, filename-safe token (F-035). Every /g2g:* command
# that names a branch or a spec file calls this; none restates the rule.

SLUG="$BATS_TEST_DIRNAME/../plugin/scripts/g2g-slug.sh"

@test "slug: script exists and is executable" {
    [[ -x "$SLUG" ]] || { echo "g2g-slug.sh missing or not executable"; return 1; }
}

@test "slug: lowercases and hyphenates a plain project name" {
    run "$SLUG" "User Preferences API"
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    [[ "$output" == "user-preferences-api" ]] || { echo "got: $output"; return 1; }
}

@test "slug: every character outside [a-z0-9] becomes a hyphen and runs collapse" {
    run "$SLUG" "Improve 2026-07-22 (round #2) — fix/spec_thing"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "improve-2026-07-22-round-2-fix-spec-thing" ]] || { echo "got: $output"; return 1; }
}

@test "slug: leading and trailing hyphens are trimmed" {
    run "$SLUG" "  --Hello World!! "
    [[ "$status" -eq 0 ]]
    [[ "$output" == "hello-world" ]] || { echo "got: $output"; return 1; }
}

@test "slug: output is capped at 60 characters with no trailing hyphen" {
    long="$(printf 'word-%.0s' $(seq 1 20))"   # 100 chars, hyphen at every 5th
    run "$SLUG" "$long"
    [[ "$status" -eq 0 ]]
    [[ "${#output}" -le 60 ]] || { echo "length ${#output}: $output"; return 1; }
    [[ "$output" != *- ]] || { echo "trailing hyphen: $output"; return 1; }
}

@test "slug: exit 2 with a message when nothing slug-worthy remains" {
    run "$SLUG" "!!! ??? ..."
    [[ "$status" -eq 2 ]] || { echo "expected exit 2, got $status: $output"; return 1; }
    [[ "$output" == *"no slug"* ]] || { echo "message does not explain: $output"; return 1; }
}

@test "slug: exit 2 on a missing argument" {
    run "$SLUG"
    [[ "$status" -eq 2 ]] || { echo "expected exit 2, got $status: $output"; return 1; }
}

@test "slug: --spec reads the project field from a spec file" {
    printf '{"project": "Concurrency Safety", "tasks": []}\n' > "$BATS_TEST_TMPDIR/spec.json"
    run "$SLUG" --spec "$BATS_TEST_TMPDIR/spec.json"
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    [[ "$output" == "concurrency-safety" ]] || { echo "got: $output"; return 1; }
}

@test "slug: --spec exits 2 on a missing file or a missing/non-string project field" {
    run "$SLUG" --spec "$BATS_TEST_TMPDIR/nope.json"
    [[ "$status" -eq 2 ]] || { echo "missing file: expected exit 2, got $status: $output"; return 1; }
    printf '{"tasks": []}\n' > "$BATS_TEST_TMPDIR/noproj.json"
    run "$SLUG" --spec "$BATS_TEST_TMPDIR/noproj.json"
    [[ "$status" -eq 2 ]] || { echo "no project: expected exit 2, got $status: $output"; return 1; }
    printf '{"project": ["x"], "tasks": []}\n' > "$BATS_TEST_TMPDIR/arrproj.json"
    run "$SLUG" --spec "$BATS_TEST_TMPDIR/arrproj.json"
    [[ "$status" -eq 2 ]] || { echo "array project: expected exit 2, got $status: $output"; return 1; }
}

@test "slug: hostile inputs always yield a valid branch name under refs/heads/g2g/" {
    # The finding's threat: a project value carrying ref traversal, shell
    # metacharacters, git-reserved suffixes, or a leading dash reaching
    # `git checkout -b` or `gh pr create`. Whatever comes out must be a
    # ref component git itself accepts.
    for hostile in '../main' '$(id)' '"; rm -rf /; echo "' 'name.lock' '-rf' 'a..b' 'über café' 'x@{1}' $'new\nline' 'tab	here'; do
        run "$SLUG" "$hostile"
        [[ "$status" -eq 0 ]] || { echo "input [$hostile]: exit $status: $output"; return 1; }
        [[ "$output" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
            || { echo "input [$hostile] -> [$output] escapes the charset"; return 1; }
        git check-ref-format "refs/heads/g2g/$output" \
            || { echo "input [$hostile] -> [$output] is not a valid ref"; return 1; }
    done
}

@test "slug: runs under the macOS system bash 3.2 when present" {
    [[ -x /bin/bash ]] || skip "no /bin/bash on this host"
    run /bin/bash "$SLUG" "Sandbox greeting"
    [[ "$status" -eq 0 ]] || { echo "exit $status under /bin/bash: $output"; return 1; }
    [[ "$output" == "sandbox-greeting" ]] || { echo "got: $output"; return 1; }
}

@test "slug: agrees with the smoke sandbox branch name" {
    # tests/smoke.sh hardcodes BRANCH=g2g/sandbox-greeting for the sandbox
    # spec whose project is "Sandbox greeting"; the helper must produce it.
    expected=$(grep -E '^BRANCH="g2g/' "$BATS_TEST_DIRNAME/smoke.sh" | sed -e 's/^BRANCH="g2g\///' -e 's/"$//')
    project=$(grep -E '^  "project":' "$BATS_TEST_DIRNAME/make_sandbox.sh" | head -1 | sed -e 's/.*: "//' -e 's/",$//')
    [[ -n "$expected" && -n "$project" ]] || { echo "could not read fixtures (branch=$expected project=$project)"; return 1; }
    run "$SLUG" "$project"
    [[ "$output" == "$expected" ]] || { echo "helper gives [$output], smoke expects [$expected]"; return 1; }
}

@test "slug: --spec never evaluates the project text as shell, even when it contains command substitutions" {
    # Codex review of PR #35: a caller that pastes project text into a
    # double-quoted argument lets Bash expand $(...) and backticks before
    # the helper runs. The --spec form reads the value from JSON, so the
    # same text is inert. The marker would appear on stderr if anything
    # evaluated it.
    jq -n '{project: "Audit $(printf F035_EXPANDED >&2) `printf F035_BACKTICK >&2` done", tasks: []}' > "$BATS_TEST_TMPDIR/hostile.json"
    run "$SLUG" --spec "$BATS_TEST_TMPDIR/hostile.json"
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    [[ "$output" != *"F035_"* ]] || { echo "project text was evaluated: $output"; return 1; }
    [[ "$output" == "audit-printf-f035-expanded-2-printf-f035-backtick-2-done" ]] || { echo "got: $output"; return 1; }
}

