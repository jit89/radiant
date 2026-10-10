import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { WalkLabel, WalkView } from '../types'
import { paneLines } from './view'
import type { Tone } from './view'

// The goal a house orchestrator is running in this session's repo, as one
// label in the prompt footer: `walk g4-ack r1 · review · 3/7`; and `/walk
// [dir]`, a pane with every goal of that repo's GOALS.md as a git graph. The
// walker runs as a background shell process, not as a subagent, so this reads
// what it writes: `scripts/events.py status` and `graph` turn the event index
// and GOALS.md into the label and the graph, and say idle once the goal
// stopped or its process is gone.
const label = atom({ plugin: 'walk', key: 'label' } as const, null as WalkLabel)
const view = atom({ plugin: 'walk', key: 'view' } as const, { graph: null, error: null, dir: null } as WalkView)

const PANE = 'walk'
const POLL_MS = 3000
// A failed poll keeps the last label; this many in a row clear it, so a broken
// poller never leaves a stale goal in the footer.
const MAX_FAILURES = 5

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

// The running session's poll, for /walk to fill its pane at once.
let pollNow: (() => Promise<void>) | null = null

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const house = `${$.plugin.root}/../..`
    const events = async (args: string[], cwd: string) => {
      const run = await $.process.run([...EVENTS, house, ...args], { cwd, timeoutMs: 5000 })
      if (run.exitCode !== 0) throw new Error(`events.py exit ${run.exitCode}: ${run.stderr.slice(0, 200)}`)
      return JSON.parse(run.stdout) as Record<string, unknown>
    }

    let inflight: Promise<void> | null = null
    let failures = 0
    const pollOnce = async () => {
      // Nothing draws a footer in a plain -p run; the desktop app hosts its
      // sessions as an SDK client (not "interactive") and still draws one.
      if ((await $.session.surfaces()).length === 0) return
      const cwd = await $.session.cwd()
      if ((await $.ui.panes()).some(pane => pane.id === PANE)) {
        const { dir } = await read($, view)
        try {
          const graph = await events(['graph', '--json', '--dir', dir ?? cwd], cwd)
          // A read for a repo /walk has since moved away from is dropped.
          await update($, view, v => (v.dir === dir ? { ...v, graph: graph as WalkView['graph'], error: null } : v))
        } catch (error) {
          // The pane keeps the last graph and says why it is not current.
          await update($, view, v => (v.dir === dir ? { ...v, error: String(error) } : v))
        }
      }
      try {
        const status = await events(['status', '--json'], cwd)
        const shown: WalkLabel =
          status.running && typeof status.label === 'string' ? `walk ${status.label}` : null
        failures = 0
        if (shown !== (await read($, label))) await update($, label, () => shown)
      } catch (error) {
        // A failed poll (python missing, a GOALS.md mid-edit) keeps the last label.
        failures += 1
        $.ui.log(`walk: status poll failed (${failures}): ${String(error)}`, { to: 'debug' })
        if (failures >= MAX_FAILURES && (await read($, label)) !== null) {
          await update($, label, () => null)
        }
      }
    }
    // One poll at a time: a tick during one is skipped, and /walk waits for it
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
      name: 'walk',
      description: 'Show the goal DAG of this repo (or DIR) as a git graph, live',
      argumentHint: '[dir]',
    })
    $.clock.every(POLL_MS, () => void poll())
    return started
  })

  on('command.run', { command: 'walk' }, async ($, e) => {
    const dir = e.args.trim() || null
    await update($, view, v => ({ ...v, dir, ...(dir === v.dir ? {} : { graph: null, error: null }) }))
    await $.ui.open({ id: PANE, title: 'walk' })
    await pollNow?.()
    return { text: `Walk pane opened for ${dir ?? 'this repo'}.` }
  })

  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const text = await read($, label)
    if (!text) return next(e)
    return next({ ...e, props: { ...e.props, modes: [...e.props.modes, text] } })
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
