import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { WalkGraph, WalkView, WalkWalk } from '../types'
import { makePushPoller } from './push'
import type { AoRow } from './push'
import { chooseWalk } from './reconcile'
import { EMPTY_TASKS, makeTaskPoller } from './tasks'
import { paneLines } from './view'
import type { Tone } from './view'

// The walk this session launched, as one task per goal in the session's task
// list, kept current by a reconcile on every poll (reconcile.ts); and `/walk-status
// [dir]`, a pane with every goal of that repo's GOALS.md as a git graph (bare,
// outside a repo with one: the walk this session launched). The
// walker runs as a background shell process, not as a subagent, so this reads
// what it writes: `scripts/events.py walks` (the walks this session's ids
// launched, in any repo) and `graph` (each goal's state). The task list is
// written through the Task* tools; every task the mod owns carries the owner
// `walk:<id8>`, and no other task is touched.
const view = atom({ plugin: 'walk', key: 'view' } as const, { graph: null, error: null, dir: null, via: null } as WalkView)
const tasks = atom({ plugin: 'walk', key: 'tasks' } as const, EMPTY_TASKS)

const PANE = 'walk'
const POLL_MS = 3000
const PUSH_MS = 60000 // the always-on supervisor itself takes a turn a minute

// `plugin install` copies the mod into the plugin cache, away from the house's
// scripts, so events.py is found in the house: beside the mod when it is read
// in place (`--plugin-dir`), else $CLAUDE_CODING_WORKFLOW, else the house's
// documented home.
const EVENTS = [
  'sh',
  '-c',
  'for d in "$0" "${CLAUDE_CODING_WORKFLOW:-$HOME/claude-coding-workflow}"; do ' +
    '[ -f "$d/scripts/events.py" ] && exec python3 "$d/scripts/events.py" "$@"; done; ' +
    'echo "events.py not found: set CLAUDE_CODING_WORKFLOW to the house checkout" >&2; exit 127',
]

// The always-on state, found as events.py is (push.ts).
const AO_STATUS = [
  'sh',
  '-c',
  // No queue, no always-on: no python every minute.
  '[ -f "${CW_AO_HOME:-$HOME/.config/cw-always-on}/queue.jsonl" ] || { echo "[]"; exit 0; }; ' +
    'for d in "$0" "${CLAUDE_CODING_WORKFLOW:-$HOME/claude-coding-workflow}"; do ' +
    '[ -f "$d/scripts/cw-decide.sh" ] && exec "$d/scripts/cw-decide.sh" status --json; done; ' +
    'echo "[]"',
]

const TONES: Record<Tone, { color?: string; dimColor?: boolean; bold?: boolean }> = {
  head: { bold: true },
  line: { dimColor: true },
  id: {},
  title: {},
  detail: { dimColor: true },
  note: { color: 'warning' },
  done: { color: 'success' },
  running: { color: 'warning', bold: true },
  paused: { color: 'warning' },
  ready: { color: 'suggestion' },
  waiting: { dimColor: true },
  bounced: { color: 'error', bold: true },
}

