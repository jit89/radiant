import type { WalkGraph, WalkTasks, WalkWalk } from '../types'
import { chooseWalk, desiredFor, ownerOf, reconcile } from './reconcile'
import type { ListedTask, Op } from './reconcile'

// One task poll (PLAN step 4): read the walks and the list, choose, reconcile,
// run the calls, keep the cache. Everything outside comes in through `deps`, so
// register.tsx wires it to `$` and the tests drive the same code with fakes.

export type TaskDeps = {
  toolNames: () => Promise<string[]>
  sessionId: () => Promise<string>
  getState: () => Promise<WalkTasks>
  setState: (fn: (s: WalkTasks) => WalkTasks) => Promise<void>
  /** `events.py` with these arguments, its stdout parsed; throws on failure. */
  events: (args: string[]) => Promise<unknown>
  /** A Task* tool call's result; throws on a refusal or an errored result. */
  call: (input: Record<string, unknown>) => Promise<unknown>
  log: (line: string, sink: 'debug' | 'transcript') => void
}

export const EMPTY_TASKS: WalkTasks = { sessions: [], last: null, created: [], prevListed: {}, finalApplied: false }

const TASK_TOOLS = ['TaskCreate', 'TaskUpdate', 'TaskList']
// Failed polls in a row before one line reaches the transcript.
export const MAX_FAILURES = 5

