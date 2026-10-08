"""
Interval data -- address search and AMI interval consumption for the
Interval page.

Requests NEVER read the Recurve share (EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC)
directly. Its RECURVE_ELEC_CONSUMPTION_INTERVAL_PGE (~449 B rows, ~6 TB) is
unclustered -- every micro-partition spans nearly every meter and date -- so
even "one meter, one day" scans all of it. Instead the API reads EE Ops'
copies, built by deploy/sql/11_interval_tables.sql (EEOPS_REFRESH_PGE_INTERVAL):

    EEOPS_PGE_PREMISE         address search index, one row per premise with data
    EEOPS_PGE_PREMISE_METER   premise -> METER_KEY links (sorted by PREMISEID)
    EEOPS_PGE_METER           METER_KEY <-> METERID, energy type, data range
    EEOPS_PGE_ELEC_INTERVAL   intervals, physically sorted by (METER_KEY, INTERVALENDTIME)

Join path (resolved at refresh time, not per request):
    RECURVE_PREMISE --PREMISEID--> RECURVE_ID_RELATIONS --METERID-->
    RECURVE_ELEC_CONSUMPTION_INTERVAL_PGE (+ RECURVE_METER.ENERGYTYPE)

Query rules that keep "one premise, one year of 15-minute data" at ~1-3
micro-partitions:
  * filter the interval table on METER_KEY IN (<integer literals>) -- bound
    constants, never a subquery/join, so pruning happens at compile time;
  * filter INTERVALENDTIME on the raw column (no function around it);
  * aggregate in Snowflake so the browser never gets more than MAX_POINTS.

Scope: PG&E electric (proof of concept). Gas / other IOUs: add a Source to
SOURCES plus its EEOPS_ tables and refresh procedure in deploy/sql/.

PII: addresses, meter IDs and consumption are customer data.
  * Raw METERID / SERVICEPOINTID never leave the server -- the browser gets
    METER_KEY (an EE Ops surrogate) and a masked label.
  * Every premise open and chart query is written to
    EEOPS_INTERVAL_ACCESS_LOG before data is returned (no log row, no data).
    Search text is never logged.

SQL safety: every request value is a bind parameter. Table names come from
code constants via get_config().fq(); DATE_TRUNC units from RESOLUTIONS.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Optional

from . import db
from .config import get_config


# --- Sources -----------------------------------------------------------------
@dataclass(frozen=True)
class Source:
    key: str            # API value
    label: str
    utility: str        # UTILITY in EEOPS_INTERVAL_REFRESH_LOG
    premise: str        # fq() stems of the EEOPS_ tables
    premise_meter: str
    meter: str
    interval: str
    unit: str


SOURCES: dict[str, Source] = {
    "pge_elec": Source(key="pge_elec", label="PG&E electric", utility="PGE",
                       premise="PGE_PREMISE", premise_meter="PGE_PREMISE_METER",
                       meter="PGE_METER", interval="PGE_ELEC_INTERVAL", unit="kWh"),
}
DEFAULT_SOURCE = "pge_elec"


def get_source(key: Optional[str]) -> Source:
    src = SOURCES.get(key or DEFAULT_SOURCE)
    if src is None:
        raise ValueError(f"Unknown interval source {key!r}. Available: {', '.join(SOURCES)}.")
    return src


# Meter time zone: day / month buckets align to local wall-clock time.
METER_TZ = "America/Los_Angeles"

# --- Limits ------------------------------------------------------------------
MIN_SEARCH_CHARS = 3
MAX_SEARCH_TOKENS = 10      # multi-unit addresses run 11-13 words; the unit is near the end
MAX_SEARCH_RESULTS = 25
MAX_METERS = 50
MAX_RANGE_DAYS = 3700       # ~10 years per request
MAX_POINTS = 10_000         # hard cap for an explicitly chosen resolution
AUTO_TARGET_POINTS = 2_000  # "auto" picks the finest resolution under this
SEARCH_TIMEOUT_S = 30
SERIES_TIMEOUT_S = 60

DAY_MS = 86_400_000

# name -> (DATE_TRUNC unit or None for raw intervals, time zone the bucket
# follows, approx points per day, label). Raw assumes 15-minute data (96/day)
# for the point cap; most PG&E meters are hourly (INTERVALENGTH 3600), so the
# cap is conservative for them. Hours bucket in UTC so the repeated 1 am on
# the DST fall-back day stays two hours, not one merged one.
RESOLUTIONS: dict[str, tuple[Optional[str], Optional[str], float, str]] = {
    "interval": (None, None, 96, "per interval"),
    "hour": ("hour", "UTC", 24, "per hour"),
    "day": ("day", METER_TZ, 1, "per day"),
    "month": ("month", METER_TZ, 1 / 30.4, "per month"),
}
RESOLUTION_ORDER = ["interval", "hour", "day", "month"]


# --- Address search ----------------------------------------------------------
_NON_ALNUM = re.compile(r"[^A-Z0-9]+")


def normalize(text: str) -> str:
    """Upper-case, every non-[A-Z0-9] run -> one space. Must match the
    SEARCH_TEXT expression in EEOPS_REFRESH_PGE_INTERVAL step 5."""
    return _NON_ALNUM.sub(" ", (text or "").upper()).strip()


def search_tokens(q: str) -> list[str]:
    """Typed address -> word tokens (A-Z0-9 only, so no LIKE wildcards can
    get through). Raises ValueError if there's too little to search on."""
    norm = normalize(q)
    if len(norm.replace(" ", "")) < MIN_SEARCH_CHARS:
        raise ValueError(f"Type at least {MIN_SEARCH_CHARS} letters or digits to search addresses.")
    tokens: list[str] = []
    for tok in norm.split(" "):
        tok = tok[:40]
        if tok not in tokens:
            tokens.append(tok)
    return tokens[:MAX_SEARCH_TOKENS]


