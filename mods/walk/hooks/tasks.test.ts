import { expect, test } from 'claude-code/testing'

import type { WalkGoal, WalkGraph, WalkTasks, WalkWalk } from '../types'
import { chooseWalk, desiredFor, ownerOf } from './reconcile'
import { SCENARIOS } from './fixtures'
import type { FixtureStep } from './fixtures'
import { EMPTY_TASKS, makeTaskPoller } from './tasks'

// The task poll driven end to end with fakes: a task list that behaves as the
// engine's (TaskCreate needs a description, TaskList omits activeForm, a list
// whose tasks are all completed clears itself), walk files, and graphs.
// docs/features/walk-tasks/VERIFICATION.md items 1 and 2.

type T = { id: string; subject: string; status: 'pending' | 'in_progress' | 'completed'; owner?: string; activeForm?: string }
type Goal = Pick<WalkGoal, 'state'> & Partial<WalkGoal>

class World {
  tasks = new Map<string, T>()
  next = 1
  walks: WalkWalk[] = []
  graphs = new Map<string, WalkGraph | 'fail'>()
  session = 'S1'
  state: WalkTasks = structuredClone(EMPTY_TASKS)
  calls: Record<string, unknown>[] = []
  /** Fail the next n calls matching the predicate. */
  failing: { n: number; when: (input: Record<string, unknown>) => boolean } | null = null
  /** Answer the next n matching TaskUpdates with `success: false` (a refusal). */
  refusing: { n: number; when: (input: Record<string, unknown>) => boolean } | null = null
  toolListCalls = 0
  walksFail = false
  toolNames = ['TaskCreate', 'TaskUpdate', 'TaskList', 'TaskGet']
  logs: [string, string][] = []
  poll = this.newPoller()

  newPoller() {
    return makeTaskPoller({
      toolNames: async () => {
        this.toolListCalls += 1
        return this.toolNames
      },
      sessionId: async () => this.session,
      getState: async () => structuredClone(this.state),
      setState: async fn => {
        this.state = fn(structuredClone(this.state))
      },
      events: async args => {
        if (args[0] === 'walks') {
          if (this.walksFail) throw new Error('events.py exit 1')
          const ids = args.filter((_, i) => args[i - 1] === '--session')
          return this.walks.filter(w => ids.includes(w.session)).map(w => ({ ...w }))
        }
        const g = this.graphs.get(args[args.indexOf('--dir') + 1])
        if (!g || g === 'fail') throw new Error('events.py exit 1: GOALS.md: bad fence')
        return structuredClone(g)
      },
      call: async input => {
        this.calls.push(input)
        if (this.failing && this.failing.n > 0 && this.failing.when(input)) {
          this.failing.n -= 1
          throw new Error(`${String(input.tool)} failed`)
        }
        if (this.refusing && this.refusing.n > 0 && this.refusing.when(input)) {
          this.refusing.n -= 1
          return { success: false, error: 'refused' }
        }
        return this.tool(input)
      },
      log: (line, sink) => {
        this.logs.push([sink, line])
      },
    })
  }

  tool(input: Record<string, unknown>) {
    if (input.tool === 'TaskList') {
      return { tasks: [...this.tasks.values()].map(({ activeForm: _a, ...t }) => ({ ...t, blockedBy: [] })) }
    }
    if (input.tool === 'TaskCreate') {
      if (!input.description) throw new Error('description required')
      const id = String(this.next++)
      this.tasks.set(id, { id, subject: String(input.subject), status: 'pending', activeForm: input.activeForm as string | undefined })
      return { task: { id, subject: input.subject } }
    }
    if (input.tool === 'TaskUpdate') {
      const t = this.tasks.get(String(input.taskId))
      if (!t) throw new Error('no such task')
      if (input.status === 'deleted') {
        this.tasks.delete(t.id)
        return { success: true }
      }
      for (const k of ['subject', 'status', 'owner', 'activeForm'] as const) if (input[k] !== undefined) (t as Record<string, unknown>)[k] = input[k]
      return { success: true }
    }
    throw new Error(`unknown tool ${String(input.tool)}`)
  }

  /** The engine: a list whose tasks are all completed clears itself. */
  engineClear() {
    const all = [...this.tasks.values()]
    if (all.length > 0 && all.every(t => t.status === 'completed')) this.tasks.clear()
  }

  async tick() {
    this.calls = []
    await this.poll()
    this.engineClear()
  }

  restart() {
    this.state = structuredClone(EMPTY_TASKS)
    this.poll = this.newPoller()
  }

  addWalk(id: string, root: string, opts: Partial<WalkWalk> = {}) {
    const w: WalkWalk = { root, walk_id: id, journal: 'docs/journal/x.md', session: this.session, mtime: 1000, live: false, started: null, ...opts }
    this.walks = [...this.walks.filter(x => x.walk_id !== id), w]
    return w
  }

