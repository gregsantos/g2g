Score 1.0 only if ALL of the following hold for the response; otherwise
score proportionally to how many hold:

1. The response is a single valid JSON object (ignoring surrounding
   whitespace) — not wrapped in prose or markdown fences.
2. It has a non-empty string `project` field.
3. `context.verificationCommands` is exactly `["bash verify.sh"]` (the
   command stated in the prompt — not invented alternatives).
4. `tasks` is a non-empty array; every task has: `id` matching T-###,
   `title`, `description`, non-empty `acceptanceCriteria` array,
   `dependsOn` array, `status` set to "pending", and `passes` set to
   false.
5. The acceptance criteria are concrete and testable (mention the exact
   expected output "greeting 1.0.0", exit code 0 for --version, exit
   code 2 and stderr usage for unknown flags, and unchanged default
   "hello" behavior).
6. No task invents scope beyond the three stated requirements.
