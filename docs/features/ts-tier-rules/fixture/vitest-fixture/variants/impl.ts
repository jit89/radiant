// A correct implementation of the planned API, written for the fixture.
export interface DurationShape { hours: number; minutes: number; label?: string }

export class Duration implements DurationShape {
  hours: number;
  minutes: number;
  label?: string;
  constructor(hours: number, minutes: number, label?: string) {
    this.hours = hours;
    this.minutes = minutes;
    this.label = label;
  }
}

// "<h>h<m>m" or "<m>m" or "<h>h"; anything else throws "bad duration: <s>".
export function parseDuration(s: string): Duration {
  const m = /^(?:(\d+)h)?(?:(\d+)m)?$/.exec(s);
  if (!m || s === "") throw new Error(`bad duration: ${s}`);
  return new Duration(Number(m[1] ?? 0), Number(m[2] ?? 0));
}

export async function loadDuration(s: string): Promise<Duration> {
  return parseDuration(s);
}

// Each field times k; the label is kept (undefined when absent).
export function scale(d: Duration, k: number): Duration {
  return new Duration(d.hours * k, d.minutes * k, d.label);
}

// Total minutes of each duration, ascending (numeric order).
export function sortMinutes(ds: Duration[]): number[] {
  return ds.map((d) => d.hours * 60 + d.minutes).sort((a, b) => a - b);
}

// Width of a label in code points (an emoji counts once).
export function labelWidth(label: string): number {
  return [...label].length;
}

// Milliseconds at the start of the given calendar day, local time.
export function dayStartMs(isoDate: string): number {
  const [y, mo, d] = isoDate.split("-").map(Number);
  return new Date(y, mo - 1, d).getTime();
}