def search_premises(source: Source, q: str, limit: int = 12) -> list[dict[str, Any]]:
    """Premises whose address has a word starting with every typed token
    (any order). '123 main' matches '123 MAIN ST' and '1234 MAINE AVE'.
    Ranking: most tokens matching a WHOLE word first (so 'SPC 12' beats
    'SPC 120'), then addresses starting with the first token. Ranking is
    ORDER BY only; WHERE stays a plain LIKE on SEARCH_TEXT."""
    tokens = search_tokens(q)
    limit = max(1, min(int(limit), MAX_SEARCH_RESULTS))
    params: dict[str, Any] = {"limit": limit, "lead": " " + tokens[0] + "%"}
    where, exact = [], []
    for i, tok in enumerate(tokens):
        params[f"t{i}"] = "% " + tok + "%"
        params[f"w{i}"] = "% " + tok + " %"
        where.append(f"SEARCH_TEXT LIKE %(t{i})s")
        exact.append(f"IFF(SEARCH_TEXT || ' ' LIKE %(w{i})s, 1, 0)")
    sql = f"""
        SELECT PREMISEID AS premise_id, FULLADDRESS AS address, CITY AS city,
               ZIPCODE5 AS zip, METER_COUNT AS meter_count, LAST_INTERVAL AS last_interval
        FROM {get_config().fq(source.premise)}
        WHERE {' AND '.join(where)}
        ORDER BY {' + '.join(exact)} DESC, IFF(SEARCH_TEXT LIKE %(lead)s, 0, 1), FULLADDRESS, CITY
        LIMIT %(limit)s
    """
    rows = db.query(sql, params, timeout=SEARCH_TIMEOUT_S)
    return [_premise_out(r) for r in rows]


def _premise_out(r: dict[str, Any]) -> dict[str, Any]:
    return {"premise_id": str(r["premise_id"]),
            "address": r["address"], "city": r["city"], "zip": r["zip"],
            "meter_count": int(r["meter_count"] or 0),
            "last_interval": _iso(r["last_interval"])}


# --- Premise + meters --------------------------------------------------------
class PremiseNotFound(Exception):
    """The premise isn't in the EE Ops index (route -> 404)."""


