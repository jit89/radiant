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
  const ran = await $.command.run({ command: 'lessons', args: '', origin: { kind: 'composer' } } as never)
  expect(runs.at(-1)).toEqual(['cli', '--project-key=-repo', '--args=', '--json', '--typed'])
  expect(ran).toMatchObject({ text: '' })
})

test('/lessons relays the text and re-renders only when the approved set changed', async ($, on) => {
  const state = { section: '', pending: 1, cli: { text: 'Approved L1a2b3c (project): use perl alarm', changed: true } }
  const runs = engine(on, state)
  await $.classic.SessionStart({ source: 'startup', transcript_path: T1 })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  state.section = '# Lessons from past sessions\n- use perl alarm\n'
  const ran = await $.command.run({ command: 'lessons', args: 'approve L1a2b3c', origin: { kind: 'composer' } } as never)
  expect(ran).toMatchObject({ text: 'Approved L1a2b3c (project): use perl alarm' })
  expect(runs.at(-2)).toEqual(['cli', '--project-key=-repo', '--args=approve L1a2b3c', '--json', '--typed'])
  expect(runs.at(-1)).toEqual(['render', '--project-key=-repo', '--json'])
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
  expect(runs.at(-1)).toEqual(['render', '--project-key=-repo', '--json'])
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
