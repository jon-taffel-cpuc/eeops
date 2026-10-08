"""
Interval page API: address search + AMI interval consumption.

All Snowflake work is in eeops/interval_data.py. Every endpoint that returns
customer data (addresses, consumption) requires a signed-in user -- inside
SPCS the ingress always provides one; locally set EEOPS_DEV_USER.
"""
from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from eeops import interval_data

from ..deps import CurrentUser, current_user

router = APIRouter()


def signed_in_user(user: CurrentUser = Depends(current_user)) -> str:
    if not user.authenticated or not user.user_id:
        raise HTTPException(status_code=401, detail="Sign in to Snowflake to view interval data.")
    return user.user_id


@router.get("/status")
def status() -> dict:
    """Which sources are loaded and when they were last refreshed (no customer data)."""
    return interval_data.status()


@router.get("/search")
def search(q: str = Query(..., max_length=200),
           source: Optional[str] = None,
           limit: int = Query(12, ge=1, le=interval_data.MAX_SEARCH_RESULTS),
           _user: str = Depends(signed_in_user)) -> dict:
    src = interval_data.get_source(source)
    return {"source": src.key, "results": interval_data.search_premises(src, q, limit)}


@router.get("/premise")
def premise(premise_id: str = Query(..., min_length=1, max_length=100),
            source: Optional[str] = None,
            user: str = Depends(signed_in_user)) -> dict:
    src = interval_data.get_source(source)
    try:
        return interval_data.premise_detail(src, premise_id, user)
    except interval_data.PremiseNotFound as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.get("/series")
def series(premise_id: str = Query(..., min_length=1, max_length=100),
           start: int = Query(..., description="window start, epoch ms"),
           end: int = Query(..., description="window end, epoch ms"),
           meter_key: Optional[int] = None,
           resolution: str = "auto",
           source: Optional[str] = None,
           user: str = Depends(signed_in_user)) -> dict:
    src = interval_data.get_source(source)
    return interval_data.interval_series(src, premise_id, user, start, end,
                                         meter_key=meter_key, resolution=resolution)
