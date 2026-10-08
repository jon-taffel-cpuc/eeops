import { useEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react';
import type { Resolution, SeriesPoint } from '../lib/api';
import { formatBucket, formatEnergy, niceCeil, timeTicks } from '../lib/time';

// Dependency-free SVG line chart for the Consumption page (no chart library: the
// deploy builds from the committed lockfile, and SVG is CSP-safe). Up to
// ~10,000 points: one <path> per series, gaps break the line, hover shows a
// readout, and dragging across the plot zooms (onZoom) -- the page then
// re-queries at a finer resolution.

type Props = {
  points: SeriesPoint[];
  start: number;
  end: number;
  resolution: Resolution;
  unit: string;
  unitLabel: string;
  onZoom?: (start: number, end: number) => void;
  minZoomMs?: number;
};

const HEIGHT = 340;
const M = { top: 16, right: 20, bottom: 32, left: 64 };

/** Index of the point whose t is closest to `t` (points sorted by t). */
function nearest(points: SeriesPoint[], t: number): number {
  let lo = 0;
  let hi = points.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (points[mid].t < t) lo = mid;
    else hi = mid;
  }
  return Math.abs(points[lo].t - t) <= Math.abs(points[hi].t - t) ? lo : hi;
}

/** Typical spacing between points; a jump of 2.5x this is drawn as a gap. */
function typicalStep(points: SeriesPoint[]): number {
  if (points.length < 2) return Infinity;
  const diffs: number[] = [];
  for (let i = 1; i < points.length; i++) diffs.push(points[i].t - points[i - 1].t);
  diffs.sort((a, b) => a - b);
  return diffs[diffs.length >> 1];
}