  setGraph(root: string, goals: Record<string, Goal>) {
    const out: Record<string, WalkGoal> = {}
    for (const [id, g] of Object.entries(goals)) {
      out[id] = { title: `title of ${id}`, waits: [], round: null, phase: null, model: null, fallback: false, secs: null, cost: null, reason: null, ...g }
    }
    this.graphs.set(root, { found: true, dir: root, goals: out })
  }

  owned(walkId: string) {
    return [...this.tasks.values()].filter(t => t.owner === ownerOf(walkId))
  }

  subjects(walkId: string) {
    return this.owned(walkId).map(t => t.subject).sort()
  }

  count(tool: string) {
    return this.calls.filter(c => c.tool === tool).length
  }
}

const A = 'aaaaaaaa-1111-4000-8000-000000000001'
const B = 'bbbbbbbb-2222-4000-8000-000000000002'
const C = 'cccccccc-3333-4000-8000-000000000003'
const ready = (n: number): Record<string, Goal> => Object.fromEntries(Array.from({ length: n }, (_, i) => [`g${i + 1}`, { state: 'ready' }]))

// --- the graph → tasks mapping -------------------------------------------

test('each goal state maps to its task', () => {
  const graph: WalkGraph = {
    found: true,
    dir: '/r',
    goals: {
      g1: { title: 'one', state: 'done', waits: [], round: 0, phase: null, model: null, fallback: false, secs: null, cost: null },
      g2: { title: 'two', state: 'running', waits: [], round: 1, phase: 'review', model: null, fallback: false, secs: null, cost: null },
      g3: { title: 'three', state: 'running', waits: [], round: null, phase: 'start', model: null, fallback: false, secs: null, cost: null },
      g4: { title: 'four', state: 'paused', waits: [], round: 0, phase: null, model: null, fallback: false, secs: null, cost: null, reason: 'proof-red' },
      g5: { title: 'five', state: 'bounced', waits: [], round: 2, phase: null, model: null, fallback: false, secs: null, cost: null, reason: 'max-fix-rounds' },
      g6: { title: 'six', state: 'waiting', waits: ['g5'], round: null, phase: null, model: null, fallback: false, secs: null, cost: null },
      g7: { title: 'seven', state: 'paused', waits: [], round: null, phase: null, model: null, fallback: false, secs: null, cost: null, reason: null },
    },
  }
  expect(desiredFor(graph).map(d => [d.subject, d.status, d.activeForm])).toEqual([
    ['g1 — one', 'completed', null],
    ['g2 — two', 'in_progress', 'g2 · review · r1'],
    ['g3 — three', 'in_progress', 'g3 · start'],
    ['g4 — PAUSED: proof-red', 'in_progress', 'g4 PAUSED: proof-red'],
    ['g5 — BOUNCED: max-fix-rounds', 'pending', null],
    ['g6 — six', 'pending', null],
    ['g7 — PAUSED: stopped', 'in_progress', 'g7 PAUSED: stopped'],
  ])
})

// --- creating, updating, adopting ----------------------------------------

test('a walk gets one owned task per goal, with a description, then only diffs', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', { g1: { state: 'running', phase: 'implement', round: 0 }, g2: { state: 'waiting' } })
  await w.tick()
  expect(w.subjects(A)).toEqual(['g1 — title of g1', 'g2 — title of g2'])
  expect(w.owned(A).find(t => t.subject.startsWith('g1'))?.status).toBe('in_progress')
  expect(w.owned(A).find(t => t.subject.startsWith('g1'))?.activeForm).toBe('g1 · implement · r0')
  await w.tick()
  expect(w.calls.map(c => c.tool)).toEqual(['TaskList']) // steady state: one read, no writes
  w.setGraph('/a', { g1: { state: 'running', phase: 'review', round: 0 }, g2: { state: 'waiting' } })
  await w.tick()
  expect(w.calls.filter(c => c.tool === 'TaskUpdate')).toEqual([{ tool: 'TaskUpdate', taskId: '1', activeForm: 'g1 · review · r0' }])
})

