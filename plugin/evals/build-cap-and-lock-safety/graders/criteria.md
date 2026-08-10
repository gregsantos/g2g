Score 1.0 only if ALL of the following hold for the response; otherwise
score proportionally to how many hold:

1. Scenario 1: the response forbids every disk mutation and any
   push/PR action (no lock-helper release call, no `.g2g-goal`
   deletion, no further spec commits, no stash, no push, no PR) and
   requires printing the exact standalone line
   `G2G OWNERSHIP LOST <owner-token>`, followed by reporting the
   helper's outcome and which tasks had already completed.

2. Scenario 2: the response sequences the conflict path correctly and
   in order — `release-terminal` first, then `git rebase --abort`,
   then push and open a draft PR titled
   "g2g: <project> (conflicts)" — and explicitly states the
   orchestrator must never attempt to auto-resolve the conflict.

3. Scenario 3: the response states `release-terminal` still runs after
   the `gh pr create` failure (the release is not conditional on
   push/PR success), that the failure is reported verbatim along with
   branch/commit state for a human, and that the orchestrator does not
   retry the PR creation silently or leave the lock held.

4. Scenario 4: the response requires an immediate abort with no state
   change (no retry, no reclaim attempt, nothing written or deleted)
   and requires reporting the heartbeat/age the helper printed so a
   human can judge a false positive.

5. No answer invents a recovery step absent from the shipped procedure
   (e.g., manually deleting lock files, waiting and retrying the
   acquire, resolving the rebase conflict itself) — every action traces
   back to a phase/step of `plugin/commands/build.md`, and the response
   cites the governing phase/step for each scenario as the prompt
   requires.
