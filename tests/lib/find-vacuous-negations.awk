# Prints file:line for every bare '! command' statement in a bats test
# body that is not the test's last statement. bash's errexit ignores the
# status of a '!' pipeline, so such a statement can never fail its test:
# the assert is vacuous (D9, the F-060 class). A negation guarded by
# '|| { ...; return 1; }', or one that ends the test (bats then reads its
# status as the test's), is enforced and is not reported.
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

/^@test / {
    in_test = 1
    statement_count = 0
    pending = ""
    next
}

in_test && /^}/ {
    flush_statement()
    for (index_in_test = 1; index_in_test < statement_count; index_in_test++) {
        text = statement_text[index_in_test]
        if (text ~ /^[[:space:]]*![[:space:]]/ && text !~ /\|\|/) {
            print FILENAME ":" statement_line[index_in_test] ": " text
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
