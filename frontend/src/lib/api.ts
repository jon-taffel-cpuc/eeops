// EE Ops API client.
//
// Every call goes to the FastAPI backend on the same origin (/api/v1/...),
// which sits behind the Snowflake SPCS ingress: the browser is already signed
// in to Snowflake, so there are no keys or tokens here and no direct
// Snowflake calls from the browser.

const BASE = '/api/v1';

export class ApiError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

export async function apiFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, { credentials: 'same-origin', ...init });
  const text = await res.text();
  let body: unknown = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  if (!res.ok) {
    const detail =
      body && typeof body === 'object' && 'detail' in body
        ? String((body as { detail: unknown }).detail)
        : `HTTP ${res.status}`;
    throw new ApiError(detail, res.status);
  }
  return body as T;
}

export function postJson<T>(path: string, body: unknown): Promise<T> {
  return apiFetch<T>(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body ?? {}),
  });
}

export type Health = { status: string; version: string; frontend_version: string; time: number };
export type Me = { authenticated: boolean; user_id: string | null };
export type SnowflakeCheck = {
  ok: boolean;
  backend_version: string;
  session: Record<string, string | null>;
};

// --- Consumption page, interval data (api/routes/interval.py) ---------------------------------
export type Resolution = 'interval' | 'hour' | 'day' | 'month';

export type IntervalSourceStatus = {
  key: string;
  label: string;
  unit: string;
  loaded: boolean;
  last_refresh: string | null;
  latest_step: string | null;
  latest_status: string | null;
  latest_at: string | null;
};
export type IntervalStatus = {
  tables_exist: boolean;
  sources: IntervalSourceStatus[];
  default_source: string;
};

export type PremiseHit = {
  premise_id: string;
  address: string | null;
  city: string | null;
  zip: string | null;
  meter_count: number;
  last_interval: string | null;
};
export type PremiseSearch = { source: string; results: PremiseHit[] };

export type MeterInfo = {
  meter_key: number;
  meter_label: string | null;
  service_point_label: string | null;
  energy_type: string | null;
  start_date: string | null;
  end_date: string | null;
  first_interval_ms: number | null;
  last_interval_ms: number | null;
  interval_rows: number;
};
export type PremiseDetail = {
  source: string;
  source_label: string;
  unit: string;
  premise: PremiseHit;
  meters: MeterInfo[];
  data_start_ms: number | null;
  data_end_ms: number | null;
};

export type SeriesPoint = {
  t: number;
  kwh: number | null;
  kwh_returned: number | null;
  peak: number | null;
  n: number;
  n_est: number;
};
export type SeriesResponse = {
  source: string;
  premise_id: string;
  meter_keys: number[];
  start_ms: number;
  end_ms: number;
  resolution: Resolution;
  unit: string;
  unit_label: string;
  points: SeriesPoint[];
  totals: {
    kwh: number;
    kwh_returned: number;
    peak_interval_kwh: number | null;
    peak_bucket_ms: number;
    intervals: number;
    estimated_share: number;
  } | null;
};
