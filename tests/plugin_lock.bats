#!/usr/bin/env bats

# Behavioral tests for plugin/scripts/g2g-lock.sh — these EXECUTE the
# lock helper (concurrently where the guarantee is about concurrency)
# rather than grepping prose. The exit codes and outcome lines asserted
# here are the stable contract build.md branches on.

LOCK_SH="$BATS_TEST_DIRNAME/../plugin/scripts/g2g-lock.sh"

setup() {
    cd "$BATS_TEST_TMPDIR" || return 1
    # Test-only pacing: poll fast so contention tests finish quickly.
    # Staleness thresholds keep their production defaults unless a test
    # overrides them explicitly.
    export G2G_LOCK_MUTEX_POLL_SECONDS=0.05
}

backdate() {
    # Set a path's mtime far into the past (portable BSD/GNU touch).
    touch -t 200001010000 "$1"
}

@test "lock: acquire on a clean checkout creates an owned lock" {
    run "$LOCK_SH" acquire tok-a
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: acquired" ]] || return 1
    [[ -f .g2g-goal.lock ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-a" ]] || return 1
    # First line is an ISO 8601 UTC heartbeat.
    [[ "$(awk 'NR==1' .g2g-goal.lock)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    # The mutex never outlives the call.
    [[ ! -e .g2g-goal.mutex ]] || return 1
}

@test "lock: two concurrent initial acquisitions — exactly one owner" {
    for i in 1 2 3 4 5 6 7 8; do
        # rc=0 ... || rc=$? keeps bats' inherited errexit from killing
        # the subshell before the exit code is recorded.
        ( rc=0; "$LOCK_SH" acquire "tok-$i" > "out-$i" 2>&1 || rc=$?; echo "$rc" > "rc-$i" ) &
    done
    wait
    winners=0
    winner=""
    for i in 1 2 3 4 5 6 7 8; do
        rc=$(cat "rc-$i")
        if [[ "$rc" -eq 0 ]]; then
            winners=$((winners + 1))
            winner="tok-$i"
            [[ "$(cat "out-$i")" == "g2g-lock: acquired" ]] || return 1
        else
            [[ "$rc" -eq 4 ]] || { echo "loser $i exited $rc: $(cat "out-$i")"; return 1; }
            [[ "$(cat "out-$i")" == "g2g-lock: live-owner "* ]] || return 1
        fi
    done
    [[ "$winners" -eq 1 ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "$winner" ]] || return 1
    [[ ! -e .g2g-goal.mutex ]] || return 1
}

@test "lock: a fresh live lock cannot be reclaimed or modified" {
    "$LOCK_SH" acquire tok-owner
    before=$(cat .g2g-goal.lock)

    run "$LOCK_SH" acquire tok-intruder
    [[ "$status" -eq 4 ]] || return 1
    [[ "$output" == "g2g-lock: live-owner heartbeat="*" age_seconds="* ]] || return 1
    [[ "$(cat .g2g-goal.lock)" == "$before" ]] || return 1

    run "$LOCK_SH" refresh tok-intruder
    [[ "$status" -eq 5 ]] || return 1
    [[ "$(cat .g2g-goal.lock)" == "$before" ]] || return 1
}

@test "lock: stale lock is reclaimed and takes the dead build's goal with it" {
    "$LOCK_SH" acquire tok-dead
    echo "old goal condition" > .g2g-goal
    backdate .g2g-goal.lock

    run "$LOCK_SH" acquire tok-new
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: reclaimed stale_heartbeat="* ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-new" ]] || return 1
    [[ ! -e .g2g-goal ]] || return 1
}

@test "lock: stale reclaim under contention has exactly one winner" {
    "$LOCK_SH" acquire tok-dead
    backdate .g2g-goal.lock
    for i in 1 2 3 4 5 6; do
        ( rc=0; "$LOCK_SH" acquire "tok-$i" > "out-$i" 2>&1 || rc=$?; echo "$rc" > "rc-$i" ) &
    done
    wait
    winners=0
    winner=""
    for i in 1 2 3 4 5 6; do
        rc=$(cat "rc-$i")
        if [[ "$rc" -eq 0 ]]; then
            winners=$((winners + 1))
            winner="tok-$i"
            [[ "$(cat "out-$i")" == "g2g-lock: reclaimed "* ]] || return 1
        else
            [[ "$rc" -eq 4 ]] || { echo "loser $i exited $rc: $(cat "out-$i")"; return 1; }
        fi
    done
    [[ "$winners" -eq 1 ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "$winner" ]] || return 1
}

@test "lock: no initial creator can enter during a reclaim replacement window" {
    # Simulate a reclaimer mid-critical-section: the test holds the mutex
    # while the lock file is swapped (removed, then replaced fresh by the
    # 'reclaimer'). A concurrent acquirer must wait on the mutex and then
    # honor the FRESH replacement lock — never create its own in the
    # absent-file window, never overwrite the reclaimer's.
    "$LOCK_SH" acquire tok-stale
    backdate .g2g-goal.lock

    mkdir .g2g-goal.mutex
    "$LOCK_SH" acquire tok-creator > creator-out 2>&1 &
    creator_pid=$!
    sleep 0.5   # let the creator start waiting on the held mutex

    rm .g2g-goal.lock
    [[ ! -e .g2g-goal.lock ]] || return 1  # the absent-file window is open right now
    sleep 0.5                    # creator keeps polling; must not create
    [[ ! -e .g2g-goal.lock ]] || { echo "creator slipped into the window"; return 1; }
    printf '%s\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "tok-reclaimer" > .g2g-goal.lock
    rmdir .g2g-goal.mutex

    creator_rc=0
    wait "$creator_pid" || creator_rc=$?
    [[ "$creator_rc" -eq 4 ]] || { echo "creator exited $creator_rc: $(cat creator-out)"; return 1; }
    [[ "$(cat creator-out)" == "g2g-lock: live-owner "* ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-reclaimer" ]] || return 1
}

@test "lock: owner refresh updates the heartbeat and preserves the token" {
    "$LOCK_SH" acquire tok-a
    backdate .g2g-goal.lock
    old_heartbeat=$(awk 'NR==1' .g2g-goal.lock)
    sleep 1.1   # the ISO heartbeat is second-granular; guarantee it advances

    run "$LOCK_SH" refresh tok-a
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: refreshed" ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-a" ]] || return 1
    [[ "$(awk 'NR==1' .g2g-goal.lock)" != "$old_heartbeat" ]] || return 1

    # The refresh must reset staleness: an immediate foreign acquire
    # sees a live lock again.
    run "$LOCK_SH" acquire tok-b
    [[ "$status" -eq 4 ]] || return 1
}

@test "lock: foreign-token refresh returns ownership-lost and changes nothing" {
    "$LOCK_SH" acquire tok-owner
    before=$(cat .g2g-goal.lock)
    run "$LOCK_SH" refresh tok-foreign
    [[ "$status" -eq 5 ]] || return 1
    [[ "$output" == "g2g-lock: ownership-lost state=foreign" ]] || return 1
    [[ "$(cat .g2g-goal.lock)" == "$before" ]] || return 1
}

@test "lock: missing-lock refresh returns ownership-lost and creates nothing" {
    run "$LOCK_SH" refresh tok-a
    [[ "$status" -eq 5 ]] || return 1
    [[ "$output" == "g2g-lock: ownership-lost state=missing" ]] || return 1
    [[ ! -e .g2g-goal.lock ]] || return 1
}

@test "lock: owner terminal release removes the goal and lock" {
    "$LOCK_SH" acquire tok-a
    echo "goal condition" > .g2g-goal
    run "$LOCK_SH" release-terminal tok-a
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: released-terminal" ]] || return 1
    [[ ! -e .g2g-goal ]] || return 1
    [[ ! -e .g2g-goal.lock ]] || return 1
    [[ ! -e .g2g-goal.mutex ]] || return 1
}

@test "lock: foreign release removes nothing" {
    "$LOCK_SH" acquire tok-owner
    echo "goal condition" > .g2g-goal
    for mode in release-terminal release-preflight; do
        run "$LOCK_SH" "$mode" tok-foreign
        [[ "$status" -eq 5 ]] || return 1
        [[ "$output" == "g2g-lock: ownership-lost state=foreign" ]] || return 1
        [[ -f .g2g-goal ]] || return 1
        [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-owner" ]] || return 1
    done
}

@test "lock: preflight release removes only the owned lock, preserves a pre-existing goal" {
    # A goal left by an older aborted run predates this acquisition; a
    # preflight abort never armed one, so it must survive.
    echo "pre-existing goal" > .g2g-goal
    "$LOCK_SH" acquire tok-a
    run "$LOCK_SH" release-preflight tok-a
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: released-preflight" ]] || return 1
    [[ ! -e .g2g-goal.lock ]] || return 1
    [[ "$(cat .g2g-goal)" == "pre-existing goal" ]] || return 1
}

@test "lock: fresh mutex contention fails closed at the deadline" {
    mkdir .g2g-goal.mutex   # a live-looking holder that never releases
    run env G2G_LOCK_MUTEX_DEADLINE_SECONDS=1 "$LOCK_SH" acquire tok-a
    [[ "$status" -eq 6 ]] || return 1
    [[ "$output" == "g2g-lock: mutex-stuck age_seconds="* ]] || return 1
    [[ ! -e .g2g-goal.lock ]] || return 1  # never proceeded unlocked
    [[ -d .g2g-goal.mutex ]] || return 1  # the foreign mutex was not stolen
}

@test "lock: stale mutex debris is recovered" {
    mkdir .g2g-goal.mutex
    echo "999-12345" > .g2g-goal.mutex/owner   # dead holder's stamp
    touch .g2g-goal.mutex/lock.tmp.999         # its in-flight write
    touch .g2g-goal.mutex/lock.tmp             # pre-stamp-era temp naming
    backdate .g2g-goal.mutex
    run "$LOCK_SH" acquire tok-a
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: acquired" ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-a" ]] || return 1
    [[ ! -e .g2g-goal.mutex ]] || return 1
}

@test "lock: a future-dated heartbeat (backward clock step) is live, never reclaimed" {
    # A wall clock that stepped backward (NTP correction, VM restore)
    # makes a live lock's mtime sit in the future. Negative age must
    # read as live — reclaiming here would create two owners.
    "$LOCK_SH" acquire tok-live
    touch -t 203001010000 .g2g-goal.lock
    run "$LOCK_SH" acquire tok-intruder
    [[ "$status" -eq 4 ]] || return 1
    [[ "$output" == "g2g-lock: live-owner "* ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-live" ]] || return 1
}

@test "lock: out-of-protocol goal shapes fail closed before any deletion" {
    # An errexit death halfway through `rm lock goal` would leave a
    # partial mutation and no outcome line; the shape check must fire
    # first and change nothing.
    "$LOCK_SH" acquire tok-a
    mkdir .g2g-goal
    run "$LOCK_SH" release-terminal tok-a
    [[ "$status" -eq 7 ]] || return 1
    [[ "$output" == "g2g-lock: malformed-state detail=goal-not-a-regular-file" ]] || return 1
    [[ -f .g2g-goal.lock ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-a" ]] || return 1
    [[ -d .g2g-goal ]] || return 1
    # Same guard on the reclaim path.
    backdate .g2g-goal.lock
    run "$LOCK_SH" acquire tok-b
    [[ "$status" -eq 7 ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-a" ]] || return 1
    [[ -d .g2g-goal ]] || return 1
}

@test "lock: unwritable checkout is an operational error, not a hang" {
    mkdir unwritable
    chmod 500 unwritable
    cd unwritable || return 1
    run "$LOCK_SH" acquire tok-a
    cd .. || return 1
    chmod 755 unwritable
    [[ "$status" -eq 8 ]] || return 1
    [[ "$output" == "g2g-lock: operational-error detail=cannot-create-mutex" ]] || return 1
    [[ ! -e unwritable/.g2g-goal.lock ]] || return 1
}

@test "lock: releasing never dismantles a successor's mutex instance" {
    # Simulate the pause-past-recovery scenario: a foreign mutex
    # instance (different owner stamp) occupies the name while our
    # helper's exit path runs. The helper must leave it standing — an
    # owner-stampless rmdir would admit a third writer. Exercised via
    # the deadline path, whose exit also runs the release trap.
    mkdir .g2g-goal.mutex
    echo "foreign-stamp" > .g2g-goal.mutex/owner
    run env G2G_LOCK_MUTEX_DEADLINE_SECONDS=1 "$LOCK_SH" acquire tok-a
    [[ "$status" -eq 6 ]] || return 1
    [[ -d .g2g-goal.mutex ]] || return 1
    [[ "$(cat .g2g-goal.mutex/owner)" == "foreign-stamp" ]] || return 1
}

@test "lock: stale mutex with unknown contents stays fail-closed" {
    mkdir .g2g-goal.mutex
    touch .g2g-goal.mutex/not-ours   # unclassifiable — never delete it
    backdate .g2g-goal.mutex
    run env G2G_LOCK_MUTEX_DEADLINE_SECONDS=1 "$LOCK_SH" acquire tok-a
    [[ "$status" -eq 6 ]] || return 1
    [[ -f .g2g-goal.mutex/not-ours ]] || return 1
    [[ ! -e .g2g-goal.lock ]] || return 1
}

@test "lock: empty lock file is crash debris — reclaimed" {
    : > .g2g-goal.lock
    run "$LOCK_SH" acquire tok-a
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: reclaimed stale_heartbeat=unreadable" ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-a" ]] || return 1
}

@test "lock: malformed lock (empty token line) is never refreshed or released through" {
    : > .g2g-goal.lock
    run "$LOCK_SH" refresh tok-a
    [[ "$status" -eq 5 ]] || return 1
    [[ "$output" == "g2g-lock: ownership-lost state=malformed" ]] || return 1
    run "$LOCK_SH" release-terminal tok-a
    [[ "$status" -eq 5 ]] || return 1
    [[ -e .g2g-goal.lock ]] || return 1
}

@test "lock: out-of-protocol lock shapes fail closed untouched" {
    mkdir .g2g-goal.lock   # a directory where the protocol writes a file
    for cmd in acquire refresh release-preflight release-terminal; do
        run "$LOCK_SH" "$cmd" tok-a
        [[ "$status" -eq 7 ]] || return 1
        [[ "$output" == "g2g-lock: malformed-state detail=lock-not-a-regular-file" ]] || return 1
        [[ -d .g2g-goal.lock ]] || return 1
    done
}

@test "lock: usage errors are exit 2 and change nothing" {
    run "$LOCK_SH" frobnicate tok-a
    [[ "$status" -eq 2 ]] || return 1
    run "$LOCK_SH" acquire
    [[ "$status" -eq 2 ]] || return 1
    run "$LOCK_SH" acquire ""
    [[ "$status" -eq 2 ]] || return 1
    run "$LOCK_SH" acquire "$(printf 'two\nlines')"
    [[ "$status" -eq 2 ]] || return 1
    [[ ! -e .g2g-goal.lock ]] || return 1
    [[ ! -e .g2g-goal.mutex ]] || return 1
}

@test "lock: re-acquire by the same owner is idempotent" {
    "$LOCK_SH" acquire tok-a
    run "$LOCK_SH" acquire tok-a
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: acquired" ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-a" ]] || return 1
}

@test "lock: acquire from a repository subdirectory finds the root's live lock (F-064)" {
    # The paths must anchor to the enclosing worktree root, not the
    # process CWD: a live lock at the root must be visible — and never
    # duplicated — from a subdirectory.
    git init -q .
    "$LOCK_SH" acquire tok-root
    mkdir -p sub/dir
    cd sub/dir || return 1
    run "$LOCK_SH" acquire tok-intruder
    subdir_lock_created=0
    [[ -e .g2g-goal.lock ]] && subdir_lock_created=1
    cd ../.. || return 1
    [[ "$status" -eq 4 ]] || return 1
    [[ "$output" == "g2g-lock: live-owner "* ]] || return 1
    [[ "$subdir_lock_created" -eq 0 ]] || { echo "a second lock was created in the subdirectory"; return 1; }
    [[ -f .g2g-goal.lock ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-root" ]] || return 1
}

@test "lock: two worktrees of the same repository acquire independently" {
    # Worktree isolation must be preserved: the anchor is `git rev-parse
    # --show-toplevel`, which reports the WORKTREE root, never the shared
    # .git common dir — so each worktree's lock is its own.
    root_dir="$PWD"
    wt2_dir="$BATS_TEST_TMPDIR/wt2"
    git init -q .
    git -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init
    git worktree add -q "$wt2_dir" -b wt2-branch >/dev/null

    run "$LOCK_SH" acquire tok-main
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: acquired" ]] || return 1

    cd "$wt2_dir" || return 1
    run "$LOCK_SH" acquire tok-wt2
    cd "$root_dir" || return 1
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: acquired" ]] || return 1

    [[ -f .g2g-goal.lock ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-main" ]] || return 1
    [[ -f "$wt2_dir/.g2g-goal.lock" ]] || return 1
    [[ "$(awk 'NR==2' "$wt2_dir/.g2g-goal.lock")" == "tok-wt2" ]] || return 1
}

@test "lock: with no enclosing repository, acquire still creates the lock in the CWD" {
    run git rev-parse --show-toplevel
    [[ "$status" -ne 0 ]] || return 1   # confirms the harness assumption this test relies on

    run "$LOCK_SH" acquire tok-a
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: acquired" ]] || return 1
    [[ -f .g2g-goal.lock ]] || return 1
    [[ "$(awk 'NR==2' .g2g-goal.lock)" == "tok-a" ]] || return 1
}

@test "lock: stale threshold is env-tunable for tests, default production-safe" {
    # With a tiny threshold, a just-written lock goes stale in seconds —
    # proving the knob works without waiting an hour.
    "$LOCK_SH" acquire tok-old
    sleep 2
    run env G2G_LOCK_STALE_SECONDS=1 "$LOCK_SH" acquire tok-new
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "g2g-lock: reclaimed stale_heartbeat="* ]] || return 1
    # And the production default (3600) treats the same 2-second-old
    # lock as live.
    "$LOCK_SH" release-terminal tok-new
    "$LOCK_SH" acquire tok-old2
    sleep 2
    run "$LOCK_SH" acquire tok-new2
    [[ "$status" -eq 4 ]] || return 1
}
