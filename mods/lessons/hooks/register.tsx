import { atom, read, update } from 'claude-code'
import type { EngineInterface as Dollar, Register } from 'claude-code'

import type { LessonItem, LessonsDialog } from '../types'

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
const PANE = 'lessons'

// The checklist dialog (Addendum A1): the lessons drawn when it opened, the
// ticked ids (the recommended ones at first), the scope for every approved
// lesson. In $.state so each toggle redraws the pane.
const dialog = atom({ plugin: 'lessons', key: 'dialog' } as const, {
  items: [],
  ticks: [],
  scope: 'project',
  key: '',
  status: null,
  open: [],
  busy: false,
} as LessonsDialog)

// This session's transcript (from the classic events, which carry it), the
// project key (its folder name: Claude Code's own key), the approved section
// as last rendered, and the main loop's failed tool calls since the last
// trigger. Module state: a reload re-runs session.start, which re-renders.
let transcript: string | null = null
let projectKey: string | null = null
let section = ''
let failures = 0
// Bumped each time the dialog opens: a fix still running from an earlier
// dialog leaves the new one's state alone.
let generation = 0

// Whether a finished tool call is the person's main loop failing: not a
// subagent's, and not a plugin's (`caller` is `next.origin?.plugin`, `engine`
// for the model's own call site; a `tool.call` carries no origin of its own).
// It cannot throw, so the hook's `.catch(passThrough)` never reruns the tool.
export function countsAsMine(agentId: string | undefined, caller: string | undefined, isError: unknown): boolean {
  return !agentId && (caller === undefined || caller === 'engine') && isError === true
}

function keyOf(path: string): string {
  const parts = path.split('/')
  return parts[parts.length - 2] ?? ''
}

// Claude Code's projects-folder key for a working directory, for a session
// whose classic events have not (yet) said where its transcript is.
function keyOfCwd(cwd: string): string {
  return cwd.replace(/[^A-Za-z0-9]/g, '-')
}