test('adoption takes only an ownerless exact subject; other tasks are never touched', async () => {
  const w = new World()
  w.tasks.set('90', { id: '90', subject: 'g1 — title of g1', status: 'pending' })
  w.tasks.set('91', { id: '91', subject: 'g2 — title of g2 (mine)', status: 'pending' })
  w.tasks.set('92', { id: '92', subject: 'g2 — title of g2', status: 'pending', owner: 'alice' })
  w.tasks.set('93', { id: '93', subject: 'write the report', status: 'in_progress' })
  w.tasks.set('94', { id: '94', subject: 'g2 — PAUSED: waiting on Bob', status: 'pending' })
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(2))
  await w.tick()
  expect(w.tasks.get('90')?.owner).toBe(ownerOf(A))
  expect(w.tasks.get('91')).toEqual({ id: '91', subject: 'g2 — title of g2 (mine)', status: 'pending' })
  expect(w.tasks.get('92')).toEqual({ id: '92', subject: 'g2 — title of g2', status: 'pending', owner: 'alice' })
  expect(w.tasks.get('93')).toEqual({ id: '93', subject: 'write the report', status: 'in_progress' })
  expect(w.tasks.get('94')).toEqual({ id: '94', subject: 'g2 — PAUSED: waiting on Bob', status: 'pending' })
  expect(w.owned(A).length).toBe(2)
})

test('a failed owner update on a PAUSED goal is adopted next poll, not duplicated', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', { g1: { state: 'paused', reason: 'dirty-tree' }, g2: { state: 'ready' } })
  w.failing = { n: 1, when: c => c.tool === 'TaskUpdate' && c.owner !== undefined && c.taskId === '1' }
  await w.tick()
  expect(w.tasks.get('1')?.owner).toBeUndefined()
  expect(w.tasks.get('1')?.subject).toBe('g1 — PAUSED: dirty-tree')
  for (let i = 0; i < 10; i++) await w.tick()
  expect(w.tasks.size).toBe(2)
  expect(w.subjects(A)).toEqual(['g1 — PAUSED: dirty-tree', 'g2 — title of g2'])
})

test('two tasks for one goal collapse to the older', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(1))
  await w.tick()
  w.tasks.set('0', { id: '0', subject: 'g1 — title of g1', status: 'pending', owner: ownerOf(A) })
  await w.tick()
  expect([...w.tasks.keys()]).toEqual(['0'])
})

// --- the person's deletions and a replaced list ---------------------------

test('a single deleted task is never recreated, down to the last one', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(5))
  await w.tick()
  for (const id of ['1', '2', '3', '4', '5']) {
    w.tasks.delete(id)
    await w.tick()
    await w.tick()
  }
  expect(w.tasks.size).toBe(0)
})

test('every proper subset deleted stays deleted', async () => {
  for (let k = 1; k < 5; k++) {
    const w = new World()
    w.addWalk(A, '/a', { live: true, started: 10 })
    w.setGraph('/a', ready(5))
    await w.tick()
    for (let i = 1; i <= k; i++) w.tasks.delete(String(i))
    await w.tick()
    await w.tick()
    expect(w.tasks.size).toBe(5 - k)
  }
})

test('every task listed last poll gone at once is recreated, earlier deletions staying gone', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(5))
  await w.tick()
  w.tasks.delete('1') // the person
  await w.tick()
  w.tasks.clear() // /clear or a TodoWrite
  await w.tick()
  expect(w.subjects(A)).toEqual(['g2 — title of g2', 'g3 — title of g3', 'g4 — title of g4', 'g5 — title of g5'])
})

test('a one-goal walk whose task is deleted stays gone', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(1))
  await w.tick()
  w.tasks.clear()
  for (let i = 0; i < 5; i++) await w.tick()
  expect(w.tasks.size).toBe(0)
})

for (const n of [1, 5]) {
  test(`an all-completed ${n}-goal walk cleared by the engine is not recreated`, async () => {
    const w = new World()
    w.addWalk(A, '/a', { live: false, mtime: 5 }) // a finished /run-goal: its file stays
    const done: Record<string, Goal> = Object.fromEntries(Array.from({ length: n }, (_, i) => [`g${i + 1}`, { state: 'done' }]))
    w.setGraph('/a', { ...done })
    w.setGraph('/a', Object.fromEntries(Object.keys(done).map((g, i) => [g, { state: i === 0 ? 'running' : 'done' }])))
    await w.tick()
    w.setGraph('/a', done)
    await w.tick() // all completed → the engine clears
    expect(w.tasks.size).toBe(0)
    let creates = 0
    for (let i = 0; i < 20; i++) {
      await w.tick()
      creates += w.count('TaskCreate')
    }
    expect(creates).toBe(0)
  })
}

test('a newly selected walk whose goals are all done gets its completed tasks', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: false, mtime: 5 })
  w.setGraph('/a', { g1: { state: 'done' }, g2: { state: 'done' } })
  w.calls = []
  await w.poll()
  expect(w.count('TaskCreate')).toBe(2)
})

// --- choosing the walk ----------------------------------------------------

