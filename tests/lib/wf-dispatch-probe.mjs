#!/usr/bin/env node
// wf-dispatch-probe.mjs — would this Workflow launch reach the loop's first
// agent dispatch?
//
// The smoke gate for /g2g:build-wf has to tell a real launch of
// plugin/workflows/g2g-build.js apart from a launch whose args make the
// script throw or return before it dispatches anything (missing arg,
// unparseable buildStart, cap already spent, every task passed or blocked,
// malformed task entries...). Re-implementing the script's checks in jq
// drifted from the JavaScript five review rounds running; this probe
// EXECUTES the shipped script instead, with the launch's args and a stub
// agent() that throws a sentinel on first use, so the answer is the
// script's own by construction.
//
// The script is run the way tests/commands.bats already models the runtime:
// the exported meta block dropped, the rest as an async function body over
// the runtime globals (args, agent, parallel, pipeline, phase). The body
// has no filesystem or shell access by runtime design and this probe hands
// it none — the stub agent is the only side channel, and it never returns.
//
//   printf '%s' '<args json>' | node wf-dispatch-probe.mjs <path/to/g2g-build.js>
//
// stdout, one line:            exit:
//   dispatch: <agent label>      0   the script called agent() — a real launch
//   no-dispatch: returned ...    1   the script returned first (nothing to do)
//   throws: <message>            2   the script threw first (rejected args)
//   probe-error: ...             3   probe misuse

import { readFileSync } from 'node:fs'

const [scriptPath] = process.argv.slice(2)
if (!scriptPath) {
  console.log('probe-error: usage: wf-dispatch-probe.mjs <workflow.js> < args.json')
  process.exit(3)
}

let args
try {
  args = JSON.parse(readFileSync(0, 'utf8'))
} catch (error) {
  console.log(`probe-error: args are not JSON: ${error.message}`)
  process.exit(3)
}

let source
try {
  source = readFileSync(scriptPath, 'utf8')
} catch (error) {
  console.log(`probe-error: cannot read ${scriptPath}: ${error.message}`)
  process.exit(3)
}

// Drop `export const meta = { ... }` — from that line through the first
// line that is exactly `}` — the same range tests/commands.bats deletes.
const lines = source.split('\n')
const metaStart = lines.findIndex(line => line.startsWith('export const meta'))
if (metaStart === -1) {
  console.log('probe-error: no `export const meta` block in the script')
  process.exit(3)
}
const metaEnd = lines.findIndex((line, index) => index > metaStart && line === '}')
if (metaEnd === -1) {
  console.log('probe-error: unterminated `export const meta` block')
  process.exit(3)
}
const body = [...lines.slice(0, metaStart), ...lines.slice(metaEnd + 1)].join('\n')

const DISPATCH = Symbol('g2g-probe-dispatch')
const agent = async (_prompt, options) => {
  throw { [DISPATCH]: true, label: options?.label ?? 'agent' }
}
const unavailable = name => () => {
  throw new Error(`${name}() reached before the first agent dispatch — not modelled by this probe`)
}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
let workflowBody
try {
  workflowBody = new AsyncFunction('args', 'agent', 'parallel', 'pipeline', 'phase', body)
} catch (error) {
  console.log(`throws: script does not compile: ${error.message}`)
  process.exit(2)
}

try {
  const result = await workflowBody(
    args, agent, unavailable('parallel'), unavailable('pipeline'), unavailable('phase'))
  const outcome = result && typeof result === 'object' && 'outcome' in result
    ? result.outcome
    : JSON.stringify(result)
  const detail = result && typeof result === 'object' && result.detail ? ` (${result.detail})` : ''
  console.log(`no-dispatch: returned ${outcome}${detail}`)
  process.exit(1)
} catch (error) {
  if (error && error[DISPATCH]) {
    console.log(`dispatch: ${error.label}`)
    process.exit(0)
  }
  console.log(`throws: ${error && error.message ? error.message : String(error)}`)
  process.exit(2)
}
