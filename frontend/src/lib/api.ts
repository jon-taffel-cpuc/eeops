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