test('a live walk wins over an idle newer leftover, also between goals', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10, mtime: 100 })
  w.addWalk(B, '/b', { live: false, mtime: 999 }) // a newer finished /run-goal file
  w.setGraph('/a', ready(2))
  w.setGraph('/b', ready(3))
  await w.tick()
  expect(w.owned(A).length).toBe(2)
  expect(w.owned(B).length).toBe(0)
})

test('the walk on screen stays when it ends, with an older leftover listed', async () => {
  const w = new World()
  w.addWalk(C, '/c', { live: false, mtime: 1 })
  w.setGraph('/c', ready(4))
  w.addWalk(A, '/a', { live: true, started: 10, mtime: 100 })
  w.setGraph('/a', { g1: { state: 'running', phase: 'review', round: 0 }, g2: { state: 'done' } })
  await w.tick()
  w.walks = w.walks.filter(x => x.walk_id !== A) // walk-end deleted its file
  w.setGraph('/a', { g1: { state: 'done' }, g2: { state: 'paused', reason: 'proof-red' } })
  await w.tick()
  expect(w.subjects(A)).toEqual(['g1 — title of g1', 'g2 — PAUSED: proof-red'])
  expect(w.owned(C).length).toBe(0)
  w.setGraph('/a', { g1: { state: 'done' }, g2: { state: 'ready' } })
  await w.tick()
  expect(w.subjects(A)).toEqual(['g1 — title of g1', 'g2 — PAUSED: proof-red']) // applied once, then left alone
})

test('the unlisted walk\'s final read is retried until it succeeds; listed again, it is reconciled', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', { g1: { state: 'running', phase: 'review', round: 0 } })
  await w.tick()
  const file = w.walks[0]
  w.walks = []
  w.graphs.set('/a', 'fail')
  await w.tick()
  expect(w.owned(A)[0].status).toBe('in_progress')
  w.setGraph('/a', { g1: { state: 'done' } })
  await w.tick()
  expect(w.tasks.size).toBe(0) // done → completed → the engine cleared it
  // Resumed with a goal added: reconciled again. g1's task, cleared by the
  // engine once completed, is not brought back.
  w.walks = [{ ...file, live: true, started: 20 }]
  w.setGraph('/a', { g1: { state: 'done' }, g2: { state: 'running', phase: 'start', round: null } })
  await w.tick()
  expect(w.subjects(A)).toEqual(['g2 — title of g2'])
  expect(w.owned(A)[0].status).toBe('in_progress')
})

test('deletions while the walk is away (another session) stay deleted when it comes back', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(3))
  await w.tick()
  const file = w.walks[0]
  w.walks = [] // resumed by another session: not listed for this one
  await w.tick()
  for (const id of ['1', '2', '3']) {
    w.tasks.delete(id)
    await w.tick()
  }
  w.walks = [{ ...file, live: true, started: 30 }] // back in this session
  await w.tick()
  expect(w.tasks.size).toBe(0)
})

test('after a restart, a task the mod already owned and the person then deletes stays deleted', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(3))
  await w.tick()
  w.restart()
  await w.tick()
  w.tasks.delete('1')
  await w.tick()
  await w.tick()
  expect(w.subjects(A)).toEqual(['g2 — title of g2', 'g3 — title of g3'])
})

test('a newer idle file does not displace the walk on screen; a new live walk does, deleting the old tasks', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10, mtime: 100 })
  w.setGraph('/a', ready(2))
  await w.tick()
  w.walks[0].live = false
  w.addWalk(B, '/b', { live: false, mtime: 500 }) // a launch a gate stopped before any pid row
  w.setGraph('/b', ready(3))
  await w.tick()
  expect(w.owned(A).length).toBe(2)
  expect(w.owned(B).length).toBe(0)
  w.walks.find(x => x.walk_id === B)!.live = true
  w.walks.find(x => x.walk_id === B)!.started = 900
  w.setGraph('/a', { g1: { state: 'done' }, g2: { state: 'done' } })
  await w.tick()
  expect(w.owned(A).length).toBe(0)
  expect(w.owned(B).length).toBe(3)
})

test('two live walks: the latest started wins, and keeps the list when the older starts its next goal', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10, mtime: 100 })
  w.addWalk(B, '/b', { live: true, started: 50, mtime: 60 })
  w.setGraph('/a', ready(2))
  w.setGraph('/b', ready(3))
  await w.tick()
  expect(w.owned(B).length).toBe(3)
  w.walks.find(x => x.walk_id === A)!.mtime = 9999 // A's next goal: started does not move
  await w.tick()
  expect(w.owned(B).length).toBe(3)
  expect(w.owned(A).length).toBe(0)
})