// The running session's poll, for /walk-status to fill its pane at once.
let pollNow: (() => Promise<void>) | null = null

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const house = `${$.plugin.root}/../..`
    const events = async (args: string[], cwd: string) => {
      const run = await $.process.run([...EVENTS, house, ...args], { cwd, timeoutMs: 5000 })
      if (run.exitCode !== 0) throw new Error(`events.py exit ${run.exitCode}: ${run.stderr.slice(0, 200)}`)
      return JSON.parse(run.stdout) as unknown
    }
    // The task poll (tasks.ts), wired to `$`.
    const pollTasks = makeTaskPoller({
      toolNames: async () => (await $.tool.list()).map(t => t.name),
      sessionId: () => $.session.id(),
      getState: () => read($, tasks),
      setState: fn => update($, tasks, fn),
      events: args => events(args, house),
      call: async input => {
        const r = (await $.tool.call(input as never)) as { deny?: string; isError?: boolean; result?: unknown }
        if (r.deny) throw new Error(`${String(input.tool)} refused: ${r.deny}`)
        if (r.isError) throw new Error(`${String(input.tool)} failed`)
        return r.result
      },
      log: (line, sink) => $.ui.log(line, { to: sink }),
    })

    let inflight: Promise<void> | null = null
    const pollOnce = async () => {
      // Nothing draws a task list in a plain -p run; the desktop app hosts its
      // sessions as an SDK client (not "interactive") and still draws one.
      if ((await $.session.surfaces()).length === 0) return
      const cwd = await $.session.cwd()
      // The task poll first, so a bare /walk-status's fallback sees the walk it chose.
      await pollTasks()
      if ((await $.ui.panes()).some(pane => pane.id === PANE)) {
        const { dir } = await read($, view)
        try {
          let graph = (await events(['graph', '--json', '--dir', dir ?? cwd], cwd)) as WalkGraph
          let via: string | null = null
          // A bare /walk-status where the working folder has no GOALS.md shows the walk
          // this session launched, chosen as the task list chooses it.
          if (dir === null && !graph.found) {
            const { sessions, last } = await read($, tasks)
            const ids = [...new Set([...sessions, await $.session.id()])]
            const walks = (await events(['walks', ...ids.flatMap(s => ['--session', s]), '--json'], cwd)) as WalkWalk[]
            const root = chooseWalk(walks, [], last)?.root ?? null
            if (root) {
              graph = (await events(['graph', '--json', '--dir', root], cwd)) as WalkGraph
              via = root
            }
          }
          // A read for a repo /walk-status has since moved away from is dropped.
          await update($, view, v => (v.dir === dir ? { ...v, graph, error: null, via } : v))
        } catch (error) {
          // The pane keeps the last graph and says why it is not current.
          await update($, view, v => (v.dir === dir ? { ...v, error: String(error) } : v))
        }
      }
    }
    // One poll at a time: a tick during one is skipped, and /walk-status waits for it
    // and then reads again, so the pane it opened is filled at once.
    const poll = () =>
      (inflight ??= pollOnce()
        .catch(error => {
          $.ui.log(`walk: poll failed: ${String(error)}`, { to: 'debug' })
        })
        .finally(() => {
          inflight = null
        }))
    pollNow = async () => {
      await inflight
      await poll()
    }

    await $.command.register({
      name: 'walk-status',
      description: 'Show the goal DAG of this repo (or DIR) as a git graph, live',
      argumentHint: '[dir]',
    })
    $.clock.every(POLL_MS, () => void poll())

    // The always-on push: a new hold becomes one PushNotification while a
    // session is drawn (push.ts).
    const pushPoll = makePushPoller({
      status: async () => {
        const run = await $.process.run([...AO_STATUS, house], { cwd: house, timeoutMs: 20000 })
        if (run.exitCode !== 0) throw new Error(`cw-decide.sh exit ${run.exitCode}: ${run.stderr.slice(0, 200)}`)
        return JSON.parse(run.stdout) as AoRow[]
      },
      toolNames: async () => (await $.tool.list()).map(t => t.name),
      call: async input => {
        const r = (await $.tool.call(input as never)) as { deny?: string; isError?: boolean; result?: unknown }
        if (r.deny) throw new Error(`${String(input.tool)} refused: ${r.deny}`)
        if (r.isError) throw new Error(`${String(input.tool)} failed`)
        return r.result
      },
      log: line => $.ui.log(line, { to: 'debug' }),
    })
    let pushing = false
    $.clock.every(PUSH_MS, () => {
      if (pushing) return
      pushing = true
      void (async () => {
        if ((await $.session.surfaces()).length > 0) await pushPoll()
      })()
        .catch(error => $.ui.log(`walk: push poll failed: ${String(error)}`, { to: 'debug' }))
        .finally(() => {
          pushing = false
        })
    })
    return started
  })

  on('command.run', { command: 'walk-status' }, async ($, e) => {
    const dir = e.args.trim() || null
    await update($, view, v => ({ ...v, dir, ...(dir === v.dir ? {} : { graph: null, error: null, via: null }) }))
    await $.ui.open({ id: PANE, title: 'walk' })
    await pollNow?.()
    const { via } = await read($, view)
    return { text: `Walk pane opened for ${dir ?? (via ? `this session's walk in ${via}` : 'this repo')}.` }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const { graph, error } = await read($, view)
    if (!graph) {
      return (
        <Box flexDirection="column">
          <Text dimColor>{error ? `walk: ${error}` : 'Reading GOALS.md…'}</Text>
        </Box>
      )
    }
    return (
      <Box flexDirection="column">
        {paneLines(graph, e.props.bodyColumns, error).map(line => (
          <Box key={line.key}>
            <Text wrap="truncate-end">
              {line.parts.map(part => (
                <Text {...TONES[part.tone]}>{part.text}</Text>
              ))}
            </Text>
          </Box>
        ))}
      </Box>
    )
  })
}
