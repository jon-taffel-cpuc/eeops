"""
API smoke tests -- no Snowflake needed.

Run (in CoCo or on a laptop):
    env -u PYTHONPATH python -m pytest -q -p no:cacheprovider tests
`env -u PYTHONPATH` stops the CoCo sandbox's packages leaking into the venv.
"""
from __future__ import annotations

import importlib
import json

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def client(tmp_path, monkeypatch):
    """App built against a throwaway static/ so tests don't depend on a frontend build."""
    (tmp_path / "assets").mkdir()
    (tmp_path / "assets" / "app-abc123.js").write_text("console.log('ok')")
    (tmp_path / "index.html").write_text("<!doctype html><div id=root></div>")
    (tmp_path / "version.json").write_text(json.dumps({"version": "9.9.9"}))
    monkeypatch.setenv("EEOPS_STATIC_DIR", str(tmp_path))
    monkeypatch.delenv("SNOWFLAKE_SERVICE_NAME", raising=False)
    monkeypatch.delenv("EEOPS_DEV_USER", raising=False)
    import api.main
    importlib.reload(api.main)
    return TestClient(api.main.app)


def test_health_reports_both_versions(client):
    from eeops import __version__
    body = client.get("/api/v1/health").json()
    assert body["status"] == "ok"
    assert body["version"] == __version__
    assert body["frontend_version"] == "9.9.9"


def test_me_uses_ingress_header(client):
    body = client.get("/api/v1/me", headers={"Sf-Context-Current-User": "jtaffel"}).json()
    assert body == {"authenticated": True, "user_id": "JTAFFEL"}


def test_me_without_header_is_anonymous(client):
    assert client.get("/api/v1/me").json() == {"authenticated": False, "user_id": None}


def test_dev_user_ignored_inside_spcs(client, monkeypatch):
    monkeypatch.setenv("EEOPS_DEV_USER", "devuser")
    assert client.get("/api/v1/me").json()["user_id"] == "DEVUSER"
    monkeypatch.setenv("SNOWFLAKE_SERVICE_NAME", "EEOPS_APP")
    assert client.get("/api/v1/me").json()["user_id"] is None


def test_spa_fallback_serves_index_uncached(client):
    for path in ("/", "/customers-markets", "/cpuc-admin/anything"):
        res = client.get(path)
        assert res.status_code == 200
        assert "id=root" in res.text
        assert "no-store" in res.headers["cache-control"]


def test_hashed_assets_are_immutable(client):
    res = client.get("/assets/app-abc123.js")
    assert res.status_code == 200
    assert "immutable" in res.headers["cache-control"]


def test_missing_asset_is_404_not_index(client):
    assert client.get("/assets/app-OLDHASH.js").status_code == 404


def test_unknown_api_route_is_404_not_spa(client):
    assert client.get("/api/v1/does-not-exist").status_code == 404


def test_path_traversal_falls_back_to_index(client):
    res = client.get("/..%2F..%2Fetc%2Fpasswd")
    assert res.status_code in (200, 404)
    assert "root:" not in res.text
