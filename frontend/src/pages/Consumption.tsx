import { useCallback, useEffect, useMemo, useState } from 'react';
import PageScaffold from '../components/PageScaffold';
import AddressSearch, { premiseLabel } from '../components/AddressSearch';
import LineChart from '../components/LineChart';
import { Icon } from '../components/Icon';
import {
  apiFetch,
  type IntervalStatus,
  type MeterInfo,
  type PremiseDetail,
  type PremiseHit,
  type Resolution,
  type SeriesResponse,
} from '../lib/api';
import { DAY_MS, HOUR_MS, formatBucket, formatDate, formatEnergy, fromDateInput, toDateInput } from '../lib/time';

// Consumption: pick a service address, see its energy use. Today that's AMI
// interval consumption (PG&E electric pilot); bills, gas and PRISM end-use
// splits will join it (see "Consumption Build Guide.md").
// Data comes from EE Ops' sorted copy of the Recurve share (see
// eeops/interval_data.py), so a premise's whole history is a few
// micro-partitions and any window comes back in about a second.
//
// PII: the selected premise is kept in component state only -- never in the
// URL, so it can't leak into browser history, bookmarks or proxy logs.

type TimeWindow = { start: number; end: number };
type ResolutionChoice = 'auto' | Resolution;

const MAX_RANGE_DAYS = 3700; // eeops/interval_data.py MAX_RANGE_DAYS
const MIN_ZOOM_MS = 2 * HOUR_MS;

const PRESETS: { key: string; label: string; days: number | null }[] = [
  { key: '7d', label: '7 days', days: 7 },
  { key: '30d', label: '30 days', days: 30 },
  { key: '90d', label: '90 days', days: 90 },
  { key: '1y', label: '1 year', days: 365 },
  { key: 'all', label: 'All', days: null },
];

const RESOLUTION_LABELS: Record<ResolutionChoice, string> = {
  auto: 'Auto',
  interval: 'Raw intervals',
  hour: 'Hourly',
  day: 'Daily',
  month: 'Monthly',
};

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

function presetWindow(detail: PremiseDetail, days: number | null): TimeWindow {
  const end = detail.data_end_ms ?? Date.now();
  const first = detail.data_start_ms ?? end - 365 * DAY_MS;
  const earliest = Math.max(first, end - MAX_RANGE_DAYS * DAY_MS);
  const start = days === null ? earliest : Math.max(earliest, end - days * DAY_MS);
  // Pad the start one interval back so the first interval end is included.
  return { start: Math.min(start, end - HOUR_MS) - 15 * 60_000, end };
}

function meterRange(m: MeterInfo): string {
  if (m.first_interval_ms === null || m.last_interval_ms === null) return 'No intervals';
  return `${formatDate(m.first_interval_ms)} – ${formatDate(m.last_interval_ms)}`;
}

function linkRange(m: MeterInfo): string {
  return `${formatDate(m.start_date)} – ${m.end_date ? formatDate(m.end_date) : 'present'}`;
}

function SourceStatus({ status, error }: { status: IntervalStatus | null; error: string | null }) {
  if (error) return <span className="tag badge-rose">Status unavailable</span>;
  if (!status) return <span className="tag badge-muted">Checking data…</span>;
  const src = status.sources.find((s) => s.key === status.default_source);
  if (!src?.loaded) return <span className="tag badge-amber">Not loaded yet</span>;
  return (
    <span className={`tag ${src.latest_status === 'FAILED' ? 'badge-amber' : 'badge-emerald'}`}>
      {src.label} · refreshed {formatDate(src.last_refresh)}
      {src.latest_status === 'FAILED' ? ' · last refresh failed' : ''}
    </span>
  );
}

function NotLoaded({ status }: { status: IntervalStatus }) {
  return (
    <section className="panel">
      <div className="empty-state">
        <div className="section-heading">Interval data hasn’t been loaded yet</div>
        <p className="section-copy narrow-copy center-copy">
          {status.tables_exist
            ? 'The EE Ops interval tables exist but the first load has not finished. Run deploy/sql/12_interval_initial_load.sql in Snowsight (sections A–C).'
            : 'Run deploy/sql/11_interval_tables.sql, then deploy/sql/12_interval_initial_load.sql, in Snowsight. The page reads EE Ops’ sorted copy of the Recurve share, never the share itself.'}
        </p>
      </div>
    </section>
  );
}

function Stat({ label, value, note }: { label: string; value: string; note?: string }) {
  return (
    <div className="stat-tile">
      <div className="detail-label">{label}</div>
      <div className="stat-value">{value}</div>
      {note ? <div className="tiny-copy">{note}</div> : null}
    </div>
  );
}

