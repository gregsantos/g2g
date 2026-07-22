---
name: reviewing-codebase
description: Structured codebase analysis producing a tracked JSON findings backlog and a Markdown report. Used by /g2g:review and the /g2g:improve cycle; also directly when reviewing code quality, security, test coverage, or architecture.
---

# Reviewing Codebase

Perform structured codebase analysis for `/g2g:review`. Produces JSON
findings (`review-output/findings.json` — the tracked source of truth)
and a regenerated Markdown report. Fix-specs are generated from findings
by `/g2g:spec --from-findings`, following the writing-g2g-specs
skill's "Fix-specs from review findings" rules — this skill defines what
a good finding is; that one defines how findings become tasks.

## Findings JSON Schema

Each finding is an object in the `findings` array:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique identifier (e.g., "F-001") |
| `category` | string | Yes | One of: `security`, `bug`, `code-quality`, `test-coverage`, `architecture` |
| `severity` | string | Yes | One of: `critical`, `high`, `medium`, `low`, `info` |
| `file` | string | Yes | File path relative to project root |
| `line` | number | No | Line number (omit for file-level findings) |
| `title` | string | Yes | Short finding title (max 80 chars) |
| `description` | string | Yes | Detailed explanation of the issue |
| `suggestion` | string | Yes | Recommended fix or improvement |
| `effort` | string | Yes | One of: `small`, `medium`, `large` |
| `references` | string[] | No | Links to relevant docs, OWASP IDs, etc. |
| `addressed` | number\|string\|null | No | `null` (or absent — treated as null) while open; the fix PR's number once an improve cycle delivers one; `"stale-<date>"` when revalidation finds the symptom already gone. Set by improve cycles. Reviews must PRESERVE existing values, never clear or overwrite them. |

### Findings File Structure

```json
{
  "project": "Project Name",
  "reviewDate": "2026-07-20",
  "scope": {
    "target": "src/*",
    "diffBase": "",
    "focus": ["code-quality", "test-coverage", "architecture", "security"]
  },
  "summary": {
    "total": 0,
    "critical": 0,
    "high": 0,
    "medium": 0,
    "low": 0,
    "info": 0
  },
  "findings": []
}
```

## Severity Rubric

| Severity | Criteria | Examples |
|----------|----------|----------|
| **critical** | Exploitable vulnerability, data loss risk, or production-breaking bug | SQL injection, unvalidated file deletion, infinite loop in request handler |
| **high** | Security gap, likely bug, or missing critical error handling | Missing auth check, unhandled null dereference, race condition in state update |
| **medium** | Code smell, moderate risk, coverage gap in important paths | Complex function (>50 LOC), untested error paths, tight coupling between modules |
| **low** | Style issue, minor improvement, documentation gap | Inconsistent naming, missing docs on exported function, magic number |
| **info** | Observation, positive pattern, or architectural note | Well-structured module, potential future consideration, pattern to replicate |

**Severity calibration rules:**
- When uncertain between two levels, pick the lower one (avoid over-alarming)
- `critical` requires demonstrated exploitability or data-loss path
- `info` findings should highlight good patterns, not just fill space
- A finding without a clear `suggestion` should not be `high` or `critical`

## Category Analysis Techniques

### Security
- **OWASP Top 10**: Injection, broken auth, sensitive data exposure, XXE, broken access control, misconfiguration, XSS, insecure deserialization, known vulnerabilities, insufficient logging
- **Input validation**: Trace user inputs through to database/filesystem/exec calls
- **Auth/authz**: Check route protection, token validation, permission boundaries
- **Secrets**: Scan for hardcoded credentials, API keys, connection strings
- **Dependencies**: Flag known CVEs in package/lock files

### Bug
- **Error handling**: Uncaught exceptions, swallowed errors, missing cleanup paths
- **Race conditions**: Shared mutable state, async operations without proper guards
- **Type safety**: Implicit any, unchecked casts, null/undefined access patterns
- **Edge cases**: Off-by-one, empty arrays, boundary values, encoding issues
- **Resource leaks**: Unclosed connections, listeners never removed

### Test Coverage
- **Untested paths**: Error branches, edge cases, boundary conditions
- **Mock quality**: Mocks that don't match real behavior, over-mocking
- **Missing integration tests**: API routes, middleware chains, persistence
- **Assertion quality**: Tests that pass but don't verify meaningful behavior
- **Flaky patterns**: Time-dependent, order-dependent, non-deterministic tests

### Architecture
- **Coupling**: Modules with excessive cross-dependencies, god objects
- **Layering violations**: UI calling persistence directly, business logic in routes
- **Single responsibility**: Files/functions doing too many things
- **Abstraction quality**: Premature, leaky, or missing abstractions
- **Consistency**: Inconsistent patterns across similar modules

### Code Quality
- **Readability**: Deep nesting, unclear names, dead code
- **Duplication**: Verbatim logic blocks repeated instead of extracted
- **Complexity**: Functions beyond ~50 LOC, boolean-flag parameters, hidden side effects
- **Conventions**: Deviations from the repo's own documented style (CLAUDE.md)

## Anti-Patterns (Do NOT Do These)

**Vague findings:**
```json
{
  "title": "Code could be improved",
  "description": "This code has some issues",
  "suggestion": "Refactor to be better"
}
```

**False positives:**
- Flagging intentional patterns as bugs (e.g., catch-all error handlers that log and re-throw)
- Reporting missing tests for trivial getters/setters
- Flagging framework conventions as architectural violations

**Wrong severity:**
- `critical` for a style issue; `low` for an actual vulnerability; `high` for an info-level observation

**Duplicate findings:**
- Reporting the same pattern in every file instead of one finding with "affects N files"
- Multiple findings for the same root cause (report the root cause once)

## Accumulation and Deduplication Rules

When merging new analysis into an existing `findings.json`:

1. **Read existing findings first** — before analyzing, know what's already recorded
2. **Deduplicate by root cause** — if the same pattern appears in 5 files, ONE finding listing all affected files
3. **Never re-report an existing finding** — same root cause, same file ⇒ it's already in the backlog
4. **Increment ids** — continue from the highest existing id (F-015 → F-016)
5. **Preserve `addressed`** — existing findings keep their `addressed` value untouched; new findings get `addressed: null`
6. **Don't downgrade severity** — unless new information justifies it
7. **Remove false positives** — if deeper analysis shows a finding was wrong, remove it and say so in the report
8. **Recompute `summary`** — counts must equal the findings array, every write

## Tips

- **Start narrow, go wide**: one module deeply before sweeping the codebase
- **Read existing tests**: what IS tested reveals what ISN'T
- **Check git history**: recent changes are likelier to have issues than battle-tested code
- **Don't over-report**: 10 high-quality findings beat 50 low-quality ones
- **Positive findings matter**: `info` findings that highlight good patterns help the team
