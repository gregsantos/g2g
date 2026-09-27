# Prints file:line for every bare '! command' statement in a bats test
# body that is not the test's last statement. bash's errexit ignores the
# status of a '!' pipeline, so such a statement can never fail its test:
# the assert is vacuous (D9, the F-060 class). A negation that ends the
# test (bats then reads its status as the test's) is enforced. So is one
# whose '||' guard has the suite's idiom as its final command,
# 'return <nonzero>': alone ('|| return 1'), closing a brace group
# ('|| { echo ...; return 1; }'), or as the last statement of a '|| {'
# block closed on a later line. This is an allowlist, not a search for
# failure words: any other guard ('|| true', '|| echo fail',
# '|| { false || true; }') is reported, and so is '||' that appears only
# in a comment or quoted text. Rewrite a reported line to the idiom.
#
# Usage: awk -f find-vacuous-negations.awk tests/*.bats

function flush_statement() {
    if (pending != "") {
        statement_count++
        statement_text[statement_count] = pending
        statement_line[statement_count] = pending_line
    }
    pending = ""
}

# The statement with quoted text blanked and any trailing comment
# removed, so only real shell operators remain.
function code_only(text,    result) {
    result = text
    gsub(/'[^']*'/, "''", result)
    gsub(/"([^"\\]|\\.)*"/, "\"\"", result)
    sub(/(^|[[:space:]])#.*$/, "", result)
    return result
}

function trim(text) {
    sub(/^[[:space:]]+/, "", text)
    sub(/[[:space:]]+$/, "", text)
    return text
}

function is_return_nonzero(code) {
    return trim(code) ~ /^return[[:space:]]+[1-9][0-9]*[[:space:]]*;?$/
}

# 1 when statement number `position` is a '!' negation with no guard
# that can fail the test.
function is_vacuous(position,    code, guard, block_index, block_code) {
    code = code_only(statement_text[position])
    if (code !~ /^[[:space:]]*![[:space:]]/) return 0
    if (index(code, "||") == 0) return 1
    guard = trim(substr(code, index(code, "||") + 2))
    if (is_return_nonzero(guard)) return 0
    if (guard ~ /^\{.*[{;][[:space:]]*return[[:space:]]+[1-9][0-9]*[[:space:]]*;[[:space:]]*\}$/) return 0
    if (guard != "{") return 1
    for (block_index = position + 1; block_index <= statement_count; block_index++) {
        block_code = trim(code_only(statement_text[block_index]))
        if (block_code ~ /^\}/) {
            return !(block_index > position + 1 && is_return_nonzero(code_only(statement_text[block_index - 1])))
        }
    }
    return 1
}

/^@test / {
    in_test = 1
    statement_count = 0
    pending = ""
    next
}

in_test && /^}/ {
    flush_statement()
    for (position = 1; position < statement_count; position++) {
        if (is_vacuous(position)) {
            print FILENAME ":" statement_line[position] ": " statement_text[position]
        }
    }
    in_test = 0
    next
}

in_test {
    if (pending == "") {
        if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
        pending_line = FNR
        pending = $0
    } else {
        pending = pending " " $0
    }
    if (pending ~ /\\$/) {
        sub(/\\$/, "", pending)
    } else {
        flush_statement()
    }
}
