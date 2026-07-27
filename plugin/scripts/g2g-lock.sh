#!/usr/bin/env bash
# g2g-lock.sh — the sole implementation of the G2G checkout-lock protocol.
#
# Serializes /g2g:build runs in one checkout via a heartbeat lock file.
# Every creation and mutation of that file happens under a mkdir mutex,
# so no interleaving (initial create vs stale reclaim, refresh vs
# reclaim, release vs reclaim) can ever produce two owners at once, and
# a stale reclaim never exposes an unlocked absent-file window.
#
# Usage: g2g-lock.sh <command> <owner-token>
#   acquire            take the lock: create it, or reclaim stale debris
#   refresh            update the heartbeat iff the token still owns the lock
#   release-preflight  remove the owned lock only (preserves any .g2g-goal
#                      this run never armed)
#   release-terminal   remove the owned goal/lock pair
#
# Files (in the CWD, which callers make the repo root):
#   .g2g-goal        armed goal condition (written by build.md, not here;
#                    deleted here only by an owner's release-terminal or
#                    a stale reclaim)
#   .g2g-goal.lock   line 1: ISO 8601 heartbeat (informational — freshness
#                    is judged by the file's mtime, which every owner write
#                    updates; mtime needs no timezone parsing and is
#                    portable across BSD and GNU userlands)
#                    line 2: opaque single-line owner token
#   .g2g-goal.mutex/ transient mkdir mutex; held for milliseconds. It
#                    carries an owner stamp and the in-flight lock temp
#                    file, so crash recovery and the exit trap can tell
#                    their own instance from a successor's
#
# stdout: exactly one machine-readable outcome line,
#   "g2g-lock: <outcome>[ key=value ...]"
# Exit codes (stable contract — callers branch on these):
#   0  ok               acquired | reclaimed | refreshed |
#                       released-preflight | released-terminal
#   2  usage            bad command or invalid owner token
#   4  live-owner       acquire found a fresh lock held by another build
#   5  ownership-lost   refresh/release found the lock missing, foreign,
#                       or malformed; nothing was changed
#   6  mutex-stuck      mutex held past the deadline by a live-looking
#                       holder; nothing was changed — the caller must
#                       never proceed as if it held the lock
#   7  malformed-state  a lock- or goal-path shape this protocol never
#                       writes (directory, symlink); nothing was changed
#   8  operational-error filesystem failure (mutex not creatable, mtime
#                       unreadable, a mutation that failed partway);
#                       state was NOT changed except where the detail
#                       says a cleanup failed mid-way
#
# Environment overrides (TEST-ONLY — production callers use the defaults):
#   G2G_LOCK_STALE_SECONDS          heartbeat age before a lock is stale
#                                   (default 3600 = 60 min: the lock is a
#                                   per-turn heartbeat, so this only needs
#                                   to outlive the longest single turn,
#                                   never the whole build)
#   G2G_LOCK_MUTEX_STALE_SECONDS    mutex age treated as crash debris (60 —
#                                   a healthy critical section lasts
#                                   milliseconds)
#   G2G_LOCK_MUTEX_DEADLINE_SECONDS overall wait before failing closed (90)
#   G2G_LOCK_MUTEX_POLL_SECONDS     wait between mutex attempts (2)
set -euo pipefail

GOAL=".g2g-goal"
LOCK=".g2g-goal.lock"
MUTEX=".g2g-goal.mutex"

STALE_SECONDS="${G2G_LOCK_STALE_SECONDS:-3600}"
MUTEX_STALE_SECONDS="${G2G_LOCK_MUTEX_STALE_SECONDS:-60}"
MUTEX_DEADLINE_SECONDS="${G2G_LOCK_MUTEX_DEADLINE_SECONDS:-90}"
MUTEX_POLL_SECONDS="${G2G_LOCK_MUTEX_POLL_SECONDS:-2}"

usage_fail() { echo "g2g-lock: $1" >&2; exit 2; }

