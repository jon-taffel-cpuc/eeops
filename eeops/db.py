"""
EE Ops data access layer -- the only module that imports snowflake.connector.

Conventions (same as Canopy / CET_2):
  * Every value goes through a bind parameter (%(name)s or %s). Never
    interpolate user input into SQL.
  * Identifiers are only interpolated from code constants via
    get_config().fq(...), never from request data.
  * One connection per thread (FastAPI runs sync routes in a threadpool),
    recycled every 15 minutes. The SPCS OAuth token file is refreshed by the
    platform, so a fresh connection always reads the current token.
  * CURRENT_USER() on this connection is the *service* identity, not the
    person using the app. The caller comes from the ingress header -- see
    api/deps.py.
"""
from __future__ import annotations

import os
import threading
import time
from typing import Any, Mapping, Optional, Sequence, Union

import snowflake.connector
import snowflake.connector.errors
from snowflake.connector import DictCursor

from .config import SnowflakeConfig, get_config

Params = Optional[Union[Sequence[Any], Mapping[str, Any]]]

_local = threading.local()
_MAX_CONN_AGE_S = 15 * 60


def _connect(cfg: SnowflakeConfig) -> snowflake.connector.SnowflakeConnection:
    kwargs: dict[str, Any] = dict(database=cfg.database, schema=cfg.schema,
                                  warehouse=cfg.warehouse, client_session_keep_alive=True)
    if cfg.role:
        kwargs["role"] = cfg.role
    if os.path.isfile(cfg.token_file):
        # SPCS (and CoCo sandboxes): OAuth token file, refreshed by the platform.
        with open(cfg.token_file) as f:
            token = f.read().strip()
        kwargs.update(account=cfg.account, host=cfg.host, authenticator="oauth", token=token)
    elif cfg.connection_name:
        kwargs["connection_name"] = cfg.connection_name
    else:
        raise RuntimeError(
            f"No Snowflake credentials: {cfg.token_file} not found and "
            "SNOWFLAKE_CONNECTION_NAME is not set.")
    return snowflake.connector.connect(**kwargs)


def get_connection() -> snowflake.connector.SnowflakeConnection:
    conn = getattr(_local, "conn", None)
    born = getattr(_local, "born", 0.0)
    if conn is not None and (conn.is_closed() or time.time() - born > _MAX_CONN_AGE_S):
        try:
            conn.close()
        except Exception:
            pass
        conn = None
    if conn is None:
        conn = _connect(get_config())
        _local.conn, _local.born = conn, time.time()
    return conn


def query(sql: str, params: Params = None, timeout: Optional[int] = None) -> list[dict[str, Any]]:
    """Run a statement and return rows as dicts with lower-case keys.

    timeout (seconds) cancels the statement server-side -- use it for queries
    over large shared tables (e.g. AMI interval data) so a slow scan can't tie
    up a worker indefinitely.
    """
    cur = get_connection().cursor(DictCursor)
    try:
        cur.execute(sql, params, timeout=timeout)
        return [{k.lower(): v for k, v in row.items()} for row in cur.fetchall()]
    finally:
        cur.close()


def execute(sql: str, params: Params = None, timeout: Optional[int] = None) -> int:
    """Run a DML statement (INSERT/UPDATE/...) and return the affected row count."""
    cur = get_connection().cursor()
    try:
        cur.execute(sql, params, timeout=timeout)
        return cur.rowcount or 0
    finally:
        cur.close()


# "Object does not exist or not authorized" -- e.g. a page's EEOPS_ tables
# before its deploy/sql file has been run.
_MISSING_OBJECT_ERRNO = 2003


def query_if_exists(sql: str, params: Params = None,
                    timeout: Optional[int] = None) -> Optional[list[dict[str, Any]]]:
    """query(), but None instead of an error when a referenced object is missing.
    Only for status checks -- data endpoints should fail loudly."""
    try:
        return query(sql, params, timeout=timeout)
    except snowflake.connector.errors.ProgrammingError as exc:
        if getattr(exc, "errno", None) == _MISSING_OBJECT_ERRNO:
            return None
        raise


def ping() -> dict[str, Any]:
    """Connectivity check used by the CPUC Admin page (not by the readiness probe)."""
    row = query("SELECT CURRENT_VERSION() AS version, CURRENT_ROLE() AS role, "
                "CURRENT_WAREHOUSE() AS warehouse, CURRENT_DATABASE() AS database, "
                "CURRENT_SCHEMA() AS schema")[0]
    return {k: (str(v) if v is not None else None) for k, v in row.items()}
