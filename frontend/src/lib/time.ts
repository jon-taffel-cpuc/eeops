// Time helpers for the Consumption page. Everything is shown in the meters' time
// zone (Pacific), matching the server's day/month buckets
// (eeops/interval_data.py METER_TZ), whatever the viewer's browser is set to.

import type { Resolution } from './api';

export const METER_TZ = 'America/Los_Angeles';
export const HOUR_MS = 3_600_000;
export const DAY_MS = 86_400_000;

export type Wall = { y: number; m: number; d: number; h: number; mi: number }; // m = 1..12

const partsFmt = new Intl.DateTimeFormat('en-US', {
  timeZone: METER_TZ, hourCycle: 'h23',
  year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric',
});

export function toWall(ms: number): Wall {
  const p: Record<string, number> = {};
  for (const part of partsFmt.formatToParts(ms)) {
    if (part.type !== 'literal') p[part.type] = Number(part.value);
  }
  return { y: p.year, m: p.month, d: p.day, h: p.hour % 24, mi: p.minute };
}

function offsetAt(ms: number): number {
  const w = toWall(ms);
  const floored = Math.floor(ms / 60_000) * 60_000;
  return Date.UTC(w.y, w.m - 1, w.d, w.h, w.mi) - floored;
}

/** Pacific wall-clock time -> epoch ms (Date.UTC-style overflow is fine: d=32 rolls over). */
export function fromWall(y: number, m: number, d = 1, h = 0, mi = 0): number {
  const guess = Date.UTC(y, m - 1, d, h, mi);
  const first = guess - offsetAt(guess);
  return guess - offsetAt(first);
}

/** 'YYYY-MM-DD' (Pacific date) for <input type="date">. */
export function toDateInput(ms: number): string {
  const w = toWall(ms);
  return `${w.y}-${String(w.m).padStart(2, '0')}-${String(w.d).padStart(2, '0')}`;
}

/** <input type="date"> value -> Pacific midnight starting that day. */
export function fromDateInput(value: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  return m ? fromWall(Number(m[1]), Number(m[2]), Number(m[3])) : null;
}

