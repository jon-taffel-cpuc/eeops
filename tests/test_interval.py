"""
Interval page tests -- no Snowflake needed (eeops.db is faked).

The SQL-shape tests guard the things that make the page fast: requests must
read the EEOPS_ sorted copy (never the 6 TB share), filter it on bound
METER_KEY literals, and keep user text out of the SQL string.
"""
from __future__ import annotations

import importlib
import inspect
import json
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from eeops import interval_data as idata

PGE = idata.SOURCES["pge_elec"]
DAY = idata.DAY_MS
USER = {"Sf-Context-Current-User": "jtaffel"}


def render(sql: str, params: dict) -> str:
    """What the connector's client-side pyformat binding does. Fails on a
    stray literal '%' in the SQL (it would have to be '%%')."""
    return sql % {k: repr(v) for k, v in params.items()}


# --- pure logic ---------------------------------------------------------------
def test_normalize_matches_refresh_expression():
    assert idata.normalize("123 Main St., Apt #4") == "123 MAIN ST APT 4"
    assert idata.normalize("  o'farrell-street ") == "O FARRELL STREET"


def test_search_tokens_strip_wildcards_and_dedupe():
    assert idata.search_tokens("100% main_st main") == ["100", "MAIN", "ST"]
    with pytest.raises(ValueError):
        idata.search_tokens("a %")


@pytest.mark.parametrize("days,expected", [(7, "interval"), (60, "hour"), (365, "day"),
                                           (5 * 365, "day"), (8 * 365, "month")])
def test_auto_resolution(days, expected):
    assert idata.choose_resolution(0, days * DAY) == expected


def test_explicit_resolution_is_capped():
    assert idata.choose_resolution(0, 90 * DAY, "interval") == "interval"   # 8,641 points
    with pytest.raises(ValueError):
        idata.choose_resolution(0, 365 * DAY, "interval")                  # 35,041 points
    with pytest.raises(ValueError):
        idata.choose_resolution(0, DAY, "minute")


def test_window_validation():
    with pytest.raises(ValueError):
        idata.validate_window(10, 10)
    with pytest.raises(ValueError):
        idata.validate_window(0, (idata.MAX_RANGE_DAYS + 1) * DAY)


def test_mask_id():
    assert idata.mask_id("1234567890") == "•••7890"
    assert idata.mask_id("12") == "•••"
    assert idata.mask_id(None) is None


# --- SQL shape ----------------------------------------------------------------
def test_requests_never_touch_the_share():
    src = inspect.getsource(idata)
    assert "amidata(" not in src
    assert "RECURVE_ELEC_CONSUMPTION_INTERVAL_PGE" not in src.split('"""', 2)[2]


@pytest.mark.parametrize("res", idata.RESOLUTION_ORDER)
def test_series_sql_prunes_on_bound_meter_keys(res):
    sql, params = idata.build_series_sql(PGE, [11, 42], res)
    assert "CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_ELEC_INTERVAL" in sql
    assert "WHERE METER_KEY IN (%(k0)s, %(k1)s)" in sql
    assert params == {"k0": 11, "k1": 42}
    # raw column compared to constants -> min/max pruning works
    assert "AND INTERVALENDTIME > TO_TIMESTAMP_TZ(%(start_s)s)" in sql
    rendered = render(sql, {**params, "start_s": 0, "end_s": 1})
    assert "METER_KEY IN (11, 42)" in rendered


def test_hour_buckets_follow_utc_day_buckets_follow_meter_tz():
    hour_sql, _ = idata.build_series_sql(PGE, [1], "hour")
    day_sql, _ = idata.build_series_sql(PGE, [1], "day")
    assert "DATE_TRUNC('hour'" in hour_sql and "'UTC'" in hour_sql
    assert "DATE_TRUNC('day'" in day_sql and idata.METER_TZ in day_sql


# --- fake Snowflake -------------------------------------------------------------
class FakeDb:
    def __init__(self):
        self.calls: list[tuple[str, str, dict]] = []
        self.meters = [{"meter_key": 7, "meter_id": "1000123456", "service_point_id": "SP99887766",
                        "energy_type": "ELEC", "start_date": None, "end_date": None,
                        "first_interval": datetime(2024, 1, 1, tzinfo=timezone.utc),
                        "last_interval": datetime(2025, 1, 1, tzinfo=timezone.utc),
                        "interval_rows": 35_000}]
        self.refresh_log: list[dict] | None = []

    def query(self, sql, params=None, timeout=None):
        params = params or {}
        render(sql, params)
        self.calls.append(("query", sql, params))
        if "EEOPS_PGE_PREMISE_METER" in sql:
            return self.meters
        if "FROM CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_PREMISE" in sql:
            return [{"premise_id": "P1", "address": "123 MAIN ST", "city": "OAKLAND",
                     "zip": "94607", "meter_count": 1, "last_interval": None}]
        if "EEOPS_PGE_ELEC_INTERVAL" in sql:
            return [{"t": 0, "kwh": 1.5, "kwh_returned": 0, "peak": 0.5, "n": 4, "n_est": 1},
                    {"t": 3_600_000, "kwh": 2.0, "kwh_returned": 0.25, "peak": 0.75, "n": 4, "n_est": 0}]
        raise AssertionError(f"unexpected SQL: {sql}")

    def execute(self, sql, params=None, timeout=None):
        render(sql, params or {})
        self.calls.append(("execute", sql, params or {}))
        return 1

    def query_if_exists(self, sql, params=None, timeout=None):
        self.calls.append(("query_if_exists", sql, params or {}))
        return self.refresh_log

    def kinds(self):
        return [(k, "LOG" if "ACCESS_LOG" in s else "") for k, s, _ in self.calls]


