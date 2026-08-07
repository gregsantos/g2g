#!/usr/bin/env bash
# g2g Stop hook — deterministic goal enforcement.
#
# Replaces the former prompt-type (LLM-evaluated) Stop hook. Every branch here
# is a mechanical check, so the "was a goal armed?" precondition can no longer
# be misjudged into blocking a bystander session.
#
# Reads the Stop hook payload on stdin and decides whether this session may end:
#   exit 0 with no output                     -> allow the stop
#   exit 0 with {"decision":"block",...}      -> block, with a reason
#
# UNCERTAINTY IS ASYMMETRIC, exactly as the prompt hook intended but could not
# guarantee. Uncertainty about whether THIS session armed a goal always allows
# the stop (fail open — a bystander must never be conscripted into finishing
# someone else's build). Only once arming is proven does uncertainty about
# whether the condition is MET fail closed. Every early return below is an
# arming-uncertainty case.
#
# Escape hatches never depend on the transcript: the turn and hours caps come
# from the goal file, so a build cannot wedge if transcript parsing breaks.
#
# stop_hook_active is deliberately NOT honoured as an allow signal. It exists to
# bound hooks that block unconditionally; honouring it would let any armed build
# escape after a single block. The loop is already bounded by the caps below.

set -uo pipefail

allow() { exit 0; }

# Every block reason starts with this, which is also how prior blocks by THIS
# hook are counted for escalation (see block()).
REASON_PREFIX="Condition not met:"

# After this many blocks with no progress, stop repeating the same demand and
# name the legitimate exits instead. A goal can be genuinely unreachable — spec
# deleted mid-run, a wedged build, or an operator arming one by hand — and in
# that state repeating "no evidence block" forever is useless. Claude Code caps
# consecutive blocks at 9 by default (CLAUDE_CODE_STOP_HOOK_BLOCK_CAP), so this
# has to escalate below that to be worth anything.
ESCALATE_AFTER=3

