import type { WalkGraph, WalkWalk } from '../types'

// The task list as a function of the world (docs/features/walk-tasks/PLAN.md,
// step 4). Each poll picks the current walk from the `walks` listing and the
// list itself, derives the tasks its graph asks for, and returns the tool calls
// that make the list so. Nothing here touches `$`: the poll in register.tsx
// reads, calls this, and runs what it returns.

export type TaskStatus = 'pending' | 'in_progress' | 'completed'
export type ListedTask = { id: string; subject: string; status: TaskStatus; owner?: string }

/** One goal's task as the graph asks for it. */
export type Desired = {
  goal: string
  /** `<goal> — <title>`: the subject of a goal that has not stopped. */
  base: string
  subject: string
  status: TaskStatus
  activeForm: string | null
}

export type Fields = { subject?: string; status?: TaskStatus; activeForm?: string; owner?: string }
export type Op =
  | { kind: 'delete'; taskId: string }
  | { kind: 'update'; taskId: string; goal: string; fields: Fields }
  | { kind: 'create'; goal: string; subject: string; status: TaskStatus; activeForm: string | null }

export const OWNER_PREFIX = 'walk:'
/** The owner a walk's tasks carry: `walk:` and the first 8 of its walk_id. */
export const ownerOf = (walkId: string) => `${OWNER_PREFIX}${walkId.slice(0, 8)}`
const lead = (goal: string) => `${goal} — `

/** One task per goal, in GOALS.md order (the graph keeps it). */
export function desiredFor(graph: WalkGraph): Desired[] {
  const out: Desired[] = []
  for (const [goal, g] of Object.entries(graph.goals ?? {})) {
    const base = `${lead(goal)}${g.title}`
    // events.py never sends an empty reason for these states; `stopped` keeps
    // the word `null` off a subject even if it did.
    const reason = String(g.reason ?? '').trim() || 'stopped'
    switch (g.state) {
      case 'done':
        out.push({ goal, base, subject: base, status: 'completed', activeForm: null })
        break
      case 'running': {
        const round = g.round === null || g.round === undefined ? '' : ` · r${g.round}`
        out.push({ goal, base, subject: base, status: 'in_progress', activeForm: `${goal} · ${g.phase ?? 'running'}${round}` })
        break
      }
      case 'paused':
        out.push({ goal, base, subject: `${lead(goal)}PAUSED: ${reason}`, status: 'in_progress', activeForm: `${goal} PAUSED: ${reason}` })
        break
      case 'bounced':
        out.push({ goal, base, subject: `${lead(goal)}BOUNCED: ${reason}`, status: 'pending', activeForm: null })
        break
      default:
        out.push({ goal, base, subject: base, status: 'pending', activeForm: null })
    }
  }
  return out
}

/** The walk the list follows: `walkId` empty means "leave the list alone". */
export type Choice = { walkId: string; root: string | null; listed: boolean }

const byNewer = <T>(key: (x: T) => number, id: (x: T) => string) => (a: T, b: T) =>
  key(b) - key(a) || (id(b) > id(a) ? 1 : id(b) < id(a) ? -1 : 0)

/**
 * (1) the most recently started live walk; else (2) the walk owning the mod's
 * tasks on the list — with several owners, the walk reconciled last poll if it
 * is among them, else the owner whose walk is listed newest; else, with none
 * of the mod's tasks listed, the remembered last walk; else (3) the newest
 * listed walk. Ties: larger walk_id.
 */
export function chooseWalk(walks: WalkWalk[], list: ListedTask[], last: { walkId: string; root: string } | null): Choice | null {
  const live = walks.filter(w => w.live).sort(byNewer(w => w.started ?? -Infinity, w => w.walk_id))
  if (live.length > 0) return { walkId: live[0].walk_id, root: live[0].root, listed: true }

  const owners = new Set(list.map(t => t.owner).filter((o): o is string => !!o && o.startsWith(OWNER_PREFIX)))
  if (owners.size > 0) {
    if (last && owners.has(ownerOf(last.walkId))) {
      const w = walks.find(x => x.walk_id === last.walkId)
      return { walkId: last.walkId, root: w?.root ?? last.root, listed: !!w }
    }
    const listed = walks.filter(w => owners.has(ownerOf(w.walk_id))).sort(byNewer(w => w.mtime, w => w.walk_id))
    if (listed.length > 0) return { walkId: listed[0].walk_id, root: listed[0].root, listed: true }
    // The tasks on screen belong to a walk neither listed nor remembered (a
    // restart after its file went): nothing to read, so leave them as shown.
    return { walkId: '', root: null, listed: false }
  }

  // Nothing of the mod's on the list (the engine cleared a finished walk, or
  // the person removed them): the remembered walk stays the walk, so a leftover
  // file does not take the empty screen. Only with nothing remembered (a fresh
  // start, a restart) does the newest listed walk show.
  if (last) {
    const w = walks.find(x => x.walk_id === last.walkId)
    return { walkId: last.walkId, root: w?.root ?? last.root, listed: !!w }
  }
  const newest = [...walks].sort(byNewer(w => w.mtime, w => w.walk_id))
  if (newest.length > 0) return { walkId: newest[0].walk_id, root: newest[0].root, listed: true }
  return null
}

