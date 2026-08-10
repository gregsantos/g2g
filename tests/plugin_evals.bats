#!/usr/bin/env bats

# Tests for plugin/evals/*/ — the eval case structure (F-014 groundwork).
# The eval harness itself is early access and not exercised here; this
# suite pins STRUCTURE only (required files, area-tag prefixes, and the
# proportional-grader phrase) so it stays useful before the harness
# lands and never becomes an executing gate on it afterward.

EVALS_DIR="$BATS_TEST_DIRNAME/../plugin/evals"

case_dirs() {
    find "$EVALS_DIR" -mindepth 1 -maxdepth 1 -type d | sort
}

@test "evals: at least one case directory exists" {
    run case_dirs
    [[ "$status" -eq 0 ]]
    [[ -n "$output" ]]
}

@test "evals: between 5 and 8 case directories" {
    count=$(case_dirs | wc -l | tr -d ' ')
    [[ "$count" -ge 5 ]]
    [[ "$count" -le 8 ]]
}

@test "evals: every case directory contains prompt.md and graders/criteria.md" {
    while IFS= read -r dir; do
        [[ -f "$dir/prompt.md" ]] || {
            echo "missing prompt.md: $dir"
            return 1
        }
        [[ -f "$dir/graders/criteria.md" ]] || {
            echo "missing graders/criteria.md: $dir"
            return 1
        }
    done < <(case_dirs)
}

@test "evals: every graders/criteria.md contains the phrase 'score proportionally'" {
    while IFS= read -r dir; do
        run grep -qi "score proportionally" "$dir/graders/criteria.md"
        [[ "$status" -eq 0 ]] || {
            echo "missing 'score proportionally': $dir/graders/criteria.md"
            return 1
        }
    done < <(case_dirs)
}

@test "evals: every graders/criteria.md enumerates at least 4 numbered criteria" {
    while IFS= read -r dir; do
        numbered=$(grep -cE '^[0-9]+\.' "$dir/graders/criteria.md")
        [[ "$numbered" -ge 4 ]] || {
            echo "fewer than 4 numbered criteria ($numbered): $dir/graders/criteria.md"
            return 1
        }
    done < <(case_dirs)
}

@test "evals: case directory names cover the four required area prefixes" {
    names=$(case_dirs | xargs -n1 basename)
    for prefix in spec- build- review- status-; do
        echo "$names" | grep -q "^${prefix}" || {
            echo "no case directory prefixed '$prefix'"
            return 1
        }
    done
}

@test "evals: README.md exists and lists every case with an area and dev/sealed set" {
    [[ -f "$EVALS_DIR/README.md" ]]
    while IFS= read -r dir; do
        name=$(basename "$dir")
        grep -q "$name" "$EVALS_DIR/README.md" || {
            echo "README.md does not mention case: $name"
            return 1
        }
    done < <(case_dirs)
    grep -qi "sealed" "$EVALS_DIR/README.md"
    grep -qi "dev" "$EVALS_DIR/README.md"
}

@test "evals: README.md marks at least one case sealed" {
    run grep -ci "sealed" "$EVALS_DIR/README.md"
    [[ "$status" -eq 0 ]]
    [[ "$output" -ge 1 ]]
}