export function makeTaskPoller(deps: TaskDeps) {
  // Module memory (a reload starts it over, and resends an activeForm once).
  const lastActive: Record<string, string> = {}
  let toolsSeen: boolean | null = null
  let toolsAsked = 0
  let failures = 0
  // Every session id this process had, kept here too: `/clear` changes the id
  // and fires no session.start, and the host might not keep $.state across it.
  const seenSessions: string[] = []
  // Tasks this process created whose owner update failed (id → goal): adopted
  // by id next poll whatever their subject has become, since the mod made them.
  const orphans: Record<string, string> = {}

  // A Task* call; TaskUpdate answers a refusal as `success: false` (its error in
  // `error`), which counts as a failure like a thrown one.
  const call = async (input: Record<string, unknown>) => {
    const r = (await deps.call(input)) as { success?: boolean; error?: string } | undefined
    if (r && typeof r === 'object' && r.success === false) throw new Error(`${String(input.tool)} failed: ${r.error ?? 'success: false'}`)
    return r
  }

  // Runs the ops; true when every one succeeded.
  const runOps = async (ops: Op[], owner: string, root: string, created: Set<string>, listed: Record<string, string>) => {
    let allOk = true
    for (const op of ops) {
      try {
        if (op.kind === 'delete') {
          await call({ tool: 'TaskUpdate', taskId: op.taskId, status: 'deleted' })
          delete listed[op.taskId]
        } else if (op.kind === 'update') {
          await call({ tool: 'TaskUpdate', taskId: op.taskId, ...op.fields })
          if (op.fields.owner) {
            created.add(op.goal)
            listed[op.taskId] = op.goal
            delete orphans[op.taskId]
          }
          if (op.fields.activeForm) lastActive[op.taskId] = op.fields.activeForm
        } else {
          const made = (await call({
            tool: 'TaskCreate',
            subject: op.subject,
            description: `walk goal ${op.goal} in ${root}`,
            ...(op.activeForm ? { activeForm: op.activeForm } : {}),
          })) as { task?: { id?: string } } | undefined
          const id = made?.task?.id
          if (!id) {
            allOk = false
            continue
          }
          // The owner goes on next; until it does, the next poll adopts this
          // ownerless task (by id) rather than creating another.
          orphans[id] = op.goal
          await call({ tool: 'TaskUpdate', taskId: id, owner, ...(op.status !== 'pending' ? { status: op.status } : {}) })
          delete orphans[id]
          created.add(op.goal)
          listed[id] = op.goal
          if (op.activeForm) lastActive[id] = op.activeForm
        }
      } catch (error) {
        // One failed call: the next poll's reconcile tries again.
        allOk = false
        deps.log(`walk: ${op.kind} failed: ${String(error)}`, 'debug')
      }
    }
    return allOk
  }

  return async function pollTasks(): Promise<void> {
    // Asked once, and again every 20 polls while they are missing (they may
    // arrive after the first poll).
    if (toolsSeen !== true && toolsAsked % 20 === 0) {
      const names = new Set(await deps.toolNames())
      const had = toolsSeen
      toolsSeen = TASK_TOOLS.every(n => names.has(n))
      if (!toolsSeen && had === null) deps.log('walk: no Task* tools in this session; the task list is not kept', 'debug')
    }
    toolsAsked += 1
    if (!toolsSeen) return
    try {
      const id = await deps.sessionId()
      if (!seenSessions.includes(id)) seenSessions.push(id)
      let state = await deps.getState()
      const sessions = [...new Set([...state.sessions, ...seenSessions])]
      if (sessions.length !== state.sessions.length) {
        state = { ...state, sessions }
        await deps.setState(s => ({ ...s, sessions }))
      }
      const walks = (await deps.events(['walks', ...sessions.flatMap(s => ['--session', s]), '--json'])) as WalkWalk[]
      // No walk file and nothing reconciled yet: no TaskList call at all.
      if (walks.length === 0 && !state.last) {
        failures = 0
        return
      }
      const listing = (await call({ tool: 'TaskList' })) as { tasks?: ListedTask[] } | undefined
      const list = listing?.tasks ?? []
      const choice = chooseWalk(walks, list, state.last)
      if (!choice || !choice.walkId || !choice.root) {
        failures = 0
        return
      }
      const firstSelect = state.last?.walkId !== choice.walkId
      // The current walk unlisted (walk-end, or moved to another session): its
      // final state is applied once, then the list is left alone.
      if (!choice.listed && !firstSelect && state.finalApplied) {
        // No writes, but keep "listed on the previous poll" current, so the
        // person's deletions while it is frozen are not read later, when it is
        // listed again (a walk back from another session), as a replaced list.
        const owner = ownerOf(choice.walkId)
        const listedNow: Record<string, string> = {}
        for (const t of list) if (t.owner === owner) listedNow[t.id] = t.subject.split(' — ')[0]
        if (JSON.stringify(listedNow) !== JSON.stringify(state.prevListed)) {
          await deps.setState(s => ({ ...s, prevListed: listedNow }))
        }
        failures = 0
        return
      }
      const graph = (await deps.events(['graph', '--json', '--dir', choice.root])) as WalkGraph
      if (!graph || !graph.found) throw new Error(`no GOALS.md at ${choice.root}`)
      failures = 0 // every read of this poll succeeded
      const owner = ownerOf(choice.walkId)
      const created = new Set(firstSelect ? [] : state.created)
      const { ops, listedNow } = reconcile({
        desired: desiredFor(graph),
        owner,
        list,
        created,
        prevListed: firstSelect ? {} : state.prevListed,
        lastActive,
        firstSelect,
        orphans,
      })
      const allOk = await runOps(ops, owner, choice.root, created, listedNow)
      // A goal whose owned task is on the list is the mod's, whether this
      // process created it or found it (after a restart or a reload): its
      // later absence is the person's deletion.
      for (const goal of Object.values(listedNow)) created.add(goal)
      const root = choice.root
      await deps.setState(s => ({
        ...s,
        last: { walkId: choice.walkId, root },
        created: [...created],
        prevListed: listedNow,
        // A final apply counts only when every write of it succeeded.
        finalApplied: !choice.listed && allOk,
      }))
    } catch (error) {
      // A failed read changes nothing; five in a row say so once.
      failures += 1
      deps.log(`walk: task poll failed (${failures}): ${String(error)}`, 'debug')
      if (failures === MAX_FAILURES) deps.log(`walk: the task list is not updating: ${String(error)}`, 'transcript')
    }
  }
}
