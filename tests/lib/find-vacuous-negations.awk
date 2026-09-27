# Prints file:line for every '!' negation in a bats test body that bash
# cannot enforce. errexit ignores the status of a '!' pipeline, so a
# negation that neither ends the test nor carries a failing guard can
# never fail its test: the assert is vacuous (D9, the F-060 class).
#
# This is an allowlist of two shapes, each a line holding one simple
# statement that starts with '!':
#   - the test's last statement, '! cmd' (bats reads its status as the
#     test's);
#   - '! cmd || <guard>', where the guard's final command is the suite's
#     idiom 'return <nonzero>': alone ('|| return 1'), closing a brace
#     group ('|| { echo ...; return 1; }'), or as the last statement of
#     a '|| {' block closed on a later line.
# Everything else that contains a negation is reported: any other guard
# ('|| true', '|| echo fail', '|| { false || true; }'), '||' that appears
# only in a comment or quoted text, and a negation joined to other
# commands by ';', '&&', a subshell, a group or a reserved word
# ('! cmd; true', 'true; ! cmd', 'if x; then ! cmd; fi'). Rewrite a
# reported line to one of the two shapes.
#
# Detection is conservative too: any '!' followed by whitespace, at line
# start or after whitespace or an operator, is a negation, except where
# bash or bats enforces the status itself: a condition negation inside
# '[[ ... ]]' or '[ ... ]', 'run ! cmd', and 'if', 'elif', 'while' or
# 'until' followed by '! cmd'.
# It reads one line at a time (joining '\' continuations), so a line
# inside a multi-line string literal is scanned as code: that can only
# over-report, so keep such strings one quoted entry per line.
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

# `code` with the negations bash or bats enforces removed, so that any
# '!' word left over is a pipeline negation.
function without_enforced_negations(code) {
    gsub(/\[\[[^]]*\]\]/, "[[ ]]", code)
    gsub(/\[[[:space:]][^]]*[[:space:]]\]/, "[ ]", code)
    while (match(code, /(^|[^[:alnum:]_])(run|if|elif|while|until)[[:space:]]+![[:space:]]/)) {
        code = substr(code, 1, RSTART - 1) " enforced " substr(code, RSTART + RLENGTH)
    }
    return code
}

# 1 when statement number `position` contains a negation outside the
# two allowed shapes above; `is_last` marks the test's final statement.
function is_unenforced(position, is_last,    code, head, guard, block_index, block_code) {
    code = code_only(statement_text[position])
    if (without_enforced_negations(code) !~ /(^|[[:space:];&|({])![[:space:]]/) return 0
    if (code !~ /^[[:space:]]*![[:space:]]/) return 1
    head = code
    if (index(code, "||") > 0) head = substr(code, 1, index(code, "||") - 1)
    if (head ~ /[;&(){}]/) return 1
    if (index(code, "||") == 0) return !is_last
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

# Fail closed on any layout this line-based reader cannot bound: a body
# that does not open at the end of its @test line, or one that never
# reaches a column-0 closing brace, is reported rather than skipped.
function report_unterminated() {
    if (in_test) {
        print test_file ":" test_line ": unterminated test body (close it with '}' at column 0): " test_text
    }
    in_test = 0
}

FNR == 1 { report_unterminated() }

/^@test / {
    report_unterminated()
    if ($0 !~ /\{[[:space:]]*$/) {
        print FILENAME ":" FNR ": unsupported @test layout (end the line with '{'): " $0
        next
    }
    in_test = 1
    test_file = FILENAME
    test_line = FNR
    test_text = $0
    statement_count = 0
    pending = ""
    next
}

in_test && /^}/ {
    flush_statement()
    for (position = 1; position <= statement_count; position++) {
        if (is_unenforced(position, position == statement_count)) {
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

END { report_unterminated() }
