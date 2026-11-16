#!/usr/bin/env bash
# g2g-timing.sh — per-task wall clock and dispatch counts for a build,
# read back from the build branch's own bookkeeping commits (issue #25).
# Usage: g2g-timing.sh <spec.json> [--range <revision-range>]
# Exit: 0 block printed (a task with no commits in range prints as
#       unmeasured, never as an error); 2 missing/invalid spec, unknown
#       argument, unusable range, or no default branch to measure from.
#
# Read-only, and it records nothing new: every build already commits
# `chore(<id>): start` when it dispatches a builder and a terminal
# bookkeeping commit when it scores the attempt (`complete`,
# `needs-human`, or `attempt <n>[, blocked]` — both engines write these
# subjects). The gap between the two author dates is that attempt's wall
# clock. Author dates, because build.md rebases the branch before the PR
# and a rebase rewrites committer dates but keeps author dates; merge
# commits keep both, so a merged build stays measurable from a fresh clone.
#
# An attempt with no `start` commit of its own (a retry whose status was
# already in_progress, so the start commit had nothing to change) is
# timed from the previous bookkeeping commit of any task — one writer
# per checkout means that is when the retry was dispatched. A task whose
# last start has no terminal commit is reported `unfinished` and adds no
# time. Other `chore(<id>): …` subjects are not attempt boundaries and
# are ignored. `dispatches` counts scored attempts: in /g2g:build each is
# one orchestrator turn (Phase 3 runs one attempt per turn).
#
# The summary's elapsed is first to last bookkeeping commit in range;
# elapsed minus serial is time spent outside any builder attempt
# (orchestration between tasks, plus anything else that ran on the
# branch in that window). Its fan-out ceiling is serial / critical-path:
# the sum of every task's wall clock over the longest dependsOn chain
# weighted the same way. It is the most an unlimited fan-out of
# independent tasks could save on this build's builder time, before any
# merge or extra verification cost: an upper bound, not a forecast.
#
# Default range: <merge-base of HEAD and the remote default branch>..HEAD,
# the default branch taken from origin/HEAD, falling back to origin/main
# then origin/master. Pass --range for anything else (a merged build:
# `<merge>^1..<merge>`). Task ids are compared to commit subjects as
# literal strings, never as patterns.
set -euo pipefail

fail() { echo "g2g-timing: $1" >&2; exit 2; }
clean() { printf '%s' "$1" | tr -d '[:cntrl:]'; }