async function lessons($: Dollar, args: string[], timeoutMs = 5000, stdin?: string) {
  const house = `${$.plugin.root}/../..`
  return $.process.run([...LESSONS, house, ...args], stdin === undefined ? { timeoutMs } : { timeoutMs, stdin })
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
    // Whenever the section is re-read, a lesson auto-approved since the last
    // look is announced (Addendum A4.4): at session start, after /clear, and
    // after a /lessons change.
    if ((await $.session.surfaces()).length > 0) await showNotices($)
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

// Auto-approved lessons since the last look (Addendum A4.4), one toast each.
async function showNotices($: Dollar) {
  try {
    const run = await lessons($, ['notices', `--project-key=${await key($)}`])
    if (run.exitCode !== 0) return
    const out = JSON.parse(run.stdout) as { notices: { id: string; text: string }[] }
    for (const n of out.notices) {
      $.ui.toast(`auto-approved ${n.id} from your correction: /lessons forget ${n.id} to undo`)
    }
  } catch (error) {
    $.ui.log(`lessons: notices: ${String(error)}`, { to: 'debug' })
  }
}

// Characters a person cannot see as written (controls, escape sequences,
// zero-width and bidi format characters, variation selectors, tag characters)
// drawn as `?`, as lessons.py's visible() does. lessons.py filters already;
// this is the mod's own guard (Addendum A1.2), and the engine refuses a whole
// tree over one control character, which would hide every lesson.
const HIDDEN = new RegExp(
  '[\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u0600-\\u0605\\u061c\\u06dd\\u070f\\u0890\\u0891\\u08e2\\u180e' +
    '\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u206f\\ue000-\\uf8ff\\ufe00-\\ufe0f\\ufeff\\ufff9-\\ufffb' +
    '\\u{110bd}\\u{110cd}\\u{13430}-\\u{1343f}\\u{1bca0}-\\u{1bca3}\\u{1d173}-\\u{1d17a}' +
    '\\u{e0000}-\\u{e007f}\\u{e0100}-\\u{e01ef}\\u{f0000}-\\u{10ffff}\\ud800-\\udfff]',
  'gu',
)

function visible(text: unknown): string {
  return String(text ?? '').replace(HIDDEN, '?')
}

function cleanItem(item: LessonItem): LessonItem {
  return {
    id: visible(item.id),
    text: visible(item.text),
    scope: item.scope === 'project' ? 'project' : 'global',
    count: Number(item.count) || 0,
    recommended: item.recommended === true,
    check: visible(item.check),
    summary: visible(item.summary),
    sessions: Number(item.sessions) || 0,
    fix: visible(item.fix),
    evidence: (item.evidence ?? []).map(ev =>
      'command' in ev
        ? { id: visible(ev.id), command: visible(ev.command), count: Number(ev.count) || 0,
            untrusted_tool_output: (ev.untrusted_tool_output ?? []).map(visible) }
        : { id: visible(ev.id), user_said: visible(ev.user_said), after_action: visible(ev.after_action) },
    ),
  }
}

// The pending lessons as the dialog draws them, or why they could not be read.
async function readItems($: Dollar, k: string): Promise<LessonItem[] | string> {
  const run = await lessons($, ['cli', `--project-key=${k}`, '--args=pending', '--json-list'], 15000)
  try {
    if (run.exitCode !== 0) throw new Error(`exit ${run.exitCode}`)
    return (JSON.parse(run.stdout) as { items: LessonItem[] }).items.map(cleanItem)
  } catch (error) {
    return `lessons: could not read the pending lessons (${String(error)})`
  }
}

// Open the checklist with the pending lessons, the recommended ones ticked
// (the only time ticks come from `recommended`). Returns the command's answer.
async function openDialog($: Dollar): Promise<string> {
  const BUSY = 'An approve, reject or suggested fix is still running; run /lessons again in a moment.'
  if ((await read($, dialog)).busy) return BUSY
  const k = await key($)
  const items = await readItems($, k)
  if (typeof items === 'string') return items
  if (items.length === 0) return 'No pending lessons.'
  // Replaced only if no action took the flag while the list was read: a
  // running action keeps its dialog.
  let opened = false
  await update($, dialog, v => {
    if (v.busy) return v
    opened = true
    return {
      items,
      ticks: items.filter(item => item.recommended).map(item => item.id),
      scope: 'project',
      key: k,
      status: null,
      open: [],
      busy: false,
    }
  })
  if (!opened) return BUSY
  generation += 1
  await $.ui.open({ id: PANE, title: 'lessons', focus: true, closeOnEscape: true, holdToasts: true })
  return `${items.length} pending lesson${items.length === 1 ? '' : 's'}: review them in the dialog.`
}

// A button press in the dialog: approve the ticked or reject the unticked,
// with exactly the ids drawn when it opened. Only the person can press it, so
// it passes --typed (Addendum A1.5).
// Take the dialog's busy flag in one state update (test-and-set): true when
// this press got it, false when another action holds it. Every action that
// sends ids, or changes what is drawn, takes it first and frees it in finally.
async function claim($: Dollar): Promise<boolean> {
  let mine = false
  await update($, dialog, v => {
    if (v.busy) return v
    mine = true
    return { ...v, busy: true }
  })
  return mine
}

async function release($: Dollar) {
  await update($, dialog, v => ({ ...v, busy: false }))
}

// The text each id was drawn with, sent on stdin with --bind: lessons.py acts
// only on ids that still read exactly as drawn, so no race between presses or
// processes can approve, reject or rewrite words the person did not see.
function drawnTexts(d: LessonsDialog, ids: string[]): Record<string, string> {
  const texts: Record<string, string> = {}
  for (const item of d.items) if (ids.includes(item.id)) texts[item.id] = item.text
  return texts
}

async function review($: Dollar, action: 'approve' | 'reject') {
  if (!(await claim($))) return
  const gen = generation
  try {
    const d = await read($, dialog)
    const ids = d.items.map(item => item.id).filter(id => (action === 'approve') === d.ticks.includes(id))
    if (ids.length === 0) {
      await update($, dialog, v => ({ ...v, status: action === 'approve' ? 'Nothing is ticked.' : 'Every lesson is ticked.' }))
      return
    }
    const run = await lessons(
      $,
      ['review', `--project-key=${d.key}`, `--${action}`, ...ids, `--scope=${d.scope}`, '--typed', '--bind'],
      15000,
      JSON.stringify({ texts: drawnTexts(d, ids) }),
    )
    let out: { text: string; changed: boolean }
    try {
      if (run.exitCode !== 0) throw new Error(`exit ${run.exitCode}`)
      out = JSON.parse(run.stdout) as { text: string; changed: boolean }
    } catch (error) {
      await update($, dialog, v => ({ ...v, status: `lessons: ${String(error)}` }))
      return
    }
    if (out.changed) await refresh($)
    $.ui.toast(out.text)
    await $.ui.close({ id: PANE })
  } catch (error) {
    await update($, dialog, v => ({ ...v, status: `lessons: ${String(error)}` }))
  } finally {
    // A dialog opened meanwhile owns the flag now.
    if (gen === generation) await release($)
  }
}

// Use suggested fix (Addendum B2.2): the lesson's text becomes the fix and its
// check is cleared. The dialog re-reads the list and stays open, keeping the
// scope and the ticks of lessons still pending; the rewritten lesson and any
// lesson that arrived meanwhile come back unticked (B2.3). On any failure the
// lesson leaves the dialog: its draw may no longer match the store.
async function useFix($: Dollar, id: string) {
  if (!(await claim($))) return
  const gen = generation
  // A dialog reopened meanwhile is not this one: its state is left alone.
  const mine = async (fn: (v: LessonsDialog) => LessonsDialog) => {
    if (gen === generation) await update($, dialog, fn)
  }
  const drop = (why: string) =>
    mine(v => ({
      ...v,
      items: v.items.filter(item => item.id !== id),
      ticks: v.ticks.filter(t => t !== id),
      open: v.open.filter(o => o !== id),
      status: `${why}; ${id} was taken out of this dialog: run /lessons again to see it.`,
    }))
  try {
    const d = await read($, dialog)
    const item = d.items.find(i => i.id === id)
    await mine(v => ({ ...v, status: 'Applying the suggested fix…' }))
    const run = await lessons(
      $,
      ['review', `--project-key=${d.key}`, `--use-fix=${id}`, '--typed', '--bind'],
      15000,
      JSON.stringify({ texts: drawnTexts(d, [id]), fix: item?.fix ?? '' }),
    )
    let text: string
    try {
      if (run.exitCode !== 0) throw new Error(`exit ${run.exitCode}`)
      text = (JSON.parse(run.stdout) as { text: string }).text
    } catch (error) {
      await drop(`lessons: ${String(error)}`)
      return
    }
    const items = await readItems($, d.key)
    if (typeof items === 'string') {
      await drop(items)
      return
    }
    await mine(v => {
      const before = new Set(v.items.map(i => i.id))
      const still = new Set(items.map(i => i.id))
      return {
        ...v,
        items,
        // A tick is kept only if its lesson still reads the same: a lesson
        // changed elsewhere (an edit, a trim and re-add) comes back unticked.
        ticks: v.ticks.filter(t => t !== id && before.has(t) && still.has(t)
          && v.items.find(i => i.id === t)?.text === items.find(i => i.id === t)?.text),
        open: v.open.filter(o => still.has(o)),
        status: visible(text),
      }
    })
    if (items.length === 0 && gen === generation) await $.ui.close({ id: PANE })
  } catch (error) {
    await drop(`lessons: ${String(error)}`)
  } finally {
    if (gen === generation) await release($)
  }
}

async function toggleEvidence($: Dollar, id: string) {
  await update($, dialog, v => ({
    ...v,
    open: v.open.includes(id) ? v.open.filter(o => o !== id) : [...v.open, id],
  }))
}

async function toggle($: Dollar, id: string) {
  await update($, dialog, v =>
    v.busy
      ? v
      : { ...v, status: null, ticks: v.ticks.includes(id) ? v.ticks.filter(t => t !== id) : [...v.ticks, id] },
  )
}

async function setScope($: Dollar, scope: string) {
  await update($, dialog, v => (v.busy ? v : { ...v, scope: scope === 'global' ? 'global' : 'project' }))
}

async function keep($: Dollar) {
  await $.ui.close({ id: PANE })
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
      description: 'Review lessons drawn from repeated failures (a checklist with no arguments; typed: show, fix, approve, edit, reject, forget, list, recheck, auto, off, on)',
      argumentHint: '[pending|list|show ID|fix ID|approve ID [global]|edit ID TEXT|reject ID|forget ID|recheck|auto on|off|off|on]',
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
    if (countsAsMine(e.agentId, next.origin?.plugin, result.isError)) {
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
  // With no arguments and a screen, /lessons opens the checklist dialog; its
  // buttons, which only the person can press, do the approving. The typed
  // verbs stay for a session with no screen (`claude -p`) and for edit.
  on('command.run', { command: 'lessons' }, async ($, e) => {
    // Only the person's own Enter opens it: a dialog that takes the keyboard,
    // opened by the model, would catch keys meant for the prompt.
    if (e.args.trim() === '' && e.origin?.kind === 'composer' && (await $.session.surfaces()).length > 0) {
      return { text: await openDialog($) }
    }
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

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Select } = $.ui.resolve(e)
    const d = await read($, dialog)
    return (
      <Box flexDirection="column">
        <Text bold>Pending lessons</Text>
        <Text dimColor>Enter toggles a lesson · Tab moves · Esc keeps them all for later</Text>
        {d.items.map(item => (
          <Box key={`l-${item.id}`} flexDirection="column">
            <Button key={`t-${item.id}`} plain onPress={() => toggle($, item.id)}>
              {d.ticks.includes(item.id) ? '[x]' : '[ ]'} {item.id}  {item.text}
              {item.recommended ? '  (Recommended)' : ''}
            </Button>
            {item.check ? (
              <Box key={`c-${item.id}`}>
                <Text dimColor>      ✗ check: {item.check}</Text>
              </Box>
            ) : null}
            <Box key={`s-${item.id}`}>
              <Text dimColor>      {item.summary}</Text>
            </Box>
            {item.fix ? (
              <Box key={`g-${item.id}`} flexDirection="column">
                <Text>      suggested: {item.fix}</Text>
                <Button key={`f-${item.id}`} plain onPress={() => useFix($, item.id)}>      Use suggested fix</Button>
              </Box>
            ) : null}
            <Button key={`x-${item.id}`} plain dimColor onPress={() => toggleEvidence($, item.id)}>
              {'      '}evidence {d.open.includes(item.id) ? '▾' : '▸'}
            </Button>
            {d.open.includes(item.id)
              ? item.evidence.map(ev =>
                  'command' in ev ? (
                    <Box key={`e-${item.id}-${ev.id}`} flexDirection="column">
                      <Text dimColor>        ran `{ev.command}` ({ev.count}x)</Text>
                      {ev.untrusted_tool_output.map((line, i) => (
                        <Box key={`u-${item.id}-${ev.id}-${i}`}>
                          <Text dimColor>          untrusted tool output: {line}</Text>
                        </Box>
                      ))}
                    </Box>
                  ) : (
                    <Box key={`e-${item.id}-${ev.id}`}>
                      <Text dimColor>        you said "{ev.user_said}" after {ev.after_action}</Text>
                    </Box>
                  ),
                )
              : null}
          </Box>
        ))}
        <Select
          key="scope"
          label="Scope for approved lessons: "
          options={[
            { value: 'project', label: 'this project' },
            { value: 'global', label: 'every project' },
          ]}
          value={d.scope}
          onSelect={value => setScope($, value)}
        />
        <Box>
          <Button key="approve" variant="primary" onPress={() => review($, 'approve')}>Approve selected</Button>
          <Button key="reject" onPress={() => review($, 'reject')}>Reject unselected</Button>
          <Button key="keep" onPress={() => keep($)}>Keep for later</Button>
        </Box>
        {d.status ? <Text color="warning">{d.status}</Text> : null}
      </Box>
    )
  })
}