test('after a restart the walk on screen stays; with nothing of the mod on the list, the newest listed wins', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10, mtime: 100 })
  w.setGraph('/a', ready(2))
  await w.tick()
  w.walks[0].live = false
  w.addWalk(B, '/b', { live: false, mtime: 500 })
  w.setGraph('/b', ready(1))
  w.restart()
  await w.tick()
  expect(w.owned(A).length).toBe(2)
  expect(w.owned(B).length).toBe(0)
  w.tasks.clear()
  w.restart()
  await w.tick()
  expect(w.owned(B).length).toBe(1)
})

test('two walk: owners after a failed delete: the walk reconciled last poll stays current', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10, mtime: 100 })
  w.setGraph('/a', ready(2))
  await w.tick()
  w.walks[0].live = false
  w.addWalk(B, '/b', { live: true, started: 50, mtime: 500 })
  w.setGraph('/b', ready(2))
  w.failing = { n: 1, when: c => c.status === 'deleted' }
  await w.tick()
  expect(w.owned(A).length).toBe(1) // one delete failed
  w.walks.find(x => x.walk_id === B)!.live = false
  await w.tick()
  expect(w.owned(B).length).toBe(2) // B stays; A's leftover is deleted
  expect(w.owned(A).length).toBe(0)
})

test('/clear: a new session id still finds the walk and rebuilds the list', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(3))
  await w.tick()
  w.session = 'S2' // the walker keeps S1
  w.tasks.clear() // a new session's list
  await w.tick()
  expect(w.owned(A).length).toBe(3)
  expect(w.state.sessions).toEqual(['S1', 'S2'])
})

// --- failures ---------------------------------------------------------------

test('failed reads change nothing; five in a row say so once in the transcript', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(2))
  await w.tick()
  const before = JSON.stringify([...w.tasks.values()])
  w.walksFail = true
  for (let i = 0; i < 7; i++) await w.tick()
  expect(JSON.stringify([...w.tasks.values()])).toBe(before)
  expect(w.logs.filter(([sink]) => sink === 'transcript').length).toBe(1)
  w.walksFail = false
  w.graphs.set('/a', 'fail')
  await w.tick()
  expect(JSON.stringify([...w.tasks.values()])).toBe(before)
})

test('a session without the Task tools does nothing', async () => {
  const w = new World()
  w.toolNames = ['Read', 'Bash']
  w.poll = w.newPoller()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(2))
  await w.tick()
  await w.tick()
  expect(w.tasks.size).toBe(0)
  expect(w.calls.length).toBe(0)
  expect(w.logs.filter(([s]) => s === 'debug').length).toBe(1)
})

test('chooseWalk: ties go to the larger walk_id', () => {
  const mk = (id: string, o: Partial<WalkWalk>): WalkWalk => ({ root: `/${id}`, walk_id: id, journal: '', session: 'S', mtime: 1, live: false, started: null, ...o })
  expect(chooseWalk([mk('a1', { live: true, started: 5 }), mk('b1', { live: true, started: 5 })], [], null)?.walkId).toBe('b1')
  expect(chooseWalk([mk('a1', { mtime: 7 }), mk('b1', { mtime: 7 })], [], null)?.walkId).toBe('b1')
  expect(chooseWalk([], [], null)).toBeNull()
})

test('a created task carries the description walk goal <goal> in <root>', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(1))
  await w.tick()
  expect(w.calls.find(c => c.tool === 'TaskCreate')?.description).toBe('walk goal g1 in /a')
})

test('/clear that also resets the host state: the session ids kept in memory still find the walk', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(2))
  await w.tick()
  w.session = 'S2' // the walker keeps S1
  w.state = structuredClone(EMPTY_TASKS) // the host dropped $.state
  w.tasks.clear()
  await w.tick()
  expect(w.owned(A).length).toBe(2)
})

test('tasks owned by a walk neither listed nor remembered are left as they are', async () => {
  const w = new World()
  w.tasks.set('7', { id: '7', subject: 'g1 — title of g1', status: 'in_progress', owner: ownerOf(C) })
  w.addWalk(A, '/a', { live: false, mtime: 999 }) // an idle file of this session
  w.setGraph('/a', ready(2))
  await w.tick()
  expect(w.tasks.get('7')?.owner).toBe(ownerOf(C))
  expect(w.owned(A).length).toBe(0)
})

test('a TaskUpdate answered success:false is a failure: the owner goes on next poll', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(2))
  w.refusing = { n: 1, when: c => c.tool === 'TaskUpdate' && c.owner !== undefined && c.taskId === '1' }
  await w.tick()
  expect(w.tasks.get('1')?.owner).toBeUndefined()
  expect(w.state.created).toEqual(['g2'])
  await w.tick()
  expect(w.tasks.get('1')?.owner).toBe(ownerOf(A))
  expect(w.tasks.size).toBe(2)
})

