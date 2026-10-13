import { expect, mock, test } from 'claude-code/testing'

import { detail, paneLines } from './view'
import type { WalkGraph } from '../types'

const NO_WALKS = '[]'

// g1 done; g2 (on g1) running; g3 (on g1 and g2) waiting.
const GRAPH: WalkGraph = {
  found: true,
  dir: '/repo',
  feature: 'mailer',
  done: 1,
  total: 3,
  running: 'g2-ack',
  phase: 'review',
  round: 1,
  width: 3,
  rows: [
    { goal: 'g1-store', graph: '●', col: 0, cont: '│ │' },
    { graph: '├─╮' },
    { goal: 'g2-ack', graph: '◉ │', col: 0, cont: '│ │' },
    { goal: 'g3-retry', graph: '◌─╯', col: 0, cont: '' },
  ],
  goals: {
    'g1-store': { title: 'Persist inbound mail', state: 'done', waits: [], round: 1, phase: null, model: 'haiku', fallback: false, secs: 372, cost: 0.09 },
    'g2-ack': { title: 'Label-ack after enqueue', state: 'running', waits: [], round: 1, phase: 'review', model: 'haiku', fallback: false, secs: 668, cost: 0.17 },
    'g3-retry': { title: 'Retry failed sends', state: 'waiting', waits: ['g2-ack'], round: null, phase: null, model: null, fallback: false, secs: null, cost: null },
  },
}

type On = Parameters<Parameters<typeof test>[1]>[1]

// The engine's session start, working directory, the surfaces drawing it and
// its panes, standing beneath the mod.
function engine(on: On, surfaces: readonly ('terminal' | 'desktop')[] = ['terminal'], tools: string[] = []) {
  const panes: string[] = []
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('session.id', () => ({ value: 'S1' }))
  on('tool.list', () => ({ value: tools.map(name => ({ name })) as never }))
  on('session.surfaces', () => ({ value: surfaces }))
  on('ui.log', () => ({ value: undefined }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('ui.open', ($, e) => {
    if (!panes.includes(e.id)) panes.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.panes', () => ({
    value: panes.map(id => ({ id, title: id, isShown: true, isFocused: false, isPlaced: true })),
  }))
  return panes
}

function pane(surface: 'terminal' | 'desktop', bodyColumns: number) {
  return {
    plugin: 'walk',
    surface,
    component: 'Pane' as const,
    requestId: 'walk',
    props: {
      title: 'walk',
      isFocused: false,
      bodyColumns,
      placement: 'dock' as const,
      scroll: { offset: 0, bodyRows: 40 },
      view: {},
    },
  }
}

for (const surface of ['terminal', 'desktop'] as const) {
  test(`/walk opens the pane with the goal graph (${surface})`, async ($, on) => {
    mock.clock(on)
    const argvs: string[][] = []
    on('process.run', async ($, e) => {
      argvs.push([...e.argv])
      const stdout = e.argv.includes('graph') ? JSON.stringify(GRAPH) : NO_WALKS
      return { value: { exitCode: 0, stdout, stderr: '' } }
    })
    const panes = engine(on, [surface])
    await $.session.start({ cwd: '/repo', surface, isInteractive: true })

    const ran = await $.command.run({ command: 'walk', args: '' })
    expect(ran.text).toBe('Walk pane opened for this repo.')
    expect(panes).toEqual(['walk'])
    expect(argvs.some(a => a.includes('graph') && a.at(-1) === '/repo')).toBe(true)

    const ui = await $.ui.mount(pane(surface, 100))
    expect((await ui.find({ key: 'head' }))?.text).toBe('mailer · 1/3 done · g2-ack r1 · review')
    expect((await ui.find({ key: 'goal:g2-ack' }))?.text).toContain('◉ │ g2-ack')
    expect((await ui.find({ key: 'goal:g3-retry' }))?.text).toContain('waits g2-ack')
  })
}

test('/walk DIR reads that repo, a failed read keeps the graph and says why', async ($, on) => {
  const clock = mock.clock(on)
  let fail = false
  const dirs: string[] = []
  on('process.run', async ($, e) => {
    if (e.argv.includes('graph')) {
      dirs.push(e.argv.at(-1) ?? '')
      if (fail) return { value: { exitCode: 1, stdout: '', stderr: 'GOALS.md: bad fence' } }
      return { value: { exitCode: 0, stdout: JSON.stringify(GRAPH), stderr: '' } }
    }
    return { value: { exitCode: 0, stdout: NO_WALKS, stderr: '' } }
  })
  engine(on)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'walk', args: ' ~/other ' })
  expect(dirs.at(-1)).toBe('~/other')

  fail = true
  await clock.advance(3000)
  const ui = await $.ui.mount(pane('terminal', 100))
  expect((await ui.find({ key: 'error' }))?.text).toContain('GOALS.md: bad fence')
  expect((await ui.find({ key: 'goal:g1-store' }))?.text).toContain('g1-store')
})

test('the pane is not read while it is closed', async ($, on) => {
  const clock = mock.clock(on)
  const argvs: string[][] = []
  on('process.run', async ($, e) => {
    argvs.push([...e.argv])
    return { value: { exitCode: 0, stdout: NO_WALKS, stderr: '' } }
  })
  engine(on)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await clock.advance(6000)
  expect(argvs.some(a => a.includes('graph'))).toBe(false)
})

