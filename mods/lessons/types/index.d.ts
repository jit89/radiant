/** One piece of evidence under a pending lesson, as `lessons.py cli --json-list` gives it. */
export type LessonEvidence =
  | { id: string; command: string; count: number; untrusted_tool_output: string[] }
  | { id: string; user_said: string; after_action: string }

/** One pending lesson in the checklist dialog (every text already through lessons.py's visible()). */
export type LessonItem = {
  id: string
  text: string
  scope: 'project' | 'global'
  count: number
  evidence: LessonEvidence[]
  recommended: boolean
  /** Why the check did not recommend it; empty when recommended. */
  check: string
}

/** The /lessons checklist dialog: the lessons drawn when it opened, the ticked ids, the scope. */
export type LessonsDialog = {
  items: LessonItem[]
  ticks: string[]
  scope: 'project' | 'global'
  key: string
  status: string | null
}

declare module 'claude-code' {
  interface PluginState {
    lessons: { dialog: LessonsDialog }
  }
}
