# Lessons learned — SPCS web apps at CPUC

Every pitfall hit while deploying CET_2 (first SPCS app, Sep 2026), Canopy
(Supabase → Snowflake migration) and CMS, and how EE Ops avoids it. Read this
before changing anything in `deploy/`. Add a row whenever something new breaks.

## Building in CoCo (Snowsight sandbox)

| # | What went wrong | Where | EE Ops handling |
|---|---|---|---|
| 1 | `npm install` / `npm ci` / `npm run build` hang on `/workspace` (a stage mount, not POSIX) | CET_2 | `01` copies `frontend/` to `$HOME/fe`, builds there, copies `dist/` back |
| 2 | Build failed silently missing vite/tsc: the sandbox sets `NODE_ENV=production`, which skips devDependencies | CET_2 | `01` runs `NODE_ENV=development npm ci --include=dev` |
| 3 | git CLI doesn't work on `/workspace` | CET_2 | Commit/push in the Snowsight Git panel; `01` has no git steps |
| 4 | `rm -rf` on directories under `/workspace` is unreliable; files can't be appended to | CET_2, CMS | `01` deletes `static/` files one by one; edits use full rewrites |
| 5 | Sandbox `PYTHONPATH` leaks old packages (e.g. `typing_extensions`) into venvs | CET_2, CMS | Always `env -u PYTHONPATH` for venvs/tests |
| 6 | Sandbox sets `PYTHONSAFEPATH=1`, so the cwd isn't on `sys.path` (`No module named 'eeops'`) | EE Ops | `tests/conftest.py` adds the repo root; for ad-hoc scripts set `PYTHONPATH=<repo>` explicitly |
| 7 | Sandbox can't reach GitHub (crane download) or the Snowflake registry (403) | CET_2, CMS | Image build/push (`02`) runs on the laptop only |
| 8 | `snow spcs image-registry token` fails in the sandbox ("child session token") | CET_2 | Not used; `02` authenticates with a PAT |
| 9 | `01`'s interactive prompt can't be answered from chat | CET_2 | CoCo always passes `--patch` / `--minor` / `--major` (AGENTS.md) |
| 10 | First run of `01` says "No changes detected" when a stale manifest exists | CET_2 | Delete `.deploy_manifest.json` to force a full rebuild |

## Building the image on the laptop

| # | What went wrong | Where | EE Ops handling |
|---|---|---|---|
| 11 | No Docker / WSL / Rancher on CPUC laptops (no admin rights) | CET_2 | `02` uses `crane` (auto-downloaded) to append one layer onto `python:3.11-slim`. No Dockerfile on purpose |
| 12 | CMS shipped an old `02` stub that still called `docker` and `snow` → `FileNotFoundError: [WinError 2]` | CMS | `02` needs only Python; `snow` isn't required for the build |
| 13 | Registry gives an empty 401 with a session token even though `crane auth login` "succeeds" | CET_2 | `02` requires a PAT (env, saved file, or prompt) |
| 14 | PAT still 401: short user name instead of LOGIN_NAME (`PAT_USER_MISMATCH` in login history) | CET_2 | `02` prompts for the email LOGIN_NAME and upper-cases it |
| 15 | `--reuse-layer` re-pushed an old `layer.tar` → code changes silently lost | CET_2 | Flag documented as "retry a failed push only"; `02` prints a warning when used |
| 16 | `static/` rebuilt but not committed/pulled → old UI deployed silently | CET_2 | `02` refuses to build unless `static/version.json` = `frontend/package.json` = `eeops/__init__.py` |
| 17 | Wheels missing for Linux | CET_2 | `--only-binary` for manylinux x86_64 / cp311; `requirements.txt` only lists wheel-shipping packages, majors capped |
| 18 | `python` opens the Microsoft Store; multi-line PowerShell pastes mangle flags | CET_2 | Docs use `py` and one command per code block |
| 19 | Account display name `cpuc` makes the CLI hang | CET_2 | Docs use `californiapublicutilitiescommission-cpuc_aws_us_west_2` |