test('seven failed graph reads in a row: one transcript line', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(2))
  await w.tick()
  w.graphs.set('/a', 'fail')
  for (let i = 0; i < 7; i++) await w.tick()
  expect(w.logs.filter(([sink]) => sink === 'transcript').length).toBe(1)
})

test('after the engine clears a finished walk, an older leftover does not take the empty list', async () => {
  const w = new World()
  w.addWalk(C, '/c', { live: false, mtime: 1 }) // an older leftover
  w.setGraph('/c', ready(3))
  w.addWalk(A, '/a', { live: true, started: 10, mtime: 100 })
  w.setGraph('/a', { g1: { state: 'running', phase: 'review', round: 0 } })
  await w.tick()
  w.walks = w.walks.filter(x => x.walk_id !== A) // walk-end
  w.setGraph('/a', { g1: { state: 'done' } })
  await w.tick() // final apply: completed → the engine clears it
  expect(w.tasks.size).toBe(0)
  for (let i = 0; i < 5; i++) await w.tick()
  expect(w.tasks.size).toBe(0)
  expect(w.owned(C).length).toBe(0)
})

test('no walk file and nothing reconciled: no TaskList call', async () => {
  const w = new World()
  await w.tick()
  await w.tick()
  expect(w.calls.length).toBe(0)
})

test('Task tools that arrive later are found within 20 polls', async () => {
  const w = new World()
  w.toolNames = ['Read']
  w.poll = w.newPoller()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', ready(1))
  await w.tick()
  w.toolNames = ['TaskCreate', 'TaskUpdate', 'TaskList']
  for (let i = 0; i < 20; i++) await w.tick()
  expect(w.owned(A).length).toBe(1)
  expect(w.toolListCalls).toBe(2)
})

test('creates of completed tasks go after the others', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', { g1: { state: 'done' }, g2: { state: 'running', phase: 'implement', round: 0 }, g3: { state: 'done' } })
  await w.tick()
  const creates = w.calls.filter(c => c.tool === 'TaskCreate').map(c => String(c.subject).split(' — ')[0])
  expect(creates).toEqual(['g2', 'g1', 'g3'])
})

// --- end to end: real events.py output (fixtures.ts) through the real poll ---

function feed(w: World, step: FixtureStep) {
  w.walks = step.walks.map(x => ({ ...x }))
  // The fixture keeps only the goal fields the task list reads.
  w.graphs = new Map(Object.entries(step.graphs).map(([root, g]) => [root, structuredClone(g) as unknown as WalkGraph]))
}
const WA = (s: FixtureStep[]) => s[0].walks.find(x => x.root === '/W/a')!.walk_id

test('fixtures: a launch a gate stopped before any pid row does not take the list', async () => {
  const steps = SCENARIOS.gateStopped
  const w = new World()
  feed(w, steps[0])
  await w.tick()
  const a = WA(steps)
  expect(w.subjects(a)).toEqual(['g1-store — Persist inbound mail', 'g2-ack — Label-ack after enqueue', 'g3-other — Independent sibling'])
  feed(w, steps[1])
  await w.tick()
  expect(w.subjects(a)[0]).toBe('g1-store — PAUSED: stopped')
  const b = steps[1].walks.find(x => x.root === '/W/b')!.walk_id
  expect(w.owned(b).length).toBe(0)
})

test('fixtures: between goals the walk stays live and current', async () => {
  const steps = SCENARIOS.betweenGoals
  const w = new World()
  feed(w, steps[0])
  await w.tick()
  const a = WA(steps)
  expect(steps[0].walks[0].live).toBe(true)
  expect(w.owned(a).map(t => t.status).sort()).toEqual(['completed', 'pending', 'pending'])
})

test('fixtures: walk-end with an older leftover: the finished walk is applied once, the leftover not shown', async () => {
  const steps = SCENARIOS.walkEnd
  const w = new World()
  feed(w, steps[0])
  await w.tick()
  const a = WA(steps)
  feed(w, steps[1])
  await w.tick()
  expect(w.subjects(a)).toEqual(['g1-store — Persist inbound mail', 'g2-ack — PAUSED: proof-red', 'g3-other — Independent sibling'])
  const c = steps[0].walks.find(x => x.root === '/W/c')!.walk_id
  expect(w.owned(c).length).toBe(0)
})

test('fixtures: two live walks: the latest started keeps the list through the older\'s next goal', async () => {
  const steps = SCENARIOS.twoLive
  const w = new World()
  feed(w, steps[0])
  await w.tick()
  const a = WA(steps)
  const b = steps[0].walks.find(x => x.root === '/W/b')!.walk_id
  expect(w.owned(b).length).toBe(3)
  feed(w, steps[1])
  await w.tick()
  expect(w.owned(b).length).toBe(3)
  expect(w.owned(a).length).toBe(0)
})