def _iso(v: Any) -> Optional[str]:
    return v.isoformat() if v is not None else None


def _ms(v: Any) -> Optional[int]:
    return int(v.timestamp() * 1000) if v is not None else None


def mask_id(value: Any) -> Optional[str]:
    """'1234567890' -> '•••7890'. Enough to tell a premise's meters apart."""
    if value is None:
        return None
    s = str(value)
    return "•••" + s[-4:] if len(s) > 4 else "•••"


def log_access(source: Source, user_id: str, action: str, premise_id: str,
               detail: Optional[str] = None) -> None:
    db.execute(
        f"INSERT INTO {get_config().fq('INTERVAL_ACCESS_LOG')} "
        "(USER_NAME, SOURCE, ACTION, PREMISEID, DETAIL, ACCESSED_AT) "
        "SELECT %(user)s, %(source)s, %(action)s, %(premise_id)s, %(detail)s, CURRENT_TIMESTAMP()",
        {"user": user_id, "source": source.key, "action": action,
         "premise_id": premise_id, "detail": detail})


def _meter_rows(source: Source, premise_id: str) -> list[dict[str, Any]]:
    cfg = get_config()
    sql = f"""
        SELECT x.METER_KEY AS meter_key, k.METERID AS meter_id,
               x.SERVICEPOINTID AS service_point_id, k.ENERGYTYPE AS energy_type,
               x.START_DATE AS start_date, x.END_DATE AS end_date,
               k.FIRST_INTERVAL AS first_interval, k.LAST_INTERVAL AS last_interval,
               k.INTERVAL_ROWS AS interval_rows
        FROM {cfg.fq(source.premise_meter)} x
        JOIN {cfg.fq(source.meter)} k ON k.METER_KEY = x.METER_KEY
        WHERE x.PREMISEID = %(premise_id)s
        ORDER BY x.END_DATE DESC NULLS FIRST, x.START_DATE DESC
        LIMIT {MAX_METERS}
    """
    return db.query(sql, {"premise_id": premise_id}, timeout=SEARCH_TIMEOUT_S)


def premise_detail(source: Source, premise_id: str, user_id: str) -> dict[str, Any]:
    """Address + meters for one premise. Logs the access first."""
    if not premise_id or len(premise_id) > 100:
        raise ValueError("A premise must be selected.")
    log_access(source, user_id, "premise", premise_id)
    rows = db.query(f"""
        SELECT PREMISEID AS premise_id, FULLADDRESS AS address, CITY AS city,
               ZIPCODE5 AS zip, METER_COUNT AS meter_count, LAST_INTERVAL AS last_interval
        FROM {get_config().fq(source.premise)}
        WHERE PREMISEID = %(premise_id)s
        LIMIT 1""", {"premise_id": premise_id}, timeout=SEARCH_TIMEOUT_S)
    if not rows:
        raise PremiseNotFound("That premise has no interval data in EE Ops.")
    meters = [{"meter_key": int(r["meter_key"]),
               "meter_label": mask_id(r["meter_id"]),
               "service_point_label": mask_id(r["service_point_id"]),
               "energy_type": r["energy_type"],
               "start_date": _iso(r["start_date"]),
               "end_date": _iso(r["end_date"]),
               "first_interval_ms": _ms(r["first_interval"]),
               "last_interval_ms": _ms(r["last_interval"]),
               "interval_rows": int(r["interval_rows"] or 0)}
              for r in _meter_rows(source, premise_id)]
    firsts = [m["first_interval_ms"] for m in meters if m["first_interval_ms"] is not None]
    lasts = [m["last_interval_ms"] for m in meters if m["last_interval_ms"] is not None]
    return {"source": source.key, "source_label": source.label, "unit": source.unit,
            "premise": _premise_out(rows[0]), "meters": meters,
            "data_start_ms": min(firsts) if firsts else None,
            "data_end_ms": max(lasts) if lasts else None}


