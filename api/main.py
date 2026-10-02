"""
EE Ops API -- FastAPI application factory (served from SPCS on :8080).

Same layout as CET_2 / Canopy: thin routes under /api/v1, and the prebuilt
React SPA (static/) served from the same origin, so the browser only ever
talks to the Snowflake-authenticated ingress. One process, one port, no nginx.

Adding a feature's API: create api/routes/<area>.py with an APIRouter, then
include it below with prefix /api/v1/<area>. Keep routes registered BEFORE
the SPA catch-all at the bottom.
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
import snowflake.connector.errors

from eeops import __version__

from .routes import system


def create_app() -> FastAPI:
    static_dir = Path(os.environ.get("EEOPS_STATIC_DIR",
                                     Path(__file__).resolve().parent.parent / "static"))
    # version.json is written by the frontend build (see frontend/vite.config.ts)
    try:
        frontend_version = json.loads((static_dir / "version.json").read_text())["version"]
    except (OSError, ValueError, KeyError):
        frontend_version = "unknown"

    app = FastAPI(
        title="EE Ops API",
        description="CPUC Energy Division EE Ops internal app, backed by Snowflake.",
        version=__version__,
    )

    @app.exception_handler(ValueError)
    async def _value_error(request: Request, exc: ValueError):
        return JSONResponse(status_code=400, content={"detail": str(exc)})

    # Surface Snowflake errors (missing table, privilege, ...) as readable JSON
    # instead of a bare 500 -- the UI shows `detail`, and it lands in the logs.
    @app.exception_handler(snowflake.connector.errors.Error)
    async def _snowflake_error(request: Request, exc: Exception):
        print(f"[snowflake error] {request.method} {request.url.path}: {exc}", flush=True)
        return JSONResponse(status_code=500,
                            content={"detail": f"Snowflake error: {getattr(exc, 'msg', exc)}"})

    app.include_router(system.router, prefix="/api/v1", tags=["system"])

    # deploy/04_verify_sf.sql greps the service log for this exact line.
    print(f"EE Ops backend v{__version__}, frontend v{frontend_version}", flush=True)

    @app.get("/api/v1/health")
    async def health():
        return {"status": "ok", "version": __version__, "frontend_version": frontend_version,
                "time": int(time.time())}

    # SPA (registered after the API so /api/* wins). Assets are served by this
    # catch-all rather than a StaticFiles mount: a mount on /assets would take
    # precedence and drop the immutable Cache-Control header below.
    if (static_dir / "index.html").is_file():
        @app.get("/{path:path}", include_in_schema=False)
        async def spa(path: str):
            if path.startswith("api/"):
                raise HTTPException(status_code=404)
            candidate = (static_dir / path).resolve()
            if path and candidate.is_file() and candidate.is_relative_to(static_dir.resolve()):
                # Hashed assets (JS/CSS/fonts) are immutable; everything else must revalidate
                if path.startswith("assets/"):
                    return FileResponse(candidate, headers={
                        "Cache-Control": "public, max-age=31536000, immutable"})
                return FileResponse(candidate, headers={"Cache-Control": "no-cache, must-revalidate"})
            # An old hashed bundle requested by a stale tab after a redeploy: 404,
            # not index.html (which the browser would reject as the wrong MIME type).
            if path.startswith("assets/"):
                raise HTTPException(status_code=404)
            # SPA fallback: index.html is never cached so a redeploy lands on the next load
            return FileResponse(static_dir / "index.html", headers={
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Pragma": "no-cache", "Expires": "0"})

    return app


app = create_app()