@pytest.fixture()
def fake_db(monkeypatch):
    fake = FakeDb()
    monkeypatch.setattr(idata.db, "query", fake.query)
    monkeypatch.setattr(idata.db, "execute", fake.execute)
    monkeypatch.setattr(idata.db, "query_if_exists", fake.query_if_exists)
    return fake


@pytest.fixture()
def client(tmp_path, monkeypatch, fake_db):
    (tmp_path / "index.html").write_text("<!doctype html><div id=root></div>")
    (tmp_path / "version.json").write_text(json.dumps({"version": "9.9.9"}))
    monkeypatch.setenv("EEOPS_STATIC_DIR", str(tmp_path))
    monkeypatch.delenv("SNOWFLAKE_SERVICE_NAME", raising=False)
    monkeypatch.delenv("EEOPS_DEV_USER", raising=False)
    import api.main
    importlib.reload(api.main)
    return TestClient(api.main.app)


# --- API -----------------------------------------------------------------------
@pytest.mark.parametrize("path", ["/api/v1/interval/search?q=main",
                                  "/api/v1/interval/premise?premise_id=P1",
                                  f"/api/v1/interval/series?premise_id=P1&start=0&end={DAY}"])
def test_customer_data_requires_sign_in(client, path):
    assert client.get(path).status_code == 401


def test_search_binds_user_text(client, fake_db):
    res = client.get("/api/v1/interval/search", params={"q": "123 Main'; DROP"}, headers=USER)
    assert res.status_code == 200
    assert res.json()["results"][0]["address"] == "123 MAIN ST"
    _, sql, params = fake_db.calls[-1]
    assert "MAIN" not in sql and "DROP" not in sql
    assert params["t0"] == "% 123%" and params["t2"] == "% DROP%"
    # whole-word matches rank first; ranking is ORDER BY only, WHERE stays prefix LIKEs
    assert params["w1"] == "% MAIN %"
    assert "SEARCH_TEXT || ' ' LIKE %(w0)s" in sql.split("ORDER BY")[1]
    assert "%(w0)s" not in sql.split("ORDER BY")[0]
    assert not any(k == "execute" for k, _ in fake_db.kinds())   # searches aren't logged


def test_premise_logs_access_first_and_masks_ids(client, fake_db):
    body = client.get("/api/v1/interval/premise", params={"premise_id": "P1"}, headers=USER).json()
    assert fake_db.kinds()[0] == ("execute", "LOG")
    assert fake_db.calls[0][2]["user"] == "JTAFFEL" and fake_db.calls[0][2]["action"] == "premise"
    meter = body["meters"][0]
    assert meter == {**meter, "meter_key": 7, "meter_label": "•••3456", "service_point_label": "•••7766"}
    assert "1000123456" not in json.dumps(body)
    assert body["data_end_ms"] == int(datetime(2025, 1, 1, tzinfo=timezone.utc).timestamp() * 1000)


def test_series_checks_meter_belongs_to_premise(client, fake_db):
    res = client.get("/api/v1/interval/series", headers=USER,
                     params={"premise_id": "P1", "start": 0, "end": DAY, "meter_key": 999})
    assert res.status_code == 400
    assert not any(k == "execute" for k, _ in fake_db.kinds())


def test_series_logs_then_returns_points_and_totals(client, fake_db):
    res = client.get("/api/v1/interval/series", headers=USER,
                     params={"premise_id": "P1", "start": 0, "end": 2 * DAY, "meter_key": 7})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["resolution"] == "interval" and body["meter_keys"] == [7]
    assert [p["t"] for p in body["points"]] == [0, 3_600_000]
    assert body["totals"]["kwh"] == pytest.approx(3.5)
    assert body["totals"]["peak_interval_kwh"] == pytest.approx(0.75)
    assert body["totals"]["estimated_share"] == pytest.approx(1 / 8)
    kinds = fake_db.kinds()
    assert kinds.index(("execute", "LOG")) < len(kinds) - 1        # logged before the data query
    assert fake_db.calls[-1][2]["k0"] == 7


def test_status_before_tables_exist(client, fake_db):
    fake_db.refresh_log = None
    body = client.get("/api/v1/interval/status").json()
    assert body["tables_exist"] is False
    assert body["sources"][0]["loaded"] is False


def test_status_after_refresh(client, fake_db):
    done = datetime(2026, 10, 3, 9, tzinfo=timezone.utc)
    fake_db.refresh_log = [{"utility": "PGE", "mode": "DELTA", "step": "DONE", "status": "OK",
                            "logged_at": done, "detail": None, "last_done": done}]
    src = client.get("/api/v1/interval/status").json()["sources"][0]
    assert src["loaded"] is True and src["last_refresh"].startswith("2026-10-03")