function SeriesStats({ series, range }: { series: SeriesResponse; range: TimeWindow }) {
  const t = series.totals;
  if (!t) return null;
  const days = Math.max(1, (range.end - range.start) / DAY_MS);
  const hasReturned = t.kwh_returned > 0;
  return (
    <div className="stats-grid">
      <Stat label="Delivered" value={formatEnergy(t.kwh, series.unit)} note={`${formatEnergy(t.kwh / days, series.unit)} per day on average`} />
      {hasReturned ? (
        <Stat label="Returned to grid" value={formatEnergy(t.kwh_returned, series.unit)}
          note={`Net ${formatEnergy(t.kwh - t.kwh_returned, series.unit)}`} />
      ) : null}
      <Stat label="Peak interval" value={formatEnergy(t.peak_interval_kwh, series.unit)}
        note={formatBucket(t.peak_bucket_ms, series.resolution)} />
      <Stat label="Intervals" value={t.intervals.toLocaleString()}
        note={t.estimated_share > 0 ? `${(t.estimated_share * 100).toFixed(1)}% estimated by the utility` : 'None estimated'} />
    </div>
  );
}

export default function Consumption() {
  const [status, setStatus] = useState<IntervalStatus | null>(null);
  const [statusError, setStatusError] = useState<string | null>(null);

  const [detail, setDetail] = useState<PremiseDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailError, setDetailError] = useState<string | null>(null);

  const [meterKey, setMeterKey] = useState<number | null>(null);
  const [win, setWin] = useState<TimeWindow | null>(null);
  const [preset, setPreset] = useState<string | null>('1y');
  const [zoomStack, setZoomStack] = useState<TimeWindow[]>([]);
  const [resolution, setResolution] = useState<ResolutionChoice>('auto');

  const [series, setSeries] = useState<SeriesResponse | null>(null);
  const [seriesLoading, setSeriesLoading] = useState(false);
  const [seriesError, setSeriesError] = useState<string | null>(null);

  const source = status?.default_source ?? 'pge_elec';

  useEffect(() => {
    apiFetch<IntervalStatus>('/interval/status')
      .then(setStatus)
      .catch((e: unknown) => setStatusError(message(e)));
  }, []);

  const openPremise = useCallback(async (hit: PremiseHit) => {
    setDetail(null);
    setSeries(null);
    setSeriesError(null);
    setDetailError(null);
    setDetailLoading(true);
    setMeterKey(null);
    setZoomStack([]);
    setResolution('auto');
    try {
      const qs = new URLSearchParams({ premise_id: hit.premise_id, source });
      const d = await apiFetch<PremiseDetail>(`/interval/premise?${qs}`);
      setDetail(d);
      setPreset('1y');
      setWin(presetWindow(d, 365));
    } catch (e) {
      setDetailError(message(e));
    } finally {
      setDetailLoading(false);
    }
  }, [source]);

  // Fetch the series whenever premise / meter / window / resolution change;
  // a newer request aborts the one in flight.
  useEffect(() => {
    if (!detail || !win) return;
    const ctrl = new AbortController();
    setSeriesLoading(true);
    setSeriesError(null);
    const qs = new URLSearchParams({
      premise_id: detail.premise.premise_id,
      start: String(Math.round(win.start)),
      end: String(Math.round(win.end)),
      resolution,
      source: detail.source,
    });
    if (meterKey !== null) qs.set('meter_key', String(meterKey));
    apiFetch<SeriesResponse>(`/interval/series?${qs}`, { signal: ctrl.signal })
      .then(setSeries)
      .catch((e: unknown) => { if (!ctrl.signal.aborted) setSeriesError(message(e)); })
      .finally(() => { if (!ctrl.signal.aborted) setSeriesLoading(false); });
    return () => ctrl.abort();
  }, [detail, win, resolution, meterKey]);

  function choosePreset(key: string, days: number | null) {
    if (!detail) return;
    setPreset(key);
    setZoomStack([]);
    setResolution('auto');
    setWin(presetWindow(detail, days));
  }

  function zoomTo(start: number, end: number) {
    if (!win) return;
    setZoomStack((s) => [...s, win]);
    setPreset(null);
    setResolution('auto');
    setWin({ start, end });
  }

  function zoomBack() {
    const prev = zoomStack[zoomStack.length - 1];
    if (!prev) return;
    setZoomStack(zoomStack.slice(0, -1));
    setPreset(null);
    setWin(prev);
  }

  function setCustom(which: 'start' | 'end', value: string) {
    const ms = fromDateInput(value);
    if (ms === null || !win) return;
    setPreset(null);
    setZoomStack([]);
    // End date is inclusive: the window runs to midnight after it.
    setWin(which === 'start' ? { start: ms, end: win.end } : { start: win.start, end: ms + DAY_MS });
  }

  const loaded = status?.sources.find((s) => s.key === source)?.loaded ?? false;
  const selectedMeter = useMemo(
    () => detail?.meters.find((m) => m.meter_key === meterKey) ?? null,
    [detail, meterKey],
  );

  return (
    <PageScaffold page="consumption" actions={<SourceStatus status={status} error={statusError} />}>
      <div className="notice">
        Customer data (PII). Addresses and consumption are for CPUC Energy Division work only. Every premise
        you open is logged with your Snowflake user name.
      </div>

      {status && !loaded ? <NotLoaded status={status} /> : null}

      <section className="panel">
        <AddressSearch source={source} disabled={!!status && !loaded} onSelect={(hit) => void openPremise(hit)} />
      </section>

      {detailLoading ? (
        <section className="panel loading-panel">
          <div className="loading-bar"><span /></div>
        </section>
      ) : null}
      {detailError ? <pre className="error-block">{detailError}</pre> : null}

      {detail ? (
        <section className="panel panel-padless">
          <div className="panel-header">
            <div>
              <h2 className="panel-title">{premiseLabel(detail.premise)}</h2>
              <p className="section-copy tiny-copy">
                {detail.source_label} · {detail.meters.length} meter{detail.meters.length === 1 ? '' : 's'} · data{' '}
                {formatDate(detail.data_start_ms)} – {formatDate(detail.data_end_ms)}
              </p>
            </div>
            <label className="inline-field">
              <span className="detail-label">Meter</span>
              <select
                className="field-select"
                value={meterKey ?? ''}
                onChange={(e) => setMeterKey(e.target.value === '' ? null : Number(e.target.value))}
              >
                <option value="">All meters (summed)</option>
                {detail.meters.map((m) => (
                  <option key={m.meter_key} value={m.meter_key}>
                    Meter {m.meter_label} · {m.energy_type ?? '—'} · {linkRange(m)}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <div className="table-panel">
            <table className="data-table compact-table">
              <thead>
                <tr>
                  <th>Meter</th>
                  <th>Service point</th>
                  <th>Type</th>
                  <th>Linked to premise</th>
                  <th>Interval data</th>
                  <th className="num">Intervals</th>
                </tr>
              </thead>
              <tbody>
                {detail.meters.map((m) => (
                  <tr key={m.meter_key} className={m.meter_key === meterKey ? 'is-selected' : undefined}>
                    <td className="mono-cell">{m.meter_label ?? '—'}</td>
                    <td className="mono-cell">{m.service_point_label ?? '—'}</td>
                    <td>{m.energy_type ?? '—'}</td>
                    <td>{linkRange(m)}</td>
                    <td>{meterRange(m)}</td>
                    <td className="num">{m.interval_rows.toLocaleString()}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      ) : null}

      {detail && win ? (
        <section className="panel panel-padless">
          <div className="panel-header chart-toolbar">
            <div className="segmented" role="group" aria-label="Time window">
              {PRESETS.map((p) => (
                <button key={p.key} type="button" className={preset === p.key ? 'is-active' : undefined}
                  onClick={() => choosePreset(p.key, p.days)}>
                  {p.label}
                </button>
              ))}
            </div>
            <div className="toolbar-row toolbar-wrap">
              <label className="inline-field">
                <span className="detail-label">From</span>
                <input type="date" className="field-date" value={toDateInput(win.start)}
                  onChange={(e) => setCustom('start', e.target.value)} />
              </label>
              <label className="inline-field">
                <span className="detail-label">To</span>
                <input type="date" className="field-date" value={toDateInput(win.end - 1)}
                  onChange={(e) => setCustom('end', e.target.value)} />
              </label>
              <label className="inline-field">
                <span className="detail-label">Resolution</span>
                <select className="field-select" value={resolution}
                  onChange={(e) => setResolution(e.target.value as ResolutionChoice)}>
                  {(Object.keys(RESOLUTION_LABELS) as ResolutionChoice[]).map((r) => (
                    <option key={r} value={r}>
                      {r === 'auto' && series && resolution === 'auto'
                        ? `Auto (${RESOLUTION_LABELS[series.resolution].toLowerCase()})`
                        : RESOLUTION_LABELS[r]}
                    </option>
                  ))}
                </select>
              </label>
              {zoomStack.length ? (
                <button type="button" className="button button-secondary button-small" onClick={zoomBack}>
                  Zoom out
                </button>
              ) : null}
            </div>
          </div>
          <div className="panel-body page-stack">
            {seriesError ? <pre className="error-block">{seriesError}</pre> : null}
            <div className={`chart-frame${seriesLoading ? ' is-loading' : ''}`}>
              <LineChart
                points={series?.points ?? []}
                start={win.start}
                end={win.end}
                resolution={series?.resolution ?? 'day'}
                unit={series?.unit ?? detail.unit}
                unitLabel={series?.unit_label ?? detail.unit}
                onZoom={zoomTo}
                minZoomMs={MIN_ZOOM_MS}
              />
              {seriesLoading ? (
                <div className="chart-overlay"><Icon name="refresh" /> Loading intervals…</div>
              ) : null}
            </div>
            {series ? <SeriesStats series={series} range={win} /> : null}
            <p className="tiny-copy">
              {selectedMeter ? `Meter ${selectedMeter.meter_label} only.` : 'All of the premise’s meters, summed per interval.'}{' '}
              Times are Pacific. Where Recurve restaged an interval, the latest version is used. Gaps in the line
              are missing intervals.
            </p>
          </div>
        </section>
      ) : null}
    </PageScaffold>
  );
}