## Running the service

| # | What went wrong | Where | EE Ops handling |
|---|---|---|---|
| 20 | `SUSPEND`/`RESUME` four times in a row kept running the old image (digest is pinned at spec-apply time) | CET_2 (2026-09-28) | Deploy = `03` (`ALTER SERVICE … FROM SPECIFICATION`); `06` explains SUSPEND/RESUME = same image |
| 21 | First deploy: `03` was ALTER-only and failed because the service didn't exist yet | CMS | `03` runs `CREATE SERVICE IF NOT EXISTS` then `ALTER` (identical specs) |
| 22 | `SYSTEM_COMPUTE_POOL_CPU` rejects general services | CET_2 | Uses `CPUC_ED_SNOWPARK_POOL` |
| 23 | CET_2's `00` created `CPUC_ED_APPS_POOL` but the service actually ran on `CPUC_ED_SNOWPARK_POOL` (docs drifted) | CET_2 | One pool name everywhere; `00` only *checks* the pool |
| 24 | In-memory job status + multiple uvicorn workers → polls hit a worker that doesn't have the job | CET_2 | Image runs 2 workers; AGENTS.md rule: no request-spanning state in memory |
| 25 | (Preventive) a readiness probe that queries Snowflake would mark the container unready whenever the warehouse is slow | design rule | `/api/v1/health` never touches Snowflake; Snowflake check is a separate admin endpoint |
| 26 | Browser kept an old UI after deploy | CET_2 | `index.html` served `no-store`; hashed assets `immutable`; banner + CPUC Admin show versions; hard-refresh step |
| 27 | A `StaticFiles` mount on `/assets` took precedence over the SPA route, so the `immutable` cache header was never sent (CET_2 / Canopy code) | EE Ops | Assets served by the catch-all; test covers it |
| 28 | Without that mount, a stale tab requesting an old hashed bundle after a redeploy would fall through to `index.html` (HTML for a `.js` request) | EE Ops | Missing `assets/*` → 404; test covers it |
| 29 | `SYSTEM$GET_SERVICE_STATUS` is deprecated | docs | `04`/`06` use `SHOW SERVICE CONTAINERS` |

## Browser / identity

| # | What went wrong | Where | EE Ops handling |
|---|---|---|---|
| 30 | Google Fonts blocked: the ingress CSP is `default-src 'self'` (report-only today; assume it will be enforced) | CMS (2026-09-30) | `@fontsource` packages, `assetsInlineLimit: 0` (no `data:` URIs), and `01` fails if built HTML/CSS references another origin |
| 31 | `CURRENT_USER()` on the backend connection returns the service identity, not the person | CMS, Canopy | Identity = `Sf-Context-Current-User` header (`api/deps.py`) |
| 32 | Frontend called `/api/v1/auth/me`, backend served `/api/v1/me` → 404 and an endless "Initializing…" | CMS | One `apiFetch` client; route tests; AGENTS.md rule to keep paths identical |
| 33 | Users without the service role get "not authorized" at the URL | Canopy | `05` grants `EEOPS_APP!APP_USER` per Snowflake role |

## Data

| # | What went wrong | Where | EE Ops handling |
|---|---|---|---|
| 34 | Shared schema `ENERGY_EFFICIENCY` holds several apps' tables | Canopy | All EE Ops objects `EEOPS_`-prefixed; never touch others' tables |
| 35 | `CREATE OR REPLACE` / `DROP` on an app table destroys data | Canopy | Idempotent DDL only (`deploy/sql/README.md`) |
| 36 | Snowflake doesn't enforce CHECK / FK constraints | Canopy | Validate in the API layer |
| 37 | T-SQL ports: `CAST(x AS INT)` rounds in Snowflake (truncates in SQL Server); `+` string concat; divide-by-zero returns NULL | CET_2 | Note for any page that ports SQL Server logic: use `TRUNC`, `||`/`CONCAT`, explicit zero guards |
