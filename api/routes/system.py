"""
System routes: who am I, and can the container reach Snowflake.

/api/v1/health (the readiness probe) lives in api/main.py and must never
touch Snowflake -- a slow warehouse would mark the container unready.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends

from eeops import __version__, db

from ..deps import CurrentUser, current_user

router = APIRouter()


@router.get("/me")
def me(user: CurrentUser = Depends(current_user)) -> dict:
    return {"authenticated": user.authenticated, "user_id": user.user_id}


@router.get("/system/snowflake")
def snowflake_check() -> dict:
    """Used by the CPUC Admin page to confirm the service's Snowflake session works."""
    return {"ok": True, "backend_version": __version__, "session": db.ping()}
