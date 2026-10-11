import type { EngineInterface as Dollar, Register } from 'claude-code'

// Lessons: failures and corrections that repeat in this session's transcript
// become reminders in the system prompt, but only those the person approves
// with /lessons. All the logic is in the house's scripts/lessons.py
// (docs/features/lessons-hook/PLAN.md); this module only triggers it, puts its
// `render` text into the system prompt as one section, and relays /lessons.
//
// Triggers: compaction (classic.PreCompact), session end and /clear
// (classic.SessionEnd, --final), every 5th failed tool call of the main loop,
// and the next session's start for transcripts a throttled trigger left due.
// `lessons.py run` releases its caller at once, so none of these waits on the
// model call; session end gives every hook 1.5 s.

// `plugin install` copies the mod into the plugin cache, away from the house's
// scripts, so lessons.py is found as walk finds events.py: beside the mod when
// it is read in place, else $CLAUDE_CODING_WORKFLOW, else the house's home.
const LESSONS = [
  'sh',
  '-c',
  'for d in "$0" "${CLAUDE_CODING_WORKFLOW:-$HOME/claude-coding-workflow}"; do ' +
    '[ -f "$d/scripts/lessons.py" ] && exec python3 "$d/scripts/lessons.py" "$@"; done; ' +
    'echo "lessons.py not found: set CLAUDE_CODING_WORKFLOW to the house checkout" >&2; exit 127',
]

const SECTION_ID = 'lessons:approved'
const FAILURES_PER_RUN = 5

// This session's transcript (from the classic events, which carry it), the
// project key (its folder name: Claude Code's own key), the approved section
// as last rendered, and the main loop's failed tool calls since the last
// trigger. Module state: a reload re-runs session.start, which re-renders.
let transcript: string | null = null
let projectKey: string | null = null
let section = ''
let failures = 0

function keyOf(path: string): string {
  const parts = path.split('/')
  return parts[parts.length - 2] ?? ''
}

// Claude Code's projects-folder key for a working directory, for a session
// whose classic events have not (yet) said where its transcript is.
function keyOfCwd(cwd: string): string {
  return cwd.replace(/[^A-Za-z0-9]/g, '-')
}

async function lessons($: Dollar, args: string[], timeoutMs = 5000) {
  const house = `${$.plugin.root}/../..`
  return $.process.run([...LESSONS, house, ...args], { timeoutMs })
}

async function key($: Dollar): Promise<string> {
  return projectKey ?? keyOfCwd(await $.session.cwd())
}

// Re-read the approved section and the pending count; the one place the
// system prompt's lessons change. Never throws: a broken render keeps the
// last section, so session.start still registers /lessons.
async function refresh($: Dollar): Promise<number> {
  try {
    const run = await lessons($, ['render', `--project-key=${await key($)}`, '--json'])
    if (run.exitCode !== 0) throw new Error(`render exit ${run.exitCode}`)
    const out = JSON.parse(run.stdout) as { section: unknown; pending: unknown }
    if (typeof out.section !== 'string' || typeof out.pending !== 'number') throw new Error('render: bad reply')
    section = out.section
    return out.pending
  } catch (error) {
    $.ui.log(`lessons: ${String(error)}`, { to: 'debug' })
    return 0
  }
}

async function trigger($: Dollar, path: string | null, final: boolean) {
  if (!path) return
  const args = ['run', `--transcript=${path}`, `--project-key=${keyOf(path)}`]
  const run = await lessons($, final ? [...args, '--final'] : args)
  if (run.exitCode !== 0) $.ui.log(`lessons: run exit ${run.exitCode}`, { to: 'debug' })
}

// A hook here only observes: if it throws, the event goes on unchanged.
function passThrough(_$: unknown, e: never, next: (e: never) => unknown) {
  return next(e)
}

export const register: Register = on => {
  on('classic.SessionStart', async ($, e, next) => {
    // Every start, /clear included: /clear goes on under a new session id with
    // no session.start, and its transcript is a new file.
    transcript = e.transcript_path
    projectKey = keyOf(e.transcript_path)
    failures = 0
    if (e.source === 'clear') await refresh($)
    return next(e)
  }).catch(passThrough)

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({
      name: 'lessons',
      description: 'Review lessons drawn from repeated failures: pending, list, approve ID [global], edit, reject, forget, off, on',
      argumentHint: '[pending|list|approve ID [global]|edit ID TEXT|reject ID|forget ID|off|on]',
    })
    const pending = await refresh($)
    if (pending > 0 && (await $.session.surfaces()).length > 0) {
      $.ui.toast(`${pending} lesson${pending === 1 ? '' : 's'} pending: /lessons`)
    }
    await lessons($, ['run', '--due', `--project-key=${await key($)}`])
    return started
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if (!section) return composed
    return { ...composed, sections: [...composed.sections, { id: SECTION_ID, text: section, scope: 'session' as const }] }
  }).catch(passThrough)

  on('tool.call', async ($, e, next) => {
    const result = await next(e)
    if (!e.agentId && result.isError === true) {
      failures += 1
      if (failures % FAILURES_PER_RUN === 0) {
        try {
          await trigger($, transcript, false)
        } catch (error) {
          $.ui.log(`lessons: trigger failed: ${String(error)}`, { to: 'debug' })
        }
      }
    }
    return result
  }).catch(passThrough)

  on('classic.PreCompact', async ($, e, next) => {
    await trigger($, e.transcript_path, false)
    return next(e)
  }).catch(passThrough)

  on('classic.SessionEnd', async ($, e, next) => {
    await trigger($, e.transcript_path, true)
    return next(e)
  }).catch(passThrough)

  // Only the person's own Enter (origin composer, which the engine stamps and
  // never presumes) may approve, edit, reject, forget or switch lessons off:
  // otherwise injected text could get the model to run `/lessons approve`.
  on('command.run', { command: 'lessons' }, async ($, e) => {
    const typed = e.origin?.kind === 'composer' ? ['--typed'] : []
    const run = await lessons($, ['cli', `--project-key=${await key($)}`, `--args=${e.args}`, '--json', ...typed], 15000)
    if (run.exitCode !== 0) return { text: `lessons: exit ${run.exitCode}: ${run.stderr.slice(0, 200)}` }
    let out: { text: string; changed: boolean }
    try {
      out = JSON.parse(run.stdout) as { text: string; changed: boolean }
    } catch {
      return { text: `lessons: unreadable reply: ${run.stdout.slice(0, 200)}` }
    }
    if (out.changed) await refresh($)
    return { text: out.text }
  })
}