# Count prior blocks from THIS hook. `stop_hook_summary` records are written by
# the harness, not the model, so this cannot be inflated by an assistant turn
# quoting an earlier reason back — and keying on hookErrors keeps other
# plugins' Stop hooks out of the count.
count_prior_blocks() {
    if [ -z "${transcript_path:-}" ] || [ ! -r "${transcript_path:-}" ]; then echo 0; return; fi
    jq -s --arg prefix "$REASON_PREFIX" '
        [ .[] | select(.type=="system" and .subtype=="stop_hook_summary")
          | select(((.hookErrors // []) | tostring) | contains($prefix)) ] | length' \
        "$transcript_path" 2>/dev/null || echo 0
}

block() {
    local reason="$1" prior
    prior=$(count_prior_blocks)
    if [ "${prior:-0}" -ge "$ESCALATE_AFTER" ] 2>/dev/null; then
        reason="$reason

This goal has now blocked $prior stops without reaching a terminal state.
Stop retrying the same step. Either finish the build properly, or end it
deliberately:
  - Reachable but incomplete: continue the procedure in build.md — for a
    terminal stop that is Phase 5 (push, then
    \`\${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh release-terminal <owner-token>\`).
  - Unreachable (spec missing, no build in progress, goal armed by hand):
    say so plainly and delete .g2g-goal. That clears the goal and this hook
    will allow the stop."
    fi
    # jq -Rs produces a correctly escaped JSON string for arbitrary reason text.
    local reason_json
    reason_json=$(printf '%s' "$reason" | jq -Rs . 2>/dev/null) || reason_json='"G2G goal not met"'
    printf '{"decision":"block","reason":%s}\n' "$reason_json"
    exit 0
}

hook_payload=$(cat 2>/dev/null || true)

# jq is required for every check below. No build can pass /g2g:build's preflight
# without jq (g2g-evidence.sh needs it), so an armed goal cannot exist on a
# jq-less machine — absence here is an arming-uncertainty case, not a build.
command -v jq >/dev/null 2>&1 || allow

payload_field() {
    printf '%s' "$hook_payload" | jq -r --arg key "$1" '.[$key] // empty' 2>/dev/null
}

project_dir="${CLAUDE_PROJECT_DIR:-}"
[ -n "$project_dir" ] || project_dir=$(payload_field cwd)
[ -n "$project_dir" ] || project_dir=$PWD

goal_file="$project_dir/.g2g-goal"

# Tier 0 — the cheapest and most important check. Every terminal path in
# build.md deletes .g2g-goal, so its absence means either no goal was ever
# armed here or the build already reached a terminal state. This single test
# is what makes the hook free in the ~99% of sessions that are not builds.
[ -f "$goal_file" ] || allow

goal_json=$(cat "$goal_file" 2>/dev/null) || allow
printf '%s' "$goal_json" | jq -e . >/dev/null 2>&1 || allow   # legacy prose goal, or corrupt

goal_field() {
    printf '%s' "$goal_json" | jq -r --arg key "$1" '.[$key] // empty' 2>/dev/null
}

owner_token=$(goal_field ownerToken)
spec_path=$(goal_field specPath)
turn_cap=$(goal_field turnCap)
hours_cap=$(goal_field hoursCap)
build_start=$(goal_field buildStart)

[ -n "$owner_token" ] || allow

transcript_path=$(payload_field transcript_path)
if [ -z "$transcript_path" ] || [ ! -r "$transcript_path" ]; then allow; fi

# ---------------------------------------------------------------------------
# Transcript-independent escape hatches. These run before any transcript
# parsing so that a build can always end even if the transcript is unusable.
# ---------------------------------------------------------------------------

iso_to_epoch() {
    # GNU date first, then BSD/macOS.
    date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

if [ -n "$hours_cap" ] && [ -n "$build_start" ]; then
    start_epoch=$(iso_to_epoch "$build_start")
    if [ -n "$start_epoch" ]; then
        elapsed_hours=$(( ( $(date -u +%s) - start_epoch ) / 3600 ))
        # Computed here rather than read from a transcript turn line: a turn the
        # model forgot to label must not make the cap invisible.
        if [ "$elapsed_hours" -ge "$hours_cap" ] 2>/dev/null; then
            allow
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Arming check. The payload's transcript_path IS this session's transcript, so
# "did this session arm the goal?" is a search of that file — no session-id
# plumbing needed. We require the on-disk owner token to appear inside a
# tool_use INPUT, which separates armers from readers: a bystander running
# /g2g:status sees the token in a tool RESULT and in its own prose, never in a
# tool call's input. A foreign token (another build reclaimed the lock) simply
# will not match, so that case self-resolves to allow.
# ---------------------------------------------------------------------------

count_matches() { grep -c . 2>/dev/null || true; }

assistant_text() {
    jq -r 'select(.type=="assistant") | .message.content[]?
           | select(type=="object" and .type=="text") | .text' \
        "$transcript_path" 2>/dev/null
}

tool_result_text() {
    jq -r 'select(.type=="user")
           | [.message.content[]? | select(type=="object" and .type=="tool_result") | .content]
           + [.toolUseResult // empty]
           | [.. | objects | .text? // empty] + [.. | strings]
           | .[]' \
        "$transcript_path" 2>/dev/null
}

armed_here=$(jq -r --arg token "$owner_token" '
    select(.type=="assistant") | .message.content[]?
    | select(type=="object" and .type=="tool_use")
    | (.input | tostring)
    | select(contains($token))
    | "armed"' "$transcript_path" 2>/dev/null | count_matches)

[ "${armed_here:-0}" -gt 0 ] 2>/dev/null || allow

# From here on the goal is proven to be THIS session's. Uncertainty now fails
# closed: we block unless an allow condition is affirmatively demonstrated.

# Turn cap — needs the transcript's turn lines, which is why the hours cap above
# is the guaranteed backstop.
highest_turn=$(assistant_text | grep -oE 'G2G TURN [0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1)
if [ -n "${highest_turn:-}" ] && [ -n "$turn_cap" ]; then
    if [ "$highest_turn" -ge "$turn_cap" ] 2>/dev/null; then
        allow
    fi
fi

# Ownership lost — a standalone terminal marker. With a JSON goal file the token
# no longer sits inside a prose condition, so an exact whole-line match cannot
# be satisfied by the goal read-back (which prints JSON).
if assistant_text | grep -qxF "G2G OWNERSHIP LOST $owner_token"; then
    if ! printf '%s' "$goal_json" | jq -e --arg token "$owner_token" \
        '.ownerToken == $token' >/dev/null 2>&1; then
        allow
    fi
    lock_owner=$(sed -n '2p' "$project_dir/.g2g-goal.lock" 2>/dev/null)
    if [ "$lock_owner" != "$owner_token" ]; then
        allow   # lock is foreign, missing, or malformed — the reclaim is real
    fi
fi

# A release-terminal that could not complete ends the run by procedure ("leave
# the files for a human"). Without this the goal would block until the hours cap.
if tool_result_text | grep -qE 'g2g-lock: (ownership-lost|mutex-stuck|malformed-state|operational-error)'; then
    allow
fi

# ---------------------------------------------------------------------------
# Completion. Mostly redundant — successful terminal paths delete .g2g-goal —
# but required for the rare complete-then-release-failed case.
#
# Provenance is structural here, not a judgement: the evidence block must sit in
# a tool_result paired by tool_use_id to a tool_use whose command actually ran
# g2g-evidence.sh for this spec with --full. A model cannot forge a tool_result
# record, and pairing to the command defeats echoing a fake block.
# ---------------------------------------------------------------------------

# One producer (g2g-evidence.sh, T-001) computes completion semantics and
# prints exactly one graded `verdict:` line; this gate only greps for it —
# it never re-derives completion from the counts/summary line or the
# in_progress/pending/blocked substrings, so a paired --full run whose
# verification command failed can no longer coexist with a passing check.
# Two hardenings keep the single token unforgeable: pairing accepts only a
# bare invocation ENDING at --full (a compound command that merely contains
# the invocation could append its own passing line to the tool_result), and
# the paired block must carry exactly ONE verdict line — a second one means
# spec-controlled text or a chained command injected a verdict, and a
# conflicted block never satisfies the goal.
evidence_check=$(jq -rs --arg spec "$spec_path" '
    ($spec | gsub("(?<c>[\\\\^$.|?*+()\\[\\]{}])"; "\\" + .c)) as $spec_re
    | [ .[] | select(.type=="assistant") | .message.content[]?
      | select(type=="object" and .type=="tool_use")
      | select((.input.command? // "")
               | test("g2g-evidence\\.sh\\s+" + $spec_re + "\\s+--full\\s*$"))
      | .id ] as $evidence_ids
    | [ .[] | select(.type=="user") | .message.content[]?
        | select(type=="object" and .type=="tool_result")
        | select(.tool_use_id as $id | $evidence_ids | index($id))
        | [.content] | flatten
        | map(if type=="object" then (.text // "") else tostring end)
        | join("\n") ] as $blocks
    | if ($blocks | length) == 0 then "NO-EVIDENCE"
      else
        ($blocks | last | split("\n") | map(select(startswith("verdict:")))) as $verdict_lines
        | if ($verdict_lines | length) > 1 then "MULTIPLE-VERDICT-LINES:" + ($verdict_lines | join(" || "))
          elif ($verdict_lines | length) == 1
               and ($verdict_lines[0] | startswith("verdict: complete (proven)")) then "EVIDENCE-OK"
          elif ($verdict_lines | length) == 1 then "VERDICT-LINE:" + $verdict_lines[0]
          else "NO-VERDICT-LINE"
          end
      end' "$transcript_path" 2>/dev/null)

if [ "$evidence_check" != "EVIDENCE-OK" ]; then
    case "$evidence_check" in
        NO-EVIDENCE|"") block "Condition not met: no G2G EVIDENCE block from a real \`g2g-evidence.sh $spec_path --full\` run appears in this transcript." ;;
        NO-VERDICT-LINE) block "Condition not met: the latest evidence block has no verdict line (a pre-0.5.0 g2g-evidence.sh run) -- the orchestrator's next turn re-runs g2g-evidence.sh and self-heals." ;;
        MULTIPLE-VERDICT-LINES:*) block "Condition not met: the latest evidence block contains multiple verdict lines (${evidence_check#MULTIPLE-VERDICT-LINES:}) -- conflicting verdicts are treated as forged and never satisfy the goal." ;;
        VERDICT-LINE:*) block "Condition not met: ${evidence_check#VERDICT-LINE:}" ;;
        *)              block "Condition not met: evidence check returned $evidence_check." ;;
    esac
fi

# The verifier's own report must come from a real subagent dispatch after arming.
# The evidence block's verifier line is read from the spec JSON, which the
# orchestrator maintains, so completion must not be reachable by spec edits.
verifier_passed=$(jq -rs --arg token "$owner_token" '
    # Arming point is located by owner token in a tool_use input — the same
    # signal as the arming check above, so it holds whether the goal was
    # written with the Write tool or a shell redirect.
    ([ range(0; length) as $index
       | select(.[$index].type=="assistant")
       | select(any(.[$index].message.content[]?;
             type=="object" and .type=="tool_use"
             and ((.input | tostring) | contains($token))))
       | $index ] | first) as $arm_index
    | if $arm_index == null then 0
      else [ range(0; length) as $index | .[$index] as $record
             | select($index > $arm_index and $record.type=="user")
             | select($record.toolUseResult.agentType? == "g2g:g2g-verifier")
             | ($record.toolUseResult.content
                | if type=="array" then map(.text // "") | join("\n") else tostring end)
             | select(test("VERIFIER REPORT") and test("verdict:[[:space:]]*PASS"))
             | 1 ] | length
      end' "$transcript_path" 2>/dev/null)

if [ "${verifier_passed:-0}" -lt 1 ] 2>/dev/null; then
    block "Condition not met: no VERIFIER REPORT with verdict: PASS from a dispatched g2g:g2g-verifier subagent appears after the goal was armed."
fi

allow