export default function LineChart({ points, start, end, resolution, unit, unitLabel, onZoom, minZoomMs = 0 }: Props) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const svgRef = useRef<SVGSVGElement>(null);
  const [width, setWidth] = useState(900);
  const [hover, setHover] = useState<number | null>(null);
  const [drag, setDrag] = useState<{ x0: number; x1: number } | null>(null);

  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      const w = entries[0]?.contentRect.width;
      if (w) setWidth(Math.max(320, Math.floor(w)));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useEffect(() => setHover(null), [points]);

  const innerW = width - M.left - M.right;
  const innerH = HEIGHT - M.top - M.bottom;
  const span = Math.max(1, end - start);
  const xOf = (t: number) => M.left + ((t - start) / span) * innerW;
  const tOf = (px: number) => start + ((px - M.left) / innerW) * span;

  const showReturned = useMemo(() => points.some((p) => (p.kwh_returned ?? 0) > 0), [points]);

  const yAxis = useMemo(() => {
    let max = 0;
    for (const p of points) {
      max = Math.max(max, p.kwh ?? 0, showReturned ? p.kwh_returned ?? 0 : 0);
    }
    const step = niceCeil((max || 1) / 4);
    const top = step * Math.max(1, Math.ceil(max / step));
    const ticks: number[] = [];
    for (let v = 0; v <= top + step / 2; v += step) ticks.push(v);
    return { top, ticks };
  }, [points, showReturned]);

  const yOf = (v: number) => M.top + innerH - (v / yAxis.top) * innerH;

  const paths = useMemo(() => {
    const gap = typicalStep(points) * 2.5;
    const base = M.top + innerH;
    const line = (pick: (p: SeriesPoint) => number | null) => {
      let d = '';
      let prev: number | null = null;
      for (const p of points) {
        const v = pick(p);
        if (v === null) { prev = null; continue; }
        const cmd = prev === null || p.t - prev > gap ? 'M' : 'L';
        d += `${cmd}${xOf(p.t).toFixed(1)},${yOf(v).toFixed(1)}`;
        // a lone point still shows: zero-length segment + round cap
        if (cmd === 'M') d += 'h0.01';
        prev = p.t;
      }
      return d;
    };
    const area = () => {
      let d = '';
      let seg: string[] = [];
      let segX0 = 0;
      let segX1 = 0;
      let prev: number | null = null;
      const flush = () => {
        if (seg.length > 1) d += `M${segX0.toFixed(1)},${base}L${seg.join('L')}L${segX1.toFixed(1)},${base}Z`;
        seg = [];
      };
      for (const p of points) {
        if (p.kwh === null) { flush(); prev = null; continue; }
        if (prev !== null && p.t - prev > gap) flush();
        const x = xOf(p.t);
        if (seg.length === 0) segX0 = x;
        segX1 = x;
        seg.push(`${x.toFixed(1)},${yOf(p.kwh).toFixed(1)}`);
        prev = p.t;
      }
      flush();
      return d;
    };
    return {
      delivered: line((p) => p.kwh),
      area: area(),
      returned: showReturned ? line((p) => p.kwh_returned) : '',
    };
    // xOf / yOf are pure functions of width, start, end and yAxis (all deps).
  }, [points, width, start, end, yAxis, showReturned, innerH]);

  const xTicks = useMemo(() => timeTicks(start, end, Math.max(2, Math.floor(innerW / 95))), [start, end, innerW]);

  function localX(e: ReactPointerEvent<SVGSVGElement>): number {
    const r = svgRef.current?.getBoundingClientRect();
    const px = r ? e.clientX - r.left : 0;
    return Math.min(M.left + innerW, Math.max(M.left, px));
  }

  function onPointerDown(e: ReactPointerEvent<SVGSVGElement>) {
    if (e.button !== 0 || !onZoom) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    const x = localX(e);
    setDrag({ x0: x, x1: x });
  }

  function onPointerMove(e: ReactPointerEvent<SVGSVGElement>) {
    const x = localX(e);
    if (drag) setDrag({ ...drag, x1: x });
    if (points.length) setHover(nearest(points, tOf(x)));
  }

  function onPointerUp() {
    if (drag && onZoom && Math.abs(drag.x1 - drag.x0) > 6) {
      const t0 = Math.round(tOf(Math.min(drag.x0, drag.x1)));
      const t1 = Math.round(tOf(Math.max(drag.x0, drag.x1)));
      if (t1 - t0 >= minZoomMs) onZoom(t0, t1);
      else {
        const mid = (t0 + t1) / 2;
        onZoom(Math.round(mid - minZoomMs / 2), Math.round(mid + minZoomMs / 2));
      }
    }
    setDrag(null);
  }

  const hp = hover !== null ? points[hover] : null;
  const tip = useMemo(() => {
    if (!hp) return null;
    const lines = [formatBucket(hp.t, resolution), `Delivered: ${formatEnergy(hp.kwh, unit)}`];
    if (showReturned) lines.push(`Returned: ${formatEnergy(hp.kwh_returned, unit)}`);
    if (resolution !== 'interval' && hp.peak !== null) lines.push(`Peak interval: ${formatEnergy(hp.peak, unit)}`);
    if (hp.n_est > 0) lines.push(`${hp.n_est.toLocaleString()} of ${hp.n.toLocaleString()} intervals estimated`);
    const w = Math.max(...lines.map((l) => l.length)) * 6.6 + 20;
    const h = lines.length * 17 + 12;
    const px = xOf(hp.t);
    const right = width - M.right;
    const x = px + 14 + w <= right ? px + 14 : Math.max(M.left, px - 14 - w);
    return { lines, w, h, x, y: M.top + 6 };
  }, [hp, resolution, unit, showReturned, width, start, end]);

  const first = points[0];
  const label = `${unitLabel} line chart, ${points.length.toLocaleString()} points` +
    (first ? ` from ${formatBucket(first.t, resolution)}` : '');

  return (
    <div className="chart-shell" ref={wrapRef}>
      <div className="chart-legend">
        <span><span className="legend-swatch legend-delivered" />Delivered ({unitLabel})</span>
        {showReturned ? <span><span className="legend-swatch legend-returned" />Returned to grid</span> : null}
        {onZoom ? <span className="chart-hint">Drag across the chart to zoom in</span> : null}
      </div>
      <svg
        ref={svgRef}
        className="chart-svg"
        width={width}
        height={HEIGHT}
        viewBox={`0 0 ${width} ${HEIGHT}`}
        role="img"
        aria-label={label}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerLeave={() => { if (!drag) setHover(null); }}
      >
        <g className="chart-grid">
          {yAxis.ticks.map((v) => (
            <line key={v} x1={M.left} x2={M.left + innerW} y1={yOf(v)} y2={yOf(v)} />
          ))}
        </g>
        <g className="chart-axis">
          {yAxis.ticks.map((v) => (
            <text key={v} x={M.left - 8} y={yOf(v) + 4} textAnchor="end">
              {v.toLocaleString('en-US', { maximumFractionDigits: 3 })}
            </text>
          ))}
          <text className="chart-axis-title" transform={`translate(14 ${M.top + innerH / 2}) rotate(-90)`} textAnchor="middle">
            {unitLabel}
          </text>
          {xTicks.map((tk) => (
            <g key={tk.t}>
              <line className="chart-tick" x1={xOf(tk.t)} x2={xOf(tk.t)} y1={M.top + innerH} y2={M.top + innerH + 5} />
              <text x={xOf(tk.t)} y={M.top + innerH + 20} textAnchor="middle">{tk.label}</text>
            </g>
          ))}
          <line className="chart-baseline" x1={M.left} x2={M.left + innerW} y1={M.top + innerH} y2={M.top + innerH} />
        </g>

        <path className="chart-area-delivered" d={paths.area} />
        <path className="chart-line-delivered" d={paths.delivered} />
        {paths.returned ? <path className="chart-line-returned" d={paths.returned} /> : null}

        {drag && Math.abs(drag.x1 - drag.x0) > 1 ? (
          <rect className="chart-brush" x={Math.min(drag.x0, drag.x1)} y={M.top}
            width={Math.abs(drag.x1 - drag.x0)} height={innerH} />
        ) : null}

        {hp && tip ? (
          <g className="chart-hover">
            <line className="chart-hover-line" x1={xOf(hp.t)} x2={xOf(hp.t)} y1={M.top} y2={M.top + innerH} />
            {hp.kwh !== null ? <circle className="chart-dot-delivered" cx={xOf(hp.t)} cy={yOf(hp.kwh)} r={3.5} /> : null}
            {showReturned && hp.kwh_returned !== null ? (
              <circle className="chart-dot-returned" cx={xOf(hp.t)} cy={yOf(hp.kwh_returned)} r={3.5} />
            ) : null}
            <g transform={`translate(${tip.x} ${tip.y})`}>
              <rect className="chart-tooltip" width={tip.w} height={tip.h} rx={4} />
              <text className="chart-tooltip-text">
                {tip.lines.map((l, i) => (
                  <tspan key={i} x={10} y={20 + i * 17} className={i === 0 ? 'chart-tooltip-title' : undefined}>{l}</tspan>
                ))}
              </text>
            </g>
          </g>
        ) : null}

        {points.length === 0 ? (
          <text className="chart-empty" x={M.left + innerW / 2} y={M.top + innerH / 2} textAnchor="middle">
            No intervals in this window
          </text>
        ) : null}
      </svg>
    </div>
  );
}
