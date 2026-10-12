import { expect, test } from 'claude-code/testing'

type On = Parameters<Parameters<typeof test>[1]>[1]

const T1 = '/home/u/.claude/projects/-repo/s1.jsonl'
const T2 = '/home/u/.claude/projects/-repo/s2.jsonl'
const ENGINE_SECTIONS = [
  { id: 'lean_body', text: 'core', scope: 'shared' as const },
  { id: 'env_info_simple', text: 'env', scope: 'session' as const },
]

// The engine beneath the mod, with lessons.py replaced: every argv the mod
// runs is recorded; `render` answers with `state.section` and `state.pending`,
// `cli` with `state.cli`.
function engine(on: On, state: { section: string; pending: number; cli: { text: string; changed: boolean } }) {
  const runs: string[][] = []
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('session.surfaces', () => ({ value: ['terminal'] as const }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('prompt.compose', () => ({ sections: ENGINE_SECTIONS }))
  on('classic.SessionStart', () => ({}))
  on('classic.PreCompact', () => ({}))
  on('classic.SessionEnd', () => ({}))
  on('process.run', async ($, e) => {
    const args = e.argv.slice(4)
    runs.push(args)
    const verb = args[0]
    const stdout =
      verb === 'render'
        ? JSON.stringify({ section: state.section, pending: state.pending, expired: 0 })
        : verb === 'cli'
          ? JSON.stringify(state.cli)
          : ''
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  return runs
}

async function compose($: Parameters<Parameters<typeof test>[1]>[0]) {
  return $.prompt.compose({ model: 'claude-opus-5-5', promptModel: 'claude-opus-5-5', surfaces: ['terminal'], tools: [], outputStyle: null, traits: [] })
}

test('the approved section is appended last, session-scoped, keeping every engine section', async ($, on) => {
  const state = { section: '# Lessons from past sessions\n- use perl alarm\n', pending: 0, cli: { text: '', changed: false } }
  engine(on, state)
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  const { sections } = await compose($)
  expect(sections.map(s => s.id)).toEqual(['lean_body', 'env_info_simple', 'lessons:approved'])
  expect(sections[2]).toEqual({ id: 'lessons:approved', text: state.section, scope: 'session' })
})

test('no approved lessons: the system prompt is the engine\'s, unchanged', async ($, on) => {
  engine(on, { section: '', pending: 0, cli: { text: '', changed: false } })
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  expect((await compose($)).sections).toEqual(ENGINE_SECTIONS)
})

test('session start renders with the transcript\'s project key and runs the due transcripts', async ($, on) => {
  const runs = engine(on, { section: '', pending: 2, cli: { text: '', changed: false } })
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  expect(runs).toContainEqual(['render', '--project-key=-repo', '--json'])
  expect(runs).toContainEqual(['run', '--due', '--project-key=-repo'])
  const ran = await $.command.run({ command: 'lessons', args: 'list', origin: { kind: 'composer' } } as never)
  expect(runs.at(-1)).toEqual(['cli', '--project-key=-repo', '--args=list', '--json', '--typed'])
  expect(ran).toMatchObject({ text: '' })
})

// The checklist dialog (Addendum A1). Two pending lessons: L1 recommended, L2 not.
const ITEMS = [
  { id: 'L1', text: 'Re-read a file before Write.', scope: 'global', count: 2, recommended: true, check: '',
    evidence: [{ id: 'E1', user_said: 'No, re-read it first', after_action: 'Write: /r/a.md' }] },
  { id: 'L2', text: 'zsh: run setopt nomatch.', scope: 'global', count: 5, recommended: false,
    check: 'nomatch is the default that errors\u001b[8m',
    evidence: [{ id: 'E2', command: 'ls *.md', count: 3, untrusted_tool_output: ['(eval):1: no matches found\u200b'] }] },
]

function dialogEngine(on: On, surfaces: readonly 'terminal'[] = ['terminal']) {
  const runs: string[][] = []
  const toasts: string[] = []
  const opened: unknown[] = []
  const closed: string[] = []
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('session.surfaces', () => ({ value: surfaces }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.toast', ($, e) => {
    toasts.push(String(e.text))
    return { value: undefined }
  })
  on('ui.open', ($, e) => {
    opened.push(e)
    return { value: { isPlaced: true } }
  })
  on('ui.close', ($, e) => {
    closed.push(e.id)
    return { value: undefined }
  })
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('prompt.compose', () => ({ sections: ENGINE_SECTIONS }))
  on('classic.SessionStart', () => ({}))
  on('process.run', async ($, e) => {
    const args = e.argv.slice(4)
    runs.push(args)
    const stdout =
      args[0] === 'render'
        ? JSON.stringify({ section: '', pending: 2, expired: 0 })
        : args[0] === 'cli' && args.includes('--json-list')
          ? JSON.stringify({ items: ITEMS })
          : args[0] === 'review'
            ? JSON.stringify({ text: 'Approved (project): L1.', changed: true })
            : args[0] === 'notices'
              ? JSON.stringify({ notices: [{ id: 'L9', text: 'Keep the vendor folder.' }] })
              : JSON.stringify({ text: 'typed verb', changed: false })
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  return { runs, toasts, opened, closed }
}

function lessonsPane() {
  return {
    plugin: 'lessons',
    surface: 'terminal' as const,
    component: 'Pane' as const,
    requestId: 'lessons',
    props: { title: 'lessons', isFocused: true, bodyColumns: 120, placement: 'dock' as const,
      scroll: { offset: 0, bodyRows: 40 }, view: {} },
  }
}

async function startDialog($: Parameters<Parameters<typeof test>[1]>[0], on: On) {
  const seen = dialogEngine(on)
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  const ran = await $.command.run({ command: 'lessons', args: '', origin: { kind: 'composer' } } as never)
  return { ...seen, ran }
}

test('/lessons with no arguments and a screen opens the checklist dialog', async ($, on) => {
  const { ran, opened, runs } = await startDialog($, on)
  expect(ran).toMatchObject({ text: '2 pending lessons: review them in the dialog.' })
  expect(runs).toContainEqual(['cli', '--project-key=-repo', '--args=pending', '--json-list'])
  expect(opened.at(-1)).toMatchObject({ id: 'lessons', focus: true, closeOnEscape: true, holdToasts: true })
})

test('the first draw ticks exactly the recommended lessons, and shows the check for the other', async ($, on) => {
  await startDialog($, on)
  const ui = await $.ui.mount(lessonsPane())
  expect((await ui.find({ key: 't-L1' }))?.text).toContain('[x] L1')
  expect((await ui.find({ key: 't-L1' }))?.text).toContain('(Recommended)')
  expect((await ui.find({ key: 't-L2' }))?.text).toContain('[ ] L2')
  expect((await ui.find({ key: 't-L2' }))?.text).not.toContain('(Recommended)')
  expect((await ui.find({ key: 'u-L2-E2-0' }))?.text).toContain('untrusted tool output: (eval):1: no matches found?')
  expect((await ui.find({ key: 'c-L2' }))?.text).toContain('check: nomatch is the default that errors?[8m')
  expect(await ui.find({ key: 'c-L1' })).toBeUndefined()
})

test('a toggle redraws; Approve selected sends exactly the ticked ids with --typed and the scope', async ($, on) => {
  const { runs, toasts, closed } = await startDialog($, on)
  const ui = await $.ui.mount(lessonsPane())
  await ui.press({ key: 't-L2' })
  expect((await ui.find({ key: 't-L2' }))?.text).toContain('[x] L2')
  await ui.press({ key: 't-L1' })
  expect((await ui.find({ key: 't-L1' }))?.text).toContain('[ ] L1')
  await ui.select({ key: 'scope', value: 'global' })
  await ui.press({ key: 'approve' })
  expect(runs.find(r => r[0] === 'review')).toEqual(['review', '--project-key=-repo', '--approve', 'L2', '--scope=global', '--typed'])
  expect(runs.slice(-2)).toEqual([['render', '--project-key=-repo', '--json'], ['notices', '--project-key=-repo']])
  expect(toasts).toContain('Approved (project): L1.')
  expect(closed).toContain('lessons')
})

test('Reject unselected sends only the unticked ids; Keep for later sends nothing', async ($, on) => {
  const { runs, closed } = await startDialog($, on)
  const ui = await $.ui.mount(lessonsPane())
  await ui.press({ key: 'reject' })
  expect(runs.find(r => r[0] === 'review')).toEqual(['review', '--project-key=-repo', '--reject', 'L2', '--scope=project', '--typed'])
  const before = runs.length
  await ui.press({ key: 'keep' })
  expect(runs.length).toBe(before)
  expect(closed.filter(id => id === 'lessons').length).toBe(2)
})

test('/lessons with arguments, or with no screen, relays the typed verb as text', async ($, on) => {
  const { runs } = dialogEngine(on, [])
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: false })
  const ran = await $.command.run({ command: 'lessons', args: '', origin: { kind: 'composer' } } as never)
  expect(ran).toMatchObject({ text: 'typed verb' })
  expect(runs.at(-1)).toEqual(['cli', '--project-key=-repo', '--args=', '--json', '--typed'])
  // With no screen nothing reads the notices: reading them uses them up.
  expect(runs).not.toContainEqual(['notices', '--project-key=-repo'])
})

test('an auto-approved lesson shows a toast naming forget at session start', async ($, on) => {
  const { toasts, runs } = await startDialog($, on)
  expect(runs).toContainEqual(['notices', '--project-key=-repo'])
  expect(toasts).toContain('auto-approved L9 from your correction: /lessons forget L9 to undo')
})

test('/lessons relays the text and re-renders only when the approved set changed', async ($, on) => {
  const state = { section: '', pending: 1, cli: { text: 'Approved L1a2b3c (project): use perl alarm', changed: true } }
  const runs = engine(on, state)
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  state.section = '# Lessons from past sessions\n- use perl alarm\n'
  const ran = await $.command.run({ command: 'lessons', args: 'approve L1a2b3c', origin: { kind: 'composer' } } as never)
  expect(ran).toMatchObject({ text: 'Approved L1a2b3c (project): use perl alarm' })
  expect(runs.at(-3)).toEqual(['cli', '--project-key=-repo', '--args=approve L1a2b3c', '--json', '--typed'])
  expect(runs.slice(-2)).toEqual([['render', '--project-key=-repo', '--json'], ['notices', '--project-key=-repo']])
  expect((await compose($)).sections.at(-1)?.id).toBe('lessons:approved')

  state.cli = { text: '1 pending', changed: false }
  const before = runs.length
  await $.command.run({ command: 'lessons', args: 'pending', origin: { kind: 'composer' } } as never)
  expect(runs.length).toBe(before + 1)
})

test('compaction triggers a run; session end triggers a --final run on that transcript', async ($, on) => {
  const runs = engine(on, { section: '', pending: 0, cli: { text: '', changed: false } })
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await $.classic.PreCompact({ trigger: 'auto', custom_instructions: null, transcript_path: T1 })
  expect(runs.at(-1)).toEqual(['run', `--transcript=${T1}`, '--project-key=-repo'])
  await $.classic.SessionEnd({ reason: 'other', transcript_path: T1 })
  expect(runs.at(-1)).toEqual(['run', `--transcript=${T1}`, '--project-key=-repo', '--final'])
})

test('every 5th failed main-loop tool call triggers a run; subagent failures and successes do not count', async ($, on) => {
  const runs = engine(on, { section: '', pending: 0, cli: { text: '', changed: false } })
  let isError = true
  on('tool.call', () => (isError ? { result: 'boom', isError: true as const, text: 'boom' } : { result: 'ok' }))
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  const call = (agentId?: string) =>
    $.tool.call({ tool: 'Bash', input: { command: 'false' }, ...(agentId ? { agentId } : {}) } as never)
  const runsOf = () => runs.filter(r => r[0] === 'run' && r[1] === `--transcript=${T1}`).length
  for (let i = 0; i < 4; i++) await call()
  await call('sub-1')
  isError = false
  await call()
  expect(runsOf()).toBe(0)
  isError = true
  await call()
  expect(runsOf()).toBe(1)
})

test('/clear: the new transcript is used and the failure count starts over', async ($, on) => {
  const runs = engine(on, { section: '', pending: 0, cli: { text: '', changed: false } })
  on('tool.call', () => ({ result: 'boom', isError: true as const, text: 'boom' }))
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  for (let i = 0; i < 3; i++) await $.tool.call({ tool: 'Bash', input: { command: 'false' } } as never)
  await $.classic.SessionEnd({ reason: 'clear', transcript_path: T1 })
  expect(runs.at(-1)).toEqual(['run', `--transcript=${T1}`, '--project-key=-repo', '--final'])
  await $.classic.SessionStart({ source: 'clear', transcript_path: T2 })
  expect(runs.slice(-2)).toEqual([['render', '--project-key=-repo', '--json'], ['notices', '--project-key=-repo']])
  for (let i = 0; i < 4; i++) await $.tool.call({ tool: 'Bash', input: { command: 'false' } } as never)
  expect(runs.filter(r => r[0] === 'run' && r[1] === `--transcript=${T2}`).length).toBe(0)
  await $.tool.call({ tool: 'Bash', input: { command: 'false' } } as never)
  expect(runs.at(-1)).toEqual(['run', `--transcript=${T2}`, '--project-key=-repo'])
})

test('a broken render still registers /lessons, still runs the due transcripts, and leaves the system prompt alone', async ($, on) => {
  const registered: string[] = []
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('session.surfaces', () => ({ value: ['terminal'] as const }))
  on('ui.log', () => ({ value: undefined }))
  on('command.register', ($, e) => {
    registered.push(e.name)
    return { value: { command: e.name } }
  })
  on('prompt.compose', () => ({ sections: ENGINE_SECTIONS }))
  on('classic.SessionStart', () => ({}))
  const runs: string[][] = []
  on('process.run', async ($, e) => {
    runs.push(e.argv.slice(4))
    return { value: { exitCode: 0, stdout: 'Traceback (most recent call last):', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  expect(registered).toEqual(['lessons'])
  expect(runs).toContainEqual(['run', '--due', '--project-key=-repo'])
  expect((await compose($)).sections).toEqual(ENGINE_SECTIONS)
})

test('a hook that throws after the tool ran never runs the tool again', async ($, on) => {
  let ran = 0
  let logThrows = false
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('session.surfaces', () => ({ value: ['terminal'] as const }))
  // Once the session is up, a failing trigger's log throws too, so the
  // try/catch cannot absorb it and the hook's .catch(passThrough) runs.
  on('ui.log', () => {
    if (logThrows) throw new Error('log down')
    return { value: undefined }
  })
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('classic.SessionStart', () => ({}))
  on('process.run', async ($, e) => {
    if (e.argv[4] === 'run' && e.argv[5] !== '--due') throw new Error('spawn failed')
    return { value: { exitCode: 0, stdout: JSON.stringify({ section: '', pending: 0 }), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('tool.call', () => {
    ran += 1
    return { result: 'boom', isError: true as const, text: 'boom' }
  })
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  logThrows = true
  for (let i = 0; i < 5; i++) {
    const result = await $.tool.call({ tool: 'Bash', input: { command: 'false' } } as never)
    expect(result).toMatchObject({ isError: true })
  }
  expect(ran).toBe(5)
})

test('/lessons not typed by the person (a plugin, the model) never passes --typed', async ($, on) => {
  const runs = engine(on, { section: '', pending: 0, cli: { text: 'only you can run it', changed: false } })
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'lessons', args: 'approve L1a2b3c', origin: { kind: 'plugin', name: 'other' } } as never)
  expect(runs.at(-1)).toEqual(['cli', '--project-key=-repo', '--args=approve L1a2b3c', '--json'])
  await $.command.run({ command: 'lessons', args: 'approve L1a2b3c' })
  expect(runs.at(-1)).toEqual(['cli', '--project-key=-repo', '--args=approve L1a2b3c', '--json'])
})

test('/lessons not typed by the person never opens the dialog', async ($, on) => {
  const { runs, opened } = dialogEngine(on)
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  const ran = await $.command.run({ command: 'lessons', args: '', origin: { kind: 'plugin', name: 'other' } } as never)
  expect(opened).toEqual([])
  expect(ran).toMatchObject({ text: 'typed verb' })
  expect(runs.at(-1)).toEqual(['cli', '--project-key=-repo', '--args=', '--json'])
})

test('a refresh after /clear announces auto-approved lessons too', async ($, on) => {
  const { toasts, runs } = dialogEngine(on)
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  const before = runs.filter(r => r[0] === 'notices').length
  await $.classic.SessionStart({ source: 'clear', transcript_path: T2 })
  expect(runs.filter(r => r[0] === 'notices').length).toBe(before + 1)
  expect(toasts.filter(t => t.startsWith('auto-approved L9')).length).toBe(2)
})