test('fixtures: a single /run-goal (dispatch rows, no walk row) is live and current', async () => {
  const steps = SCENARIOS.runGoalOnly
  const w = new World()
  feed(w, steps[0])
  await w.tick()
  const a = WA(steps)
  expect(steps[0].walks[0].live).toBe(true)
  expect(w.owned(a).find(t => t.subject.startsWith('g1-store'))?.status).toBe('in_progress')
})

test('fixtures: a new live walk replaces the walk on screen', async () => {
  const steps = SCENARIOS.newLiveReplaces
  const w = new World()
  feed(w, steps[0])
  await w.tick()
  const a = WA(steps)
  expect(w.owned(a).length).toBe(3)
  feed(w, steps[1])
  await w.tick()
  const b = steps[1].walks.find(x => x.root === '/W/b')!.walk_id
  expect(w.owned(a).length).toBe(0)
  expect(w.owned(b).length).toBe(3)
})

test('fixtures: a gate stop on a goal not yet started keeps its plain title', async () => {
  const steps = SCENARIOS.gateUnstarted
  const w = new World()
  feed(w, steps[0])
  await w.tick()
  feed(w, steps[1])
  await w.tick()
  const a = WA(steps)
  const g2 = w.owned(a).find(t => t.subject.startsWith('g2-ack'))
  expect(g2?.subject).toBe('g2-ack — Label-ack after enqueue')
  expect(g2?.status).toBe('pending')
})

test('a created task whose owner update failed is adopted by id after its subject changed', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  // Created while paused for one reason; the owner update fails; the reason
  // changes, so the orphan's subject is neither the plain title nor the new one.
  w.setGraph('/a', { g1: { state: 'paused', reason: 'proof-red' } })
  w.failing = { n: 1, when: c => c.tool === 'TaskUpdate' && c.owner !== undefined }
  await w.tick()
  expect(w.tasks.get('1')?.owner).toBeUndefined()
  expect(w.tasks.get('1')?.subject).toBe('g1 — PAUSED: proof-red')
  w.setGraph('/a', { g1: { state: 'paused', reason: 'dirty-tree' } })
  await w.tick()
  expect([...w.tasks.values()].map(t => [t.id, t.subject, t.owner])).toEqual([['1', 'g1 — PAUSED: dirty-tree', ownerOf(A)]])
})

test('a final apply with a failed write is retried, not frozen', async () => {
  const w = new World()
  w.addWalk(A, '/a', { live: true, started: 10 })
  w.setGraph('/a', { g1: { state: 'running', phase: 'review', round: 0 }, g2: { state: 'ready' } })
  await w.tick()
  w.walks = [] // walk-end
  w.setGraph('/a', { g1: { state: 'done' }, g2: { state: 'paused', reason: 'proof-red' } })
  w.failing = { n: 1, when: c => c.tool === 'TaskUpdate' && c.taskId === '2' }
  await w.tick()
  expect(w.state.finalApplied).toBe(false)
  await w.tick()
  expect(w.subjects(A)).toEqual(['g1 — title of g1', 'g2 — PAUSED: proof-red'])
  expect(w.state.finalApplied).toBe(true)
})

// --- the randomised invariant test (VERIFICATION item 2) ------------------

// A small deterministic PRNG, so a failure reprints its seed.
function rng(seed: number) {
  let s = seed >>> 0
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0
    return s / 2 ** 32
  }
}