now_epoch() { date +%s; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

mtime_epoch() {
    # GNU stat first, then BSD (macOS). Prints nothing on failure.
    # The order is load-bearing: BSD `stat -c` fails cleanly with empty
    # stdout, but GNU `stat -f %m <file>` (-f = --file-system there)
    # PRINTS a filesystem block for the file operand while exiting
    # nonzero — running it first would prepend garbage to the fallback's
    # real answer.
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

age_seconds() {
    # Prints the age in seconds, which is NEGATIVE when the mtime is in
    # the future (a backward wall-clock step: NTP correction, VM
    # restore, suspend/resume). Prints nothing when the mtime is
    # unreadable — callers must treat those two cases differently:
    # a future mtime is a LIVE artifact, never debris.
    #
    # The numeric guard (not just non-empty) is load-bearing: if the
    # path vanishes between mtime_epoch's two stat calls and reappears
    # (another contender recreating the mutex), GNU `stat -f %m <path>`
    # — filesystem mode there — prints a multi-line block for the
    # now-existing path. Feeding that to the arithmetic below dies
    # under set -u ("File: unbound variable"), killing the caller with
    # an unclassified exit instead of a protocol code. Garbage mtime =
    # unreadable = live: never debris, never a crash.
    local mt
    mt=$(mtime_epoch "$1")
    if [[ ! "$mt" =~ ^[0-9]+$ ]]; then
        echo ""
        return 0
    fi
    echo "$(( $(now_epoch) - mt ))"
}

# The mutex directory carries an owner stamp so that stale-recovery (a
# holder paused past MUTEX_STALE_SECONDS is indistinguishable from a
# crashed one) can never make a resumed ex-holder mutate through, or
# tear down, a mutex that has since been legitimately recovered by
# someone else.
MUTEX_STAMP="$$-${RANDOM}${RANDOM}"
MUTEX_HELD=0

mutex_is_ours() {
    [[ "$(cat "$MUTEX/owner" 2>/dev/null || true)" == "$MUTEX_STAMP" ]]
}

release_mutex() {
    if [[ "$MUTEX_HELD" -eq 1 ]]; then
        MUTEX_HELD=0
        # Only dismantle a mutex we still own: after a long pause our
        # instance may have been recovered and re-created by another
        # process — removing THAT one would admit a third writer.
        if mutex_is_ours; then
            rm -f "$MUTEX/owner" "$MUTEX/lock.tmp" "$MUTEX"/lock.tmp.* 2>/dev/null || true
            rmdir "$MUTEX" 2>/dev/null || true
        fi
    fi
}
trap release_mutex EXIT

claim_mutex() {
    # Just won the mkdir: mark the instance as ours. If the stamp write
    # itself fails (errexit), the trap sees a stampless mutex it does
    # not own and leaves it — the next caller's stale recovery clears
    # it. Fail closed, never half-owned.
    MUTEX_HELD=1
    printf '%s\n' "$MUTEX_STAMP" > "$MUTEX/owner" \
        || finish 8 "operational-error detail=stamp-write-failed"
}

acquire_mutex() {
    local start age
    start=$(now_epoch)
    while true; do
        if mkdir "$MUTEX" 2>/dev/null; then
            claim_mutex
            return 0
        fi
        if [[ ! -e "$MUTEX" ]]; then
            # mkdir failed yet nothing is there: either the holder
            # released in the race window (retry succeeds) or the
            # location is unwritable (fail closed) — a second immediate
            # attempt distinguishes the two.
            if mkdir "$MUTEX" 2>/dev/null; then
                claim_mutex
                return 0
            fi
            if [[ ! -e "$MUTEX" ]]; then
                echo "g2g-lock: operational-error detail=cannot-create-mutex"
                exit 8
            fi
        fi
        age=$(age_seconds "$MUTEX")
        if [[ -n "$age" && "$age" -gt "$MUTEX_STALE_SECONDS" ]]; then
            # Crash debris: its holder died mid-mutation (a negative age
            # — future mtime after a backward clock step — is NOT
            # debris; it waits like a fresh mutex). Remove only the
            # documented children (owner stamp, temp lock writes), then
            # the emptied directory; if it holds anything else, rmdir
            # fails and we fall through to the deadline —
            # unclassifiable state fails closed, and a foreign mutex
            # never makes us proceed unlocked.
            rm -f "$MUTEX/owner" "$MUTEX/lock.tmp" "$MUTEX"/lock.tmp.* 2>/dev/null || true
            rmdir "$MUTEX" 2>/dev/null || true
            if [[ ! -e "$MUTEX" ]]; then
                continue
            fi
        fi
        if [[ "$(( $(now_epoch) - start ))" -ge "$MUTEX_DEADLINE_SECONDS" ]]; then
            echo "g2g-lock: mutex-stuck age_seconds=${age:-unknown}"
            exit 6
        fi
        sleep "$MUTEX_POLL_SECONDS"
    done
}

# The awk reads tolerate a missing file (empty result) so callers can
# branch on emptiness instead of exit codes.
lock_heartbeat() { awk 'NR==1' "$LOCK" 2>/dev/null || true; }
lock_token() { awk 'NR==2' "$LOCK" 2>/dev/null || true; }

write_lock() {
    # Caller must hold the mutex: the temp file lives inside the mutex
    # directory (named per-process so a paused writer can never move
    # another writer's content) so a crash mid-write leaves debris only
    # where mutex crash recovery already cleans, and the mv makes the
    # lock itself appear atomically — no reader ever sees a torn lock
    # file. Re-verify the mutex stamp right before the mv: if we were
    # paused long enough to be recovered, mutating now would race the
    # new holder.
    local tmp="$MUTEX/lock.tmp.$$"
    printf '%s\n%s\n' "$(iso_now)" "$TOKEN" > "$tmp" \
        || finish 8 "operational-error detail=temp-write-failed"
    if ! mutex_is_ours; then
        rm -f "$tmp" 2>/dev/null || true
        finish 8 "operational-error detail=mutex-ownership-lost-mid-write"
    fi
    mv -f "$tmp" "$LOCK" || finish 8 "operational-error detail=lock-write-failed"
}

finish() {
    # finish <exit-code> <outcome line...> — releases the mutex, prints
    # the single machine-readable outcome line, exits.
    local rc="$1"
    shift
    release_mutex
    echo "g2g-lock: $*"
    exit "$rc"
}

fail_unless_regular_lock() {
    # The protocol only ever writes a regular file at $LOCK. Anything
    # else (directory, symlink) is out-of-protocol state: never read
    # through it, never delete it — report and fail closed.
    if [[ -L "$LOCK" ]] || [[ -e "$LOCK" && ! -f "$LOCK" ]]; then
        finish 7 "malformed-state detail=lock-not-a-regular-file"
    fi
}

fail_unless_deletable_goal() {
    # Called before any path that removes $GOAL. build.md only ever
    # writes a regular file there; a directory or symlink is
    # out-of-protocol state — deleting it (or dying on `rm` mid-critical
    # -section, leaving a partial mutation and no outcome line) is worse
    # than stopping, so fail closed before touching anything.
    if [[ -L "$GOAL" ]] || [[ -e "$GOAL" && ! -f "$GOAL" ]]; then
        finish 7 "malformed-state detail=goal-not-a-regular-file"
    fi
}

cmd_acquire() {
    acquire_mutex
    fail_unless_regular_lock
    if [[ ! -e "$LOCK" ]]; then
        write_lock
        finish 0 "acquired"
    fi
    local holder heartbeat age
    holder=$(lock_token)
    heartbeat=$(lock_heartbeat)
    if [[ -n "$holder" && "$holder" == "$TOKEN" ]]; then
        # Re-acquire by the same owner (a retried preflight): idempotent —
        # refresh the heartbeat and report acquired.
        write_lock
        finish 0 "acquired"
    fi
    age=$(age_seconds "$LOCK")
    if [[ -z "$holder" ]] || [[ -n "$age" && "$age" -gt "$STALE_SECONDS" ]]; then
        # Crash debris: an empty/truncated lock, or a heartbeat past the
        # stale threshold (its build died and stopped refreshing). A
        # NEGATIVE age — future mtime after a backward wall-clock step
        # (NTP correction, VM restore) — is NOT debris: the owner may be
        # perfectly alive, so it is treated as live below. Reclaim the
        # checkout: the dead build's goal goes with its lock, and the
        # replacement lock is written before the mutex is released —
        # there is never an unlocked absent-file window for another
        # creator to slip into.
        fail_unless_deletable_goal
        rm -f "$LOCK" "$GOAL" || finish 8 "operational-error detail=reclaim-cleanup-failed"
        write_lock
        finish 0 "reclaimed stale_heartbeat=${heartbeat:-unreadable}"
    fi
    if [[ -z "$age" ]]; then
        # The lock exists but its mtime is unreadable: staleness cannot
        # be judged, so neither reclaiming nor declaring a live owner is
        # safe.
        finish 8 "operational-error detail=lock-mtime-unreadable"
    fi
    finish 4 "live-owner heartbeat=$heartbeat age_seconds=$age"
}

cmd_refresh() {
    acquire_mutex
    fail_unless_regular_lock
    if [[ ! -e "$LOCK" ]]; then
        finish 5 "ownership-lost state=missing"
    fi
    local holder
    holder=$(lock_token)
    if [[ -n "$holder" && "$holder" == "$TOKEN" ]]; then
        write_lock
        finish 0 "refreshed"
    fi
    if [[ -z "$holder" ]]; then
        finish 5 "ownership-lost state=malformed"
    fi
    finish 5 "ownership-lost state=foreign"
}

cmd_release() {
    # cmd_release <preflight|terminal> — both delete only what the token
    # still owns; a foreign or missing lock means nothing here is ours
    # to remove.
    local mode="$1" holder
    acquire_mutex
    fail_unless_regular_lock
    if [[ ! -e "$LOCK" ]]; then
        finish 5 "ownership-lost state=missing"
    fi
    holder=$(lock_token)
    if [[ -z "$holder" ]]; then
        finish 5 "ownership-lost state=malformed"
    fi
    if [[ "$holder" != "$TOKEN" ]]; then
        finish 5 "ownership-lost state=foreign"
    fi
    if [[ "$mode" == "terminal" ]]; then
        fail_unless_deletable_goal
        rm -f "$GOAL" "$LOCK" || finish 8 "operational-error detail=release-cleanup-failed"
        finish 0 "released-terminal"
    fi
    # Preflight abort: this run never armed a goal, so a pre-existing
    # .g2g-goal is not ours to delete — remove only the lock. Guarded to
    # match release-terminal: reaching here proves the dir is writable
    # (acquire_mutex fails closed otherwise), so a failing rm is only an
    # immutable-flag/TOCTOU edge — but it must classify as
    # operational-error, never an unclassified set -e exit.
    rm -f "$LOCK" || finish 8 "operational-error detail=release-cleanup-failed"
    finish 0 "released-preflight"
}

CMD="${1:-}"
TOKEN="${2:-}"

case "$CMD" in
    acquire|refresh|release-preflight|release-terminal) ;;
    *) usage_fail "usage: g2g-lock.sh <acquire|refresh|release-preflight|release-terminal> <owner-token>" ;;
esac

if [[ -z "$TOKEN" ]]; then
    usage_fail "owner token must be non-empty"
fi
case "$TOKEN" in
    *$'\n'* | *$'\r'*)
        usage_fail "owner token must be a single line"
        ;;
esac

case "$CMD" in
    acquire) cmd_acquire ;;
    refresh) cmd_refresh ;;
    release-preflight) cmd_release preflight ;;
    release-terminal) cmd_release terminal ;;
esac
