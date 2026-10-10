import type { WalkGoal, WalkGraph } from '../types'

// The /walk pane as lines of tinted parts, for a body `columns` cells wide.
// Pure, so the layout is tested without a surface.

export type Tone = 'head' | 'line' | 'id' | 'title' | 'detail' | 'note' | WalkGoal['state']
export type Part = { text: string; tone: Tone }
export type Line = { key: string; parts: Part[] }

export const LEGEND = '● done  ◉ running  ◐ paused  ○ ready  ◌ waiting  ✗ bounced'
// Cells right of the graph that hold an id, a title and the detail on one row;
// fewer and the pane is a sidebar: the id alone, the detail on a line beneath.
const WIDE = 56
// Below this many cells for the id, the graph is dropped for a flat list.
const MIN_ID = 8

export function clip(text: string, room: number): string {
  if (room <= 0) return ''
  return text.length > room ? `${text.slice(0, room - 1)}…` : text
}

export function fmtSecs(secs: number | null): string {
  if (!secs) return ''
  const h = Math.floor(secs / 3600)
  const m = Math.floor((secs % 3600) / 60)
  const s = Math.floor(secs % 60)
  return h ? `${h}h${String(m).padStart(2, '0')}m` : `${m}m${String(s).padStart(2, '0')}s`
}

/** `r2 · review · haiku · 11m08s · $0.17`, `waits g07,g11`, or `ready`. */
export function detail(g: WalkGoal): string {
  if (g.state === 'waiting') return `waits ${g.waits.join(',')}`
  if (g.state === 'ready') return 'ready'
  return parts(g).join(' · ')
}

// The detail's bits; the state's word only where the glyph is easy to miss.
function parts(g: WalkGoal): string[] {
  const bits = [
    g.state === 'paused' || g.state === 'bounced' ? g.state : '',
    g.round === null ? '' : `r${g.round}`,
    g.state === 'running' ? (g.phase ?? '') : '',
    g.model ? `${g.model}${g.fallback ? '*' : ''}` : '',
    fmtSecs(g.secs),
    g.cost === null ? '' : `$${g.cost.toFixed(2)}`,
  ]
  return bits.filter(Boolean)
}

/** The detail's bits packed into lines of at most `room` cells. */
function pack(bits: string[], room: number, sep = ' · '): string[] {
  const out: string[] = []
  for (const bit of bits) {
    const last = out.at(-1)
    if (last !== undefined && last.length + sep.length + bit.length <= room) out[out.length - 1] = `${last}${sep}${bit}`
    else out.push(clip(bit, room))
  }
  return out
}

function header(view: WalkGraph): string {
  const head = `${view.feature} · ${view.done}/${view.total} done`
  if (!view.running) return `${head} · idle`
  const round = view.round === null || view.round === undefined ? '' : ` r${view.round}`
  const more = view.others ? ` +${view.others}` : ''
  return `${head} · ${view.running}${round} · ${view.phase ?? 'running'}${more}`
}

export function paneLines(view: WalkGraph, columns: number, error: string | null = null): Line[] {
  const lines: Line[] = []
  if (error) lines.push({ key: 'error', parts: [{ text: clip(`walk: ${error}`, columns), tone: 'note' }] })
  if (!view.found) {
    lines.push({ key: 'none', parts: [{ text: clip(`No GOALS.md at or above ${view.dir}`, columns), tone: 'note' }] })
    return lines
  }
  const goals = view.goals ?? {}
  const rows = view.rows ?? []
  const width = view.width ?? 0
  const room = columns - width - 1
  const isFlat = room < MIN_ID
  const isWide = room >= WIDE
  const idWidth = Math.min(18, Math.max(0, ...Object.keys(goals).map(id => id.length)))

  lines.push({ key: 'head', parts: [{ text: clip(header(view), columns), tone: 'head' }] })
  rows.forEach((row, n) => {
    if (row.goal === undefined) {
      if (!isFlat) lines.push({ key: `fork:${n}`, parts: [{ text: row.graph, tone: 'line' }] })
      return
    }
    const id = row.goal
    const g = goals[id]
    if (!g) return
    const said = detail(g)
    const col = row.col ?? 0
    const glyph = row.graph.slice(col, col + 1)
    const idTone: Tone = g.state === 'waiting' ? 'detail' : 'id'
    if (isFlat) {
      const tail = columns - 2 - id.length
      lines.push({
        key: `goal:${id}`,
        parts: [
          { text: glyph, tone: g.state },
          { text: ` ${clip(id, columns - 2)}`, tone: idTone },
          { text: tail >= MIN_ID ? clip(`  ${said}`, tail) : '', tone: 'detail' },
        ],
      })
      return
    }
    const graph: Part[] = [
      { text: row.graph.slice(0, col), tone: 'line' },
      { text: glyph, tone: g.state },
      { text: `${row.graph.slice(col + 1).padEnd(width - col - 1)} `, tone: 'line' },
    ]
    if (isWide) {
      const rest = room - idWidth - 2
      const titleWidth = Math.max(0, Math.min(28, rest - 26))
      const title = titleWidth >= 8 ? `${clip(g.title, titleWidth).padEnd(titleWidth)}  ` : ''
      lines.push({
        key: `goal:${id}`,
        parts: [
          ...graph,
          { text: `${clip(id, idWidth).padEnd(idWidth)}  `, tone: idTone },
          { text: title, tone: 'title' },
          { text: clip(said, rest - title.length), tone: 'detail' },
        ],
      })
      return
    }
    // A sidebar: the id, and the detail beside it when it fits, else beneath.
    const inline = id.length + 2 + said.length <= room
    lines.push({
      key: `goal:${id}`,
      parts: [
        ...graph,
        { text: clip(id, room), tone: idTone },
        { text: inline ? `  ${said}` : '', tone: 'detail' },
      ],
    })
    if (!inline && ['running', 'paused', 'bounced'].includes(g.state)) {
      pack(parts(g), room).forEach((text, k) => {
        lines.push({
          key: k ? `detail:${id}:${k}` : `detail:${id}`,
          parts: [
            { text: `${(row.cont ?? '').padEnd(width)} `, tone: 'line' },
            { text, tone: 'detail' },
          ],
        })
      })
    }
  })
  pack(LEGEND.split('  '), columns, '  ').forEach((text, k) => {
    lines.push({ key: k ? `legend:${k}` : 'legend', parts: [{ text, tone: 'detail' }] })
  })
  return lines
}