test('a session no surface draws never polls', async ($, on) => {
  const clock = mock.clock(on)
  let calls = 0
  on('process.run', async () => {
    calls += 1
    return { value: { exitCode: 0, stdout: NO_WALKS, stderr: '' } }
  })
  engine(on, [])
  await $.session.start({ cwd: '/repo', surface: null, isInteractive: false })
  await clock.advance(9000)
  expect(calls).toBe(0)
})

test('the poll keeps the task list for the walk this session launched', async ($, on) => {
  const clock = mock.clock(on)
  const argvs: string[][] = []
  const store = new Map<string, Record<string, unknown>>()
  let next = 1
  const WALK = { root: '/target', walk_id: 'cfcda33d-1111-4000-8000-000000000001', journal: 'docs/journal/x.md', session: 'S1', mtime: 1, live: true, started: 5 }
  on('process.run', async ($, e) => {
    argvs.push([...e.argv])
    const stdout = e.argv.includes('walks') ? JSON.stringify([WALK]) : JSON.stringify(GRAPH)
    return { value: { exitCode: 0, stdout, stderr: '' } }
  })
  on('tool.call', ($, e) => {
    const input = e as unknown as Record<string, unknown>
    if (input.tool === 'TaskList') return { result: { tasks: [...store.values()] } } as never
    if (input.tool === 'TaskCreate') {
      const id = String(next++)
      store.set(id, { id, subject: input.subject, status: 'pending', activeForm: input.activeForm })
      return { result: { task: { id, subject: input.subject } } } as never
    }
    const t = store.get(String(input.taskId))
    if (!t) return { result: { success: false }, isError: true } as never
    if (input.status === 'deleted') store.delete(String(input.taskId))
    else for (const k of ['subject', 'status', 'owner', 'activeForm']) if (input[k] !== undefined) t[k] = input[k]
    return { result: { success: true } } as never
  })
  engine(on, ['terminal'], ['TaskCreate', 'TaskUpdate', 'TaskList'])
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await clock.advance(3000)

  const walks = argvs.find(a => a.includes('walks')) ?? []
  expect(walks.slice(walks.indexOf('walks'))).toEqual(['walks', '--session', 'S1', '--json'])
  expect(argvs.some(a => a.includes('graph') && a.at(-1) === '/target')).toBe(true)
  const tasks = [...store.values()].sort((a, b) => String(a.subject).localeCompare(String(b.subject)))
  expect(tasks.map(t => t.subject)).toEqual([
    'g1-store — Persist inbound mail',
    'g2-ack — Label-ack after enqueue',
    'g3-retry — Retry failed sends',
  ])
  expect(tasks.every(t => t.owner === 'walk:cfcda33d')).toBe(true)
  expect(tasks.map(t => t.status)).toEqual(['completed', 'in_progress', 'pending'])
  expect(tasks[1].activeForm).toBe('g2-ack · review · r1')
})

test('a session without the Task tools never touches the list', async ($, on) => {
  const clock = mock.clock(on)
  let calls = 0
  on('process.run', async () => ({ value: { exitCode: 0, stdout: NO_WALKS, stderr: '' } }))
  on('tool.call', () => {
    calls += 1
    return { result: {} } as never
  })
  engine(on)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await clock.advance(9000)
  expect(calls).toBe(0)
})

// The layout alone, by the room the pane has.
const text = (lines: ReturnType<typeof paneLines>) => lines.map(l => l.parts.map(p => p.text).join('').trimEnd())

test('a wide pane puts id, title and detail on one row', () => {
  expect(text(paneLines(GRAPH, 90))).toEqual([
    'mailer · 1/3 done · g2-ack r1 · review',
    '●   g1-store  Persist inbound mail          r1 · haiku · 6m12s · $0.09',
    '├─╮',
    '◉ │ g2-ack    Label-ack after enqueue       r1 · review · haiku · 11m08s · $0.17',
    '◌─╯ g3-retry  Retry failed sends            waits g2-ack',
    '● done  ◉ running  ◐ paused  ○ ready  ◌ waiting  ✗ bounced',
  ])
})

test('a sidebar puts the running detail under its row', () => {
  expect(text(paneLines(GRAPH, 30))).toEqual([
    'mailer · 1/3 done · g2-ack r1…',
    '●   g1-store',
    '├─╮',
    '◉ │ g2-ack',
    '│ │ r1 · review · haiku',
    '│ │ 11m08s · $0.17',
    '◌─╯ g3-retry  waits g2-ack',
    '● done  ◉ running  ◐ paused',
    '○ ready  ◌ waiting  ✗ bounced',
  ])
})

test('a pane too narrow for the graph lists the goals flat', () => {
  expect(text(paneLines(GRAPH, 10)).slice(1, 4)).toEqual(['● g1-store', '◉ g2-ack', '◌ g3-retry'])
})

test('a repo with no GOALS.md says so', () => {
  expect(text(paneLines({ found: false, dir: '/tmp/x' }, 60))).toEqual(['No GOALS.md at or above /tmp/x'])
  expect(detail({ ...GRAPH.goals!['g1-store'], fallback: true, model: 'deepseek' })).toBe('r1 · deepseek* · 6m12s · $0.09')
})

test('a parallel walk counts the other running goals in the header', () => {
  expect(text(paneLines({ ...GRAPH, others: 2 }, 90))[0]).toBe('mailer · 1/3 done · g2-ack r1 · review +2')
})