# --- Interval series ---------------------------------------------------------
def validate_window(start_ms: int, end_ms: int) -> None:
    if end_ms <= start_ms:
        raise ValueError("The end of the time window must be after its start.")
    if end_ms - start_ms > MAX_RANGE_DAYS * DAY_MS:
        raise ValueError(f"The time window is limited to {MAX_RANGE_DAYS} days per request.")


def estimated_points(resolution: str, start_ms: int, end_ms: int) -> int:
    return int((end_ms - start_ms) / DAY_MS * RESOLUTIONS[resolution][2]) + 1


def choose_resolution(start_ms: int, end_ms: int, requested: str = "auto") -> str:
    """'auto' -> finest resolution under AUTO_TARGET_POINTS; an explicit one
    is honoured unless it would exceed MAX_POINTS."""
    if requested == "auto":
        for res in RESOLUTION_ORDER:
            if estimated_points(res, start_ms, end_ms) <= AUTO_TARGET_POINTS:
                return res
        return RESOLUTION_ORDER[-1]
    if requested not in RESOLUTIONS:
        raise ValueError(f"Resolution must be auto or one of {', '.join(RESOLUTION_ORDER)}.")
    if estimated_points(requested, start_ms, end_ms) > MAX_POINTS:
        raise ValueError(f"'{requested}' resolution over this window would be more than "
                         f"{MAX_POINTS:,} points -- shorten the window or pick a coarser resolution.")
    return requested


def build_series_sql(source: Source, meter_keys: list[int], resolution: str) -> tuple[str, dict[str, Any]]:
    """SQL + binds for one premise's series. Kept separate so tests can check
    the pruning-critical shape without Snowflake."""
    trunc_unit, bucket_tz, _, _ = RESOLUTIONS[resolution]
    params: dict[str, Any] = {}
    keys = []
    for i, k in enumerate(meter_keys):
        params[f"k{i}"] = int(k)
        keys.append(f"%(k{i})s")
    if trunc_unit is None:
        # Raw: one point per interval end.
        t_expr = "DATE_PART(epoch_millisecond, INTERVALENDTIME)"
    else:
        # Bucket by the interval's START (end - 1 s), so the interval ending at
        # midnight counts toward the day before; return the bucket's start as
        # a true epoch instant. bucket_tz is a code constant.
        local = (f"CONVERT_TIMEZONE('{bucket_tz}', DATEADD(second, -1, INTERVALENDTIME))"
                 f"::TIMESTAMP_NTZ")
        t_expr = (f"DATE_PART(epoch_millisecond, CONVERT_TIMEZONE('{bucket_tz}', 'UTC', "
                  f"DATE_TRUNC('{trunc_unit}', {local})))")
    sql = f"""
        WITH iv AS (
            SELECT METER_KEY, INTERVALENDTIME, KWHDELIVERED, KWHRETURNED, ISKWHDELIVEREDESTIMATED
            FROM {get_config().fq(source.interval)}
            WHERE METER_KEY IN ({', '.join(keys)})
              AND INTERVALENDTIME > TO_TIMESTAMP_TZ(%(start_s)s)
              AND INTERVALENDTIME <= TO_TIMESTAMP_TZ(%(end_s)s)
            -- a restaged interval appears more than once: latest restage wins
            QUALIFY ROW_NUMBER() OVER (PARTITION BY METER_KEY, INTERVALENDTIME
                                       ORDER BY RECORDSTAGEDATETIME DESC NULLS LAST) = 1
        ),
        ts AS (  -- premise total per interval (summed across its meters)
            SELECT INTERVALENDTIME, SUM(KWHDELIVERED) AS d, SUM(KWHRETURNED) AS r,
                   COUNT(*) AS n, COUNT_IF(ISKWHDELIVEREDESTIMATED) AS n_est
            FROM iv GROUP BY INTERVALENDTIME
        )
        SELECT {t_expr} AS t, SUM(d) AS kwh, SUM(r) AS kwh_returned, MAX(d) AS peak,
               SUM(n) AS n, SUM(n_est) AS n_est
        FROM ts GROUP BY 1 ORDER BY 1"""
    return sql, params


