// The planned API, every body a trap (Tier 1 stub).
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

export function parseDuration(s: string): Duration {
  throw new Error("duration-trap");
}

export function loadDuration(s: string): Promise<Duration> {
  return Promise.reject(new Error("duration-trap"));
}

export function scale(d: Duration, k: number): Duration {
  throw new Error("duration-trap");
}

export function sortMinutes(ds: Duration[]): number[] {
  throw new Error("duration-trap");
}

export function labelWidth(label: string): number {
  throw new Error("duration-trap");
}

export function dayStartMs(isoDate: string): number {
  throw new Error("duration-trap");
}