export type ReconcileIn = {
  desired: Desired[]
  /** The current walk's owner, `walk:<id8>`. */
  owner: string
  list: ListedTask[]
  /** Goals of this walk whose task the mod created or adopted. */
  created: ReadonlySet<string>
  /** Task id → goal, this walk's tasks listed on the previous poll. */
  prevListed: Readonly<Record<string, string>>
  /** Task id → the activeForm last sent (TaskList does not return it). */
  lastActive: Readonly<Record<string, string>>
  /** This walk was not the one reconciled on the previous poll. */
  firstSelect: boolean
  /** Task id → goal: tasks this process created whose owner update failed. */
  orphans?: Readonly<Record<string, string>>
}

export type ReconcileOut = {
  ops: Op[]
  /** Task id → goal: this walk's tasks kept on the list this poll (before creates). */
  listedNow: Record<string, string>
}

const numericId = (id: string) => (Number.isFinite(Number(id)) ? Number(id) : Number.MAX_SAFE_INTEGER)

export function reconcile(inp: ReconcileIn): ReconcileOut {
  const ops: Op[] = []
  const listIds = new Set(inp.list.map(t => t.id))
  const goals = new Map(inp.desired.map(d => [d.goal, d]))
  const mine = inp.list.filter(t => !!t.owner && t.owner.startsWith(OWNER_PREFIX))

  // Another walk's tasks leave the list, completed ones included.
  for (const t of mine) if (t.owner !== inp.owner) ops.push({ kind: 'delete', taskId: t.id })

  // This walk's tasks, matched to goals by subject; the older of two is kept,
  // and a task for a goal no longer in GOALS.md is deleted.
  const byGoal = new Map<string, ListedTask>()
  const own = mine.filter(t => t.owner === inp.owner).sort((a, b) => numericId(a.id) - numericId(b.id))
  for (const t of own) {
    const goal = [...goals.keys()].find(g => t.subject.startsWith(lead(g)))
    if (!goal || byGoal.has(goal)) {
      ops.push({ kind: 'delete', taskId: t.id })
      continue
    }
    byGoal.set(goal, t)
  }
  const listedNow: Record<string, string> = {}
  for (const [goal, t] of byGoal) listedNow[t.id] = goal

  const allCompleted = inp.desired.length > 0 && inp.desired.every(d => d.status === 'completed')
  // A replaced list (/clear, a TodoWrite): two or more of this walk's tasks
  // listed last poll, all gone now — but never the engine's all-completed clear.
  const prevIds = Object.keys(inp.prevListed)
  const replaced = !allCompleted && prevIds.length >= 2 && prevIds.every(id => !listIds.has(id))
  const replacedGoals = new Set(replaced ? prevIds.map(id => inp.prevListed[id]) : [])

  const used = new Set<string>()
  for (const d of inp.desired) {
    const t = byGoal.get(d.goal)
    if (t) {
      const fields: Fields = {}
      if (t.subject !== d.subject) fields.subject = d.subject
      if (t.status !== d.status) fields.status = d.status
      if (d.activeForm && inp.lastActive[t.id] !== d.activeForm) fields.activeForm = d.activeForm
      if (Object.keys(fields).length > 0) ops.push({ kind: 'update', taskId: t.id, goal: d.goal, fields })
      continue
    }
    // The person deleted it (and the list was not replaced): it stays deleted.
    if (inp.created.has(d.goal) && !replacedGoals.has(d.goal)) continue
    // The engine cleared an all-completed walk the list already showed.
    if (allCompleted && byGoal.size === 0 && !inp.firstSelect) continue
    // Adopt one ownerless task whose subject is exactly the goal's plain title
    // or its desired subject now (an Architect-seeded task, or the mod's own
    // whose owner update failed); a person's own `g1 — PAUSED: …` is not ours.
    const orphan =
      inp.list.find(x => !x.owner && !used.has(x.id) && inp.orphans?.[x.id] === d.goal) ??
      inp.list.find(x => !x.owner && !used.has(x.id) && (x.subject === d.base || x.subject === d.subject))
    if (orphan) {
      used.add(orphan.id)
      const fields: Fields = { owner: inp.owner }
      if (orphan.subject !== d.subject) fields.subject = d.subject
      if (orphan.status !== d.status) fields.status = d.status
      if (d.activeForm) fields.activeForm = d.activeForm
      ops.push({ kind: 'update', taskId: orphan.id, goal: d.goal, fields })
      continue
    }
    ops.push({ kind: 'create', goal: d.goal, subject: d.subject, status: d.status, activeForm: d.activeForm })
  }
  // Creates of completed tasks go last: the engine may clear a list the moment
  // all of it is completed, which would take the first ones mid-poll.
  const rank = (op: Op) => (op.kind === 'create' && op.status === 'completed' ? 1 : 0)
  return { ops: ops.map((op, i) => [op, i] as const).sort((a, b) => rank(a[0]) - rank(b[0]) || a[1] - b[1]).map(([op]) => op), listedNow }
}
