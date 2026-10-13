/** One goal as `events.py graph --json` gives it. */
export type WalkGoal = {
  title: string
  state: 'done' | 'running' | 'paused' | 'ready' | 'waiting' | 'bounced'
  waits: string[]
  round: number | null
  phase: string | null
  model: string | null
  fallback: boolean
  secs: number | null
  cost: number | null
  /** Why a paused or bounced goal stopped (never empty then); null otherwise. */
  reason?: string | null
}

/** One walk `events.py walks --json` lists: a walk file this session's ids launched. */
export type WalkWalk = {
  root: string
  walk_id: string
  journal: string
  session: string
  /** The walk file's modification time, milliseconds. */
  mtime: number
  /** Its walker process is alive. */
  live: boolean
  /** When that walker began (`ts_mono` of its first row), null when not live. */
  started: number | null
}

/** The task cache the reconcile keeps between polls. Only `last` takes part in
 * choosing the walk: a tie between two `walk:` owners on the list, and, with
 * none of the mod's tasks listed, the walk that stays current. */
export type WalkTasks = {
  /** Every session id this process has had (`/clear` changes it). */
  sessions: string[]
  /** The walk reconciled on the last poll: its id and root (for the final read). */
  last: { walkId: string; root: string } | null
  /** Goals of `last` whose task the mod created or adopted (owner set). */
  created: string[]
  /** Task id → goal, for `last`'s tasks listed on the previous poll. */
  prevListed: Record<string, string>
  /** `last`'s final state was applied while it is unlisted. */
  finalApplied: boolean
}

/** A git-graph row: a goal's (with the cell of its glyph and the lanes past it) or a fork's. */
export type WalkRow = { graph: string; goal?: string; col?: number; cont?: string }

/** `events.py graph --json`: every goal of a GOALS.md, laid out. */
export type WalkGraph = {
  found: boolean
  dir: string
  feature?: string
  done?: number
  total?: number
  /** The newest running goal; `others` more run beside it in a parallel walk. */
  running?: string | null
  others?: number
  phase?: string | null
  round?: number | null
  width?: number
  rows?: WalkRow[]
  goals?: Record<string, WalkGoal>
}

/** What the /walk pane draws: the last graph read, the last read's failure, the repo asked for. */
export type WalkView = { graph: WalkGraph | null; error: string | null; dir: string | null }

declare module 'claude-code' {
  interface PluginState {
    walk: { view: WalkView; tasks: WalkTasks }
  }
}