// --- formatting --------------------------------------------------------------
function fmt(opts: Intl.DateTimeFormatOptions): Intl.DateTimeFormat {
  return new Intl.DateTimeFormat('en-US', { timeZone: METER_TZ, ...opts });
}
const F = {
  minute: fmt({ month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit', timeZoneName: 'short' }),
  hour: fmt({ weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', timeZoneName: 'short' }),
  day: fmt({ weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' }),
  month: fmt({ month: 'long', year: 'numeric' }),
  date: fmt({ month: 'short', day: 'numeric', year: 'numeric' }),
  tickTime: fmt({ hour: 'numeric', minute: '2-digit' }),
  tickHour: fmt({ hour: 'numeric' }),
  tickDay: fmt({ month: 'short', day: 'numeric' }),
  tickMonth: fmt({ month: 'short' }),
  tickMonthYear: fmt({ month: 'short', year: 'numeric' }),
  tickYear: fmt({ year: 'numeric' }),
};

/** Tooltip label for a point. Raw points are stamped at the interval END. */
export function formatBucket(t: number, resolution: Resolution): string {
  switch (resolution) {
    case 'interval': return `Interval ending ${F.minute.format(t)}`;
    case 'hour': return F.hour.format(t);
    case 'day': return F.day.format(t);
    case 'month': return F.month.format(t);
  }
}

export function formatDate(ms: number | string | null | undefined): string {
  if (ms === null || ms === undefined) return '—';
  return F.date.format(typeof ms === 'string' ? new Date(ms) : ms);
}

// --- axis ticks -------------------------------------------------------------
type Step = { unit: 'minute' | 'hour' | 'day' | 'month'; n: number; approx: number };
const STEPS: Step[] = [
  { unit: 'minute', n: 15, approx: 15 * 60_000 },
  { unit: 'minute', n: 30, approx: 30 * 60_000 },
  { unit: 'hour', n: 1, approx: HOUR_MS },
  { unit: 'hour', n: 3, approx: 3 * HOUR_MS },
  { unit: 'hour', n: 6, approx: 6 * HOUR_MS },
  { unit: 'hour', n: 12, approx: 12 * HOUR_MS },
  { unit: 'day', n: 1, approx: DAY_MS },
  { unit: 'day', n: 2, approx: 2 * DAY_MS },
  { unit: 'day', n: 7, approx: 7 * DAY_MS },
  { unit: 'month', n: 1, approx: 30.4 * DAY_MS },
  { unit: 'month', n: 3, approx: 91 * DAY_MS },
  { unit: 'month', n: 6, approx: 182 * DAY_MS },
  { unit: 'month', n: 12, approx: 365 * DAY_MS },
  { unit: 'month', n: 24, approx: 730 * DAY_MS },
];

export type Tick = { t: number; label: string };

/** Pacific-aligned ticks (local midnights, month starts, ...) for [start, end]. */
export function timeTicks(start: number, end: number, maxTicks: number): Tick[] {
  const span = end - start;
  const step = STEPS.find((s) => span / s.approx <= maxTicks) ?? STEPS[STEPS.length - 1];
  const ticks: Tick[] = [];
  if (step.unit === 'minute' || step.unit === 'hour') {
    // Pacific offsets are whole hours, so local quarter-hours/hours are UTC ones.
    const unitMs = step.unit === 'minute' ? 60_000 : HOUR_MS;
    const base = step.unit === 'minute' ? step.n * unitMs : HOUR_MS;
    for (let t = Math.ceil(start / base) * base; t <= end; t += base) {
      const w = toWall(t);
      if (step.unit === 'hour' && w.h % step.n !== 0) continue;
      const midnight = w.h === 0 && w.mi === 0;
      const label = midnight ? F.tickDay.format(t) : step.unit === 'minute' ? F.tickTime.format(t) : F.tickHour.format(t);
      ticks.push({ t, label });
    }
    return ticks;
  }
  const w0 = toWall(start);
  if (step.unit === 'day') {
    for (let i = 0; i < 400; i++) {
      const t = fromWall(w0.y, w0.m, w0.d + i);
      if (t > end) break;
      const w = toWall(t);
      if (t < start || (step.n === 7 ? (w.d - 1) % 7 !== 0 || w.d > 22 : (w.d - 1) % step.n !== 0)) continue;
      ticks.push({ t, label: w.m === 1 && w.d === 1 ? F.tickMonthYear.format(t) : F.tickDay.format(t) });
    }
    return ticks;
  }
  for (let i = 0; i < 400; i++) {
    const t = fromWall(w0.y, w0.m + i, 1);
    if (t > end) break;
    const w = toWall(t);
    if (t < start || (w.y * 12 + w.m - 1) % step.n !== 0) continue;
    const label = step.n >= 12 ? F.tickYear.format(t)
      : w.m === 1 || ticks.length === 0 ? F.tickMonthYear.format(t) : F.tickMonth.format(t);
    ticks.push({ t, label });
  }
  return ticks;
}

// --- numbers ------------------------------------------------------------------
export function formatEnergy(v: number | null | undefined, unit = 'kWh'): string {
  if (v === null || v === undefined || Number.isNaN(v)) return '—';
  const abs = Math.abs(v);
  const digits = abs >= 1000 ? 0 : abs >= 100 ? 1 : abs >= 1 ? 2 : 3;
  return `${v.toLocaleString('en-US', { maximumFractionDigits: digits, minimumFractionDigits: 0 })} ${unit}`;
}

/** 0 -> 1, 3.7 -> 4, 12 -> 15, 0.083 -> 0.1: a round upper bound for an axis. */
export function niceCeil(v: number): number {
  if (!(v > 0)) return 1;
  const pow = 10 ** Math.floor(Math.log10(v));
  const f = v / pow;
  const nice = f <= 1 ? 1 : f <= 1.5 ? 1.5 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 3 ? 3 : f <= 4 ? 4 : f <= 5 ? 5 : f <= 6 ? 6 : f <= 8 ? 8 : 10;
  return nice * pow;
}