test('random sequences keep the invariants after every poll', async () => {
  const STATES: WalkGoal['state'][] = ['ready', 'waiting', 'running', 'paused', 'bounced', 'done']
  const REASONS = ['proof-red', 'dirty-tree', 'walk-stuck', null]
  for (let seed = 1; seed <= 2500; seed++) {
    const r = rng(seed)
    const pick = <X>(xs: X[]) => xs[Math.floor(r() * xs.length)]
    const w = new World()
    const ids = [A, B, C]
    let clock = 100
    // Goals the person deleted while this walk was current, since its last restart.
    let personDeleted = new Set<string>()
    let currentSeen: string | null = null
    const foreignBefore = new Map<string, string>()
    for (let step = 0; step < 25; step++) {
      clock += 10
      const roll = r()
      let injected = false
      if (roll < 0.18) {
        const id = pick(ids)
        const root = `/${id.slice(0, 1)}`
        const n = 1 + Math.floor(r() * 4)
        const live = r() < 0.8
        w.addWalk(id, root, { live, started: live ? clock : null, mtime: clock, session: w.session })
        w.setGraph(root, ready(n))
      } else if (roll < 0.45 && w.walks.length > 0) {
        const wk = pick(w.walks)
        const g = w.graphs.get(wk.root)
        if (g && g !== 'fail') {
          const goal = pick(Object.keys(g.goals ?? {}))
          const st = pick(STATES)
          g.goals![goal] = { ...g.goals![goal], state: st, round: r() < 0.5 ? null : 1, phase: st === 'running' ? 'review' : null, reason: st === 'paused' || st === 'bounced' ? pick(REASONS) : null }
        }
      } else if (roll < 0.52 && w.walks.length > 0) {
        const wk = pick(w.walks)
        if (r() < 0.5) w.walks = w.walks.filter(x => x !== wk) // walk-end
        else wk.live = false // stopped, file stays
      } else if (roll < 0.62) {
        const mine = [...w.tasks.values()].filter(t => t.owner && currentSeen && t.owner === ownerOf(currentSeen))
        if (mine.length > 0) {
          const t = pick(mine)
          w.tasks.delete(t.id)
          personDeleted.add(t.subject.split(' — ')[0])
        }
      } else if (roll < 0.67) {
        w.tasks.clear() // a replaced list; the person's earlier deletions stay deleted
      } else if (roll < 0.72) {
        const id = String(1000 + step)
        const subject = r() < 0.5 ? `note ${step}` : `g${1 + Math.floor(r() * 4)} — title of g${1 + Math.floor(r() * 4)}`
        // Some are someone else's (an owner that is not walk:), never touched.
        w.tasks.set(id, r() < 0.3 ? { id, subject, status: 'pending', owner: 'alice' } : { id, subject, status: 'pending' })
      } else if (roll < 0.76) {
        w.restart()
        personDeleted = new Set()
      } else if (roll < 0.79) {
        w.session = `S${step}` // /clear
        w.tasks.clear()
      } else if (roll < 0.88) {
        injected = true
        w.failing = { n: 1 + Math.floor(r() * 3), when: () => r() < 0.5 }
      } else if (roll < 0.92 && w.walks.length > 0) {
        injected = true
        w.graphs.set(pick(w.walks).root, 'fail')
      }
      // Tasks no walk owns, as they stood before the poll.
      foreignBefore.clear()
      for (const t of w.tasks.values()) if (!t.owner?.startsWith('walk:')) foreignBefore.set(t.id, JSON.stringify(t))

      await w.poll()
      w.failing = null
      for (const [root, g] of w.graphs) if (g === 'fail') w.setGraph(root, ready(2))

      const ctx = `seed ${seed} step ${step}`
      const cur = w.state.last?.walkId ?? null
      if (cur !== currentSeen) {
        personDeleted = new Set()
        currentSeen = cur
      }
      const owned = [...w.tasks.values()].filter(t => t.owner?.startsWith('walk:'))
      // I1: a task no walk owns is untouched, unless adopted (an exact subject).
      for (const [id, before] of foreignBefore) {
        const now = w.tasks.get(id)
        if (!now) throw new Error(`${ctx}: deleted a task it does not own: ${before}`)
        if (JSON.stringify(now) !== before) {
          const b = JSON.parse(before) as T
          const m = /^(g\d+) — title of \1$/.exec(b.subject)
          const adopted = cur !== null && !b.owner && now.owner === ownerOf(cur) && m !== null && now.subject.startsWith(`${m[1]} — `)
          if (!adopted) throw new Error(`${ctx}: touched a task it does not own: ${before} → ${JSON.stringify(now)}`)
        }
      }
      if (cur) {
        // I2: at most one task per goal of the current walk.
        const perGoal = new Map<string, number>()
        for (const t of owned.filter(t => t.owner === ownerOf(cur))) {
          const g = t.subject.split(' — ')[0]
          perGoal.set(g, (perGoal.get(g) ?? 0) + 1)
        }
        for (const [g, n] of perGoal) if (n > 1) throw new Error(`${ctx}: ${n} tasks for ${g}`)
        // I3: no task of another walk survives a poll with no injected failure.
        if (!injected) {
          const stray = owned.filter(t => t.owner !== ownerOf(cur))
          if (stray.length > 0) throw new Error(`${ctx}: another walk's task survived: ${JSON.stringify(stray)}`)
        }
        // I4: a goal the person deleted does not come back.
        for (const t of owned.filter(t => t.owner === ownerOf(cur))) {
          const g = t.subject.split(' — ')[0]
          if (personDeleted.has(g)) throw new Error(`${ctx}: person-deleted ${g} came back`)
        }
      }
      // I5: no subject or activeForm says null.
      for (const t of w.tasks.values()) {
        if (/\bnull\b|rnull/.test(`${t.subject} ${t.activeForm ?? ''}`)) throw new Error(`${ctx}: null in ${JSON.stringify(t)}`)
      }
      w.engineClear()
    }
  }
})
