#!/usr/bin/env bats

# Tests for plugin/templates/*.json — the g2g init starter templates.
# Every template must parse as valid JSON and expose the required
# defaultBudgets defaults and reviewFocus categories (see issue #15).

TEMPLATES_DIR="$BATS_TEST_DIRNAME/../plugin/templates"

@test "templates: at least one template exists" {
    run bash -c 'ls "$0"/*.json' "$TEMPLATES_DIR"
    [[ "$status" -eq 0 ]]
    [[ -n "$output" ]]
}

@test "templates: every *.json parses as valid JSON" {
    for f in "$TEMPLATES_DIR"/*.json; do
        run jq . "$f"
        [[ "$status" -eq 0 ]] || {
            echo "invalid JSON: $f"
            echo "$output"
            return 1
        }
    done
}

@test "templates: every template has EXACTLY the required defaultBudgets values" {
    for f in "$TEMPLATES_DIR"/*.json; do
        run jq -e '
            .defaultBudgets ==
            { "buildTurnsFactor": 2, "buildHours": 2,
              "improveTurns": 50, "improveUsd": 25, "improveFindings": 3 }
        ' "$f"
        [[ "$status" -eq 0 ]] || {
            echo "defaultBudgets values wrong: $f"
            echo "$output"
            return 1
        }
    done
}

@test "templates: improve is disabled by default in every template" {
    for f in "$TEMPLATES_DIR"/*.json; do
        run jq -e '.improve == { "enabled": false }' "$f"
        [[ "$status" -eq 0 ]] || {
            echo "improve must default to { enabled: false }: $f"
            echo "$output"
            return 1
        }
    done
}

@test "templates: every template lists exactly the five reviewFocus categories" {
    for f in "$TEMPLATES_DIR"/*.json; do
        run jq -e '
            (.reviewFocus | sort) ==
            (["architecture","bug","code-quality","security","test-coverage"])
        ' "$f"
        [[ "$status" -eq 0 ]] || {
            echo "reviewFocus categories wrong: $f"
            echo "$output"
            return 1
        }
    done
}

@test "templates: verificationCommands is a non-empty array of non-empty strings" {
    for f in "$TEMPLATES_DIR"/*.json; do
        run jq -e '
            .verificationCommands
            | type == "array" and length > 0
              and all(.[]; type == "string" and length > 0)
        ' "$f"
        [[ "$status" -eq 0 ]] || {
            echo "invalid verificationCommands: $f"
            echo "$output"
            return 1
        }
    done
}

@test "templates: sourceDirs is a non-empty array of non-empty strings" {
    for f in "$TEMPLATES_DIR"/*.json; do
        run jq -e '
            .sourceDirs
            | type == "array" and length > 0
              and all(.[]; type == "string" and length > 0)
        ' "$f"
        [[ "$status" -eq 0 ]] || {
            echo "invalid sourceDirs: $f"
            echo "$output"
            return 1
        }
    done
}

@test "templates: greenfield verification command is exactly bash verify.sh" {
    run jq -e '.verificationCommands == ["bash verify.sh"]' \
        "$TEMPLATES_DIR/g2g-greenfield.json"
    [[ "$status" -eq 0 ]]
}
