#!/usr/bin/env node
// wf-loop-runner.mjs — drives plugin/workflows/g2g-build.js to a real
// return value under the same node:vm isolation as wf-dispatch-probe.mjs,
// but with a SCRIPTED QUEUE of agent() responses instead of a
// sentinel-throwing stub. The probe only answers "would this launch reach
// the first agent dispatch"; this answers "what does the loop actually do
// end to end" — task status, attempts, outcome — for launches (like a
// NEEDS_DECISION report) that exercise several agent() calls per turn.
//
// Isolation is identical to the probe and for the same reason: the body
// must not get Node globals, a module loader, or code generation, or a
// sloppy runner could let a script escape the sandbox and fake a result.
// The queue is the only side channel.
//
//   printf '%s' '{"args": <args json>, "queue": [<agent response>, ...]}' \
//     | node wf-loop-runner.mjs <path/to/g2g-build.js>
//
// Each queue entry is returned, in call order, to the next agent()
// invocation (its `label` is recorded alongside so a mismatch is visible
// in the trace on failure). An agent() call past the end of the queue
// throws loudly — a miscounted queue must fail the test, never stall or
// silently repeat the last entry.
//
// stdout, one JSON line on a normal return:
//   {"outcome": "returned", "result": <the script's done() object>,
//    "trace": [<label>, ...]}
// exit 0
//
// On a thrown error (bad args, exhausted queue, a script bug):
//   {"outcome": "threw", "message": <string>, "trace": [<label>, ...]}
// exit 1

import { readFileSync } from 'node:fs'
import vm from 'node:vm'

const [scriptPath] = process.argv.slice(2)
if (!scriptPath) {
  console.log(JSON.stringify({ outcome: 'usage-error', message: 'usage: wf-loop-runner.mjs <workflow.js> < input.json' }))
  process.exit(2)
}

let input
try {
  input = JSON.parse(readFileSync(0, 'utf8'))
} catch (error) {
  console.log(JSON.stringify({ outcome: 'usage-error', message: `input is not JSON: ${error.message}` }))
  process.exit(2)
}
const { args, queue } = input || {}
if (!Array.isArray(queue)) {
  console.log(JSON.stringify({ outcome: 'usage-error', message: 'input.queue must be an array' }))
  process.exit(2)
}

let source
try {
  source = readFileSync(scriptPath, 'utf8')
} catch (error) {
  console.log(JSON.stringify({ outcome: 'usage-error', message: `cannot read ${scriptPath}: ${error.message}` }))
  process.exit(2)
}

// Drop `export const meta = { ... }` — the same range tests/commands.bats
// and wf-dispatch-probe.mjs strip — so the body can be wrapped as a plain
// async function.
const lines = source.split('\n')
const metaStart = lines.findIndex(line => line.startsWith('export const meta'))
if (metaStart === -1) {
  console.log(JSON.stringify({ outcome: 'usage-error', message: 'no `export const meta` block in the script' }))
  process.exit(2)
}
const metaEnd = lines.findIndex((line, index) => index > metaStart && line === '}')
if (metaEnd === -1) {
  console.log(JSON.stringify({ outcome: 'usage-error', message: 'unterminated `export const meta` block' }))
  process.exit(2)
}
const body = [...lines.slice(0, metaStart), ...lines.slice(metaEnd + 1)].join('\n')

let cursor = 0
const trace = []
const agent = async (_prompt, options) => {
  const label = options?.label ?? 'agent'
  trace.push(label)
  if (cursor >= queue.length) {
    throw new Error(`wf-loop-runner: agent queue exhausted at call ${cursor + 1} (label: ${label}) — the queue only had ${queue.length} entries`)
  }
  return queue[cursor++]
}
const unavailable = name => () => {
  throw new Error(`${name}() called — not modelled by this runner`)
}

// A fresh context with only JavaScript intrinsics, no Node globals, no
// dynamic code generation, no module loader — exactly wf-dispatch-probe's
// sandbox, so the body cannot reach the filesystem or process by any route
// other than the scripted agent() queue.
const context = vm.createContext(Object.create(null), {
  codeGeneration: { strings: false, wasm: false },
})
const wrapped = `'use strict';\n(async (args, agent, parallel, pipeline, phase) => {\n${body}\n})`
let workflowBody
try {
  workflowBody = new vm.Script(wrapped, { filename: scriptPath }).runInContext(context)
} catch (error) {
  console.log(JSON.stringify({ outcome: 'threw', message: `script does not compile: ${error.message}`, trace }))
  process.exit(1)
}

try {
  const result = await workflowBody(
    args, agent, unavailable('parallel'), unavailable('pipeline'), unavailable('phase'))
  console.log(JSON.stringify({ outcome: 'returned', result, trace }))
  process.exit(0)
} catch (error) {
  console.log(JSON.stringify({ outcome: 'threw', message: error && error.message ? error.message : String(error), trace }))
  process.exit(1)
}
