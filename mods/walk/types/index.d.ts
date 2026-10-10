/** The footer label: `walk <goal> r<n> · <phase> · <done>/<total>`, or null when idle. */
export type WalkLabel = string | null

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
    walk: { label: WalkLabel; view: WalkView }
  }
}
