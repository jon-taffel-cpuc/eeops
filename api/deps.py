"""
Request identity.

The service's public endpoint sits behind Snowflake's SPCS ingress: a browser
must sign in to Snowflake (CPUC SSO) before any request reaches the container,
and only Snowflake roles granted the service role EEOPS_APP!APP_USER get in
(deploy/05_manage_access_sf.sql). The ingress then adds the header
`Sf-Context-Current-User: <SNOWFLAKE USER NAME>`; that user name is the
identity everywhere.

Do NOT use CURRENT_USER() on the backend's Snowflake connection for this --
it returns the service's own identity, not the person using the app.

Local development (not in SPCS): set EEOPS_DEV_USER=<SNOWFLAKE_USER> to
simulate the header. It is ignored when SNOWFLAKE_SERVICE_NAME is set (SPCS).
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional

from fastapi import Request

USER_HEADER = "sf-context-current-user"


@dataclass(frozen=True)
class CurrentUser:
    user_id: Optional[str]  # Snowflake user name; None = unauthenticated (dev only)

    @property
    def authenticated(self) -> bool:
        return self.user_id is not None


def user_id_from_request(request: Request) -> Optional[str]:
    header = (request.headers.get(USER_HEADER) or "").strip()
    if header:
        return header.upper()
    if not os.environ.get("SNOWFLAKE_SERVICE_NAME"):
        dev = (os.environ.get("EEOPS_DEV_USER") or "").strip()
        if dev:
            return dev.upper()
    return None


def current_user(request: Request) -> CurrentUser:
    return CurrentUser(user_id=user_id_from_request(request))
