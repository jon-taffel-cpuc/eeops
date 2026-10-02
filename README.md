# EE Ops — CPUC Energy Division internal operations app

Internal web app for the Energy Division EE team. Runs entirely inside
Snowflake: one Snowpark Container Services (SPCS) service serves the React
UI and a FastAPI backend, data lives in `CPUC_ED_DB.ENERGY_EFFICIENCY`
(objects prefixed `EEOPS_`), and sign-in is Snowflake's own (CPUC SSO).
UI design follows the Canopy design system; the deploy pipeline is the one
proven on CET_2 (and refined on Canopy and CMS).

**Status:** scaffold. Six pages are reserved and empty, ready to be scoped:

| Page | Route |
|---|---|
| Customers and Markets | `/customers-markets` |
| Ex Ante/Custom | `/ex-ante-custom` |
| Programs and Performance | `/programs-performance` |
| Grid Details | `/grid-details` |
| Policies and Proceedings | `/policies-proceedings` |
| CPUC Admin | `/cpuc-admin` (includes a deploy/system status panel) |

- **Deploying:** [`Quick Deploy Guide.md`](Quick%20Deploy%20Guide.md)
- **CoCo / AI assistant rules:** [`AGENTS.md`](AGENTS.md)
- **Why the pipeline is the way it is:** [`deploy/LESSONS_LEARNED.md`](deploy/LESSONS_LEARNED.md)
- **Schema conventions:** [`deploy/sql/README.md`](deploy/sql/README.md)

```
api/          FastAPI app (api/main.py), identity (api/deps.py), routes/ (served at /api/v1)
eeops/        Backend package: version, Snowflake config (config.py), data layer (db.py)
frontend/     React 19 + Vite + TypeScript source (built into static/ by deploy/01)
  src/nav.ts       the one list of pages (sidebar + routes + page titles)
  src/pages/       one file per page
  src/index.css    design system ported from Canopy
static/       Built SPA shipped in the image (generated -- commit it, don't edit it)
deploy/       00-06 deploy pipeline + sql/ for future DDL
tests/        API tests (no Snowflake needed)
```

## Architecture

```
 Browser ──(Snowflake SSO)──► SPCS ingress ──► EEOPS_APP service (:8080, one container)
                                │                 ├─ static/   React SPA
   Sf-Context-Current-User ─────┘                 ├─ api/      FastAPI  /api/v1/...
                                                  └─ eeops/    Snowflake data layer
                                                        │  OAuth token at /snowflake/session/token
                    CPUC_ED_DB.ENERGY_EFFICIENCY  ◄─────┘  (service owner role CPUC_ED_TITLE20_RL)
```

## Local development

Backend (laptop, with a `cpuc_sso` Snowflake CLI connection — see the Quick Deploy Guide):

```powershell
py -m pip install -r requirements-dev.txt
```
```powershell
$env:SNOWFLAKE_CONNECTION_NAME = "cpuc_sso"; $env:EEOPS_DEV_USER = "<YOUR_SNOWFLAKE_USER>"
```
```powershell
py -m uvicorn api.main:app --reload --port 8000
```

Frontend (in `frontend/`): `npm install` then `npm run dev` — Vite proxies
`/api` to `:8000`. **Not in CoCo:** npm hangs on the `/workspace` stage mount;
in CoCo the only supported build is `deploy/01_auto_deploy_sf.sh`.

Tests: `env -u PYTHONPATH python -m pytest -q -p no:cacheprovider tests`