SPEC="${1:-}"
if (($#)); then shift; fi
RANGE=""
while (($#)); do
    case "$1" in
        --range)
            (($# >= 2)) || fail "--range needs a revision range"
            RANGE="$2"
            shift 2
            ;;
        *) fail "unknown argument: $(clean "$1")" ;;
    esac
done

[[ -n "$SPEC" && -f "$SPEC" ]] || fail "spec not found: $(clean "${SPEC:-<missing>}")"
jq empty "$SPEC" 2>/dev/null || fail "spec is not valid JSON: $(clean "$SPEC")"
jq -e '.tasks | type == "array" and all(.[]?;
        type == "object" and (.id | type == "string")
        and ((.dependsOn // []) | type == "array" and all(.[]?; type == "string")))' \
    "$SPEC" >/dev/null \
    || fail "tasks must be an array of objects with a string id and a dependsOn array of strings: $(clean "$SPEC")"

git rev-parse --git-dir >/dev/null 2>&1 || fail "not inside a git repository"

if [[ -z "$RANGE" ]]; then
    BASE_REF=""
    if ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
        BASE_REF="$ref"
    else
        for candidate in origin/main origin/master; do
            if git rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then
                BASE_REF="$candidate"
                break
            fi
        done
    fi
    [[ -n "$BASE_REF" ]] || fail "no remote default branch (origin/HEAD, origin/main, origin/master); pass --range"
    BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null) || fail "HEAD shares no history with $BASE_REF; pass --range"
    RANGE="$BASE..HEAD"
fi
# A leading dash would reach git log as an option, not a revision.
[[ "$RANGE" != -* ]] || fail "range must not start with '-': $(clean "$RANGE")"

LOG=$(git log --reverse --author-date-order --format='%at%x09%s' "$RANGE" -- 2>/dev/null) \
    || fail "git log cannot read range: $(clean "$RANGE")"

# One jq program does the pairing, the critical path, and the formatting,
# so the arithmetic lives in one place. Input: the log as raw text, the
# spec as $spec. Every spec string that reaches stdout has control
# characters stripped, like g2g-evidence.sh.
printf '%s' "$LOG" | jq -R -s -r --slurpfile spec "$SPEC" --arg range "$RANGE" --arg specPath "$SPEC" '
    def clean: tostring | gsub("[[:cntrl:]]"; " ");
    def two: tostring | if length < 2 then "0" + . else . end;
    def dur:
        if . >= 3600 then "\(. / 3600 | floor)h\(. % 3600 / 60 | floor | two)m"
        elif . >= 60 then "\(. / 60 | floor)m\(. % 60 | two)s"
        else "\(.)s" end;
    def pad($n): . + (" " * ([$n - length, 0] | max));

    ($spec[0].tasks) as $tasks
    | ($tasks | map(.id)) as $ids
    # Bookkeeping events for this spec, oldest first.
    | [ split("\n")[] | select(length > 0)
        | capture("^(?<t>[0-9]+)\t(?<type>[a-z]+)\\((?<id>[^)]*)\\): (?<rest>.*)$")?
        | select(.type == "chore") | .t |= tonumber
        | select(.id as $id | any($ids[]; . == $id))
        | .kind = (if .rest == "start" then "start"
                   elif .rest == "complete" then "complete"
                   elif .rest == "needs-human" then "needs-human"
                   elif (.rest | test("^attempt [0-9]+, blocked")) then "blocked"
                   elif (.rest | test("^attempt [0-9]+")) then "failed"
                   else null end)
        | select(.kind != null) ]
    # Pair each terminal event with its attempt start.
    | (if length > 0 then .[-1].t - .[0].t else 0 end) as $elapsed
    | (reduce .[] as $e ({open: {}, last: null, per: {}};
        if $e.kind == "start" then .open[$e.id] = $e.t
        else
            (.open[$e.id] // .last) as $from
            | .per[$e.id].dispatches += 1
            | .per[$e.id].outcome = $e.kind
            | .per[$e.id].wall += (if $from == null then 0 else $e.t - $from end)
            | .per[$e.id].untimed += (if $from == null then 1 else 0 end)
            | .open |= del(.[$e.id])
        end
        | .last = $e.t)) as $acc
    | [ $tasks[] | .id as $id
        | { id: $id, deps: (.dependsOn // []),
            dispatches: ($acc.per[$id].dispatches // 0),
            wall: ($acc.per[$id].wall // 0),
            untimed: ($acc.per[$id].untimed // 0),
            outcome: (if $acc.open[$id] != null then "unfinished"
                      else $acc.per[$id].outcome // "unmeasured" end) } ] as $rows
    # Longest dependsOn chain, weighted by measured wall clock. Relaxing
    # once per task settles any acyclic graph; on a cyclic spec (which
    # g2g-evidence.sh rejects) it still terminates, just meaninglessly.
    | (reduce range(0; $rows | length) as $_ ({};
        . as $cp
        | reduce $rows[] as $r ($cp;
            .[$r.id] = $r.wall + ([$r.deps[] | $cp[.] // 0] | max // 0)))) as $cp
    | ([$rows[].wall] | add // 0) as $serial
    | ([$cp[]] | max // 0) as $critical
    | ([$rows[] | select(.dispatches > 0)] | length) as $measured
    | ($rows | map(.id | clean | length) | (max // 0) | [., 4] | max) as $w
    | "=== G2G TIMING ===",
      "spec: \($specPath | clean)",
      "range: \($range | clean)",
      ("task" | pad($w)) + "  " + ("outcome" | pad(11)) + "  dispatches  wall",
      ( $rows[]
        | (.id | clean | pad($w)) + "  " + (.outcome | pad(11)) + "  "
          + (.dispatches | tostring | pad(10)) + "  " + (.wall | dur)
          + (if .untimed > 0 then " (\(.untimed) untimed)" else "" end) ),
      "summary: tasks=\($rows | length) measured=\($measured) elapsed=\($elapsed | dur) serial=\($serial | dur) critical-path=\($critical | dur) fan-out-ceiling="
        + (if $critical > 0 then ($serial * 100 / $critical | floor) as $h
            | "\($h / 100 | floor).\($h % 100 | two)x"
          else "n/a" end),
      "=== END G2G TIMING ==="
'
