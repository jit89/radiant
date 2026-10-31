// The always-on push (docs/features/always-on/PLAN.md step 13): while a
// session is open, a new hold of an always-on entry becomes one
// PushNotification (Remote Control carries it to the phone), with the same
// fixed fields as the iMessage: the repo's name, the short entry id, the class
// and the reason code, and the command to run. Never stop text or findings.
// The state is read from `cw-decide.sh status --json`; the first read after
// the mod loads only seeds what it has seen, so old holds are not replayed.

export type AoHold = { class: string | null; reason: string | null; utc: string | null }
export type AoRow = { id: string; repo: string; status: string; hold: AoHold | null }

export type PushDeps = {
  status: () => Promise<AoRow[]>
  toolNames: () => Promise<string[]>
  call: (input: Record<string, unknown>) => Promise<unknown>
  log: (line: string) => void
}

const clean = (s: string | null | undefined, max = 40) =>
  (s ?? '').replace(/[^A-Za-z0-9 ._:/,$+=()#-]/g, '').slice(0, max)

/** A hold's identity: the entry and when it was held (a resume and a new hold differ). */
export const holdKey = (r: AoRow): string | null =>
  r.status === 'held' && r.hold ? `${r.id}@${r.hold.utc ?? ''}` : null

/** A reason code only: a stop's reason line is free text. */
const code = (s: string | null | undefined) =>
  !s ? '' : /^[a-z0-9_-]{1,40}$/.test(s) ? s : 'unlisted-reason'

/** The message, under 200 characters, fixed fields only. */
export const pushMessage = (r: AoRow): string =>
  `always-on: ${clean(r.repo)} (${clean(r.id, 12)}) held, class ${clean(r.hold?.class, 16)}: ` +
  `${code(r.hold?.reason)}. At the Mac: cw-decide.sh status`

/** The holds not yet seen; `seen` null is the first read (seed, notify none). */
export const newHolds = (seen: string[] | null, rows: AoRow[]): { notify: AoRow[]; seen: string[] } => {
  const keys = rows.map(r => [r, holdKey(r)] as const).filter((x): x is readonly [AoRow, string] => x[1] !== null)
  const now = keys.map(([, k]) => k)
  if (seen === null) return { notify: [], seen: now }
  return { notify: keys.filter(([, k]) => !seen.includes(k)).map(([r]) => r), seen: now }
}

/** One poll: read the state, push each new hold, keep what was seen. */
export const makePushPoller = (deps: PushDeps) => {
  let seen: string[] | null = null
  let warned = false
  return async () => {
    let rows: AoRow[]
    try {
      rows = await deps.status()
    } catch (error) {
      deps.log(`walk: always-on status failed: ${String(error)}`)
      return
    }
    const { notify, seen: next } = newHolds(seen, rows)
    seen = next
    if (notify.length === 0) return
    if (!(await deps.toolNames()).includes('PushNotification')) {
      if (!warned) deps.log('walk: no PushNotification tool in this session: always-on holds are not pushed')
      warned = true
      return
    }
    for (const r of notify) {
      try {
        await deps.call({ tool: 'PushNotification', message: pushMessage(r), status: 'proactive' })
      } catch (error) {
        deps.log(`walk: push failed: ${String(error)}`)
      }
    }
  }
}