def _f(v: Any) -> Optional[float]:
    return None if v is None else float(v)


def _day(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d")


def interval_series(source: Source, premise_id: str, user_id: str, start_ms: int, end_ms: int,
                    meter_key: Optional[int] = None, resolution: str = "auto") -> dict[str, Any]:
    """Consumption for a premise's meters (or one of them) over a window, at
    a resolution that keeps the response <= MAX_POINTS points."""
    validate_window(start_ms, end_ms)
    res = choose_resolution(start_ms, end_ms, resolution)
    # Re-derive the premise's meters server-side: the browser can only ask
    # for meters linked to the premise it opened.
    keys = [int(r["meter_key"]) for r in _meter_rows(source, premise_id)]
    if meter_key is not None:
        if meter_key not in keys:
            raise ValueError("That meter is not linked to the selected premise.")
        keys = [meter_key]
    out: dict[str, Any] = {"source": source.key, "premise_id": premise_id, "meter_keys": keys,
                           "start_ms": start_ms, "end_ms": end_ms, "resolution": res,
                           "unit": source.unit, "unit_label": f"{source.unit} {RESOLUTIONS[res][3]}",
                           "points": [], "totals": None}
    if not keys:
        return out
    log_access(source, user_id, "series", premise_id,
               detail=f"{_day(start_ms)}..{_day(end_ms)} {res}"
                      + (f" meter_key={meter_key}" if meter_key is not None else ""))
    sql, params = build_series_sql(source, keys, res)
    params.update(start_s=start_ms // 1000, end_s=-(-end_ms // 1000))
    rows = db.query(sql, params, timeout=SERIES_TIMEOUT_S)
    points = [{"t": int(r["t"]), "kwh": _f(r["kwh"]), "kwh_returned": _f(r["kwh_returned"]),
               "peak": _f(r["peak"]), "n": int(r["n"]), "n_est": int(r["n_est"])} for r in rows]
    out["points"] = points
    if points:
        peak = max(points, key=lambda p: p["peak"] if p["peak"] is not None else float("-inf"))
        n = sum(p["n"] for p in points)
        out["totals"] = {
            "kwh": sum(p["kwh"] or 0.0 for p in points),
            "kwh_returned": sum(p["kwh_returned"] or 0.0 for p in points),
            "peak_interval_kwh": peak["peak"], "peak_bucket_ms": peak["t"],
            "intervals": n,
            "estimated_share": (sum(p["n_est"] for p in points) / n) if n else 0.0,
        }
    return out


# --- Status ------------------------------------------------------------------
def status() -> dict[str, Any]:
    """Last completed refresh per source; loaded=False until 11 + 12 have run."""
    rows = db.query_if_exists(f"""
        SELECT UTILITY AS utility, MODE AS mode, STEP AS step, STATUS AS status,
               LOGGED_AT AS logged_at, DETAIL AS detail,
               MAX(IFF(STEP = 'DONE', LOGGED_AT, NULL)) OVER (PARTITION BY UTILITY) AS last_done
        FROM {get_config().fq('INTERVAL_REFRESH_LOG')}
        QUALIFY ROW_NUMBER() OVER (PARTITION BY UTILITY ORDER BY LOGGED_AT DESC) = 1
    """, timeout=SEARCH_TIMEOUT_S)
    by_utility = {r["utility"]: r for r in rows or []}
    sources = []
    for src in SOURCES.values():
        r = by_utility.get(src.utility)
        sources.append({
            "key": src.key, "label": src.label, "unit": src.unit,
            "loaded": bool(r and r["last_done"]),
            "last_refresh": _iso(r["last_done"]) if r else None,
            "latest_step": r["step"] if r else None,
            "latest_status": r["status"] if r else None,
            "latest_at": _iso(r["logged_at"]) if r else None,
        })
    return {"tables_exist": rows is not None, "sources": sources,
            "default_source": DEFAULT_SOURCE}
