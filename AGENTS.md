# CoCo Instructions for the EE Ops Workspace

EE Ops deploys **only** through the Snowflake pipeline in `deploy/` (see
`Quick Deploy Guide.md`). Every chat in this workspace must follow it. Do not
suggest Docker Desktop, Netlify, Render, Supabase, Auth0, Streamlit or any
other hosting / deploy path. Before changing anything in `deploy/`, read
`deploy/LESSONS_LEARNED.md` — every rule below exists because it broke once
on CET_2, Canopy or CMS.

## Platform facts (don't re-derive these)

- **Service:** `CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP` in compute pool
  `CPUC_ED_SNOWPARK_POOL` (shared with `CET_APP`, `CMS_APP`; never
  `SYSTEM_COMPUTE_POOL_CPU`). Image
  `/cpuc_ed_db/energy_efficiency/eeops_images/eeops-app:latest`, repository
  `EEOPS_IMAGES`. Container `eeops-app`, port 8080, health `/api/v1/health`.
- **Role / warehouse:** `CPUC_ED_TITLE20_RL` / `CPUC_ED_TITLE20_S_WH`.
- **Workspace:** `USER$.PUBLIC."eeops"` (lower-case name — keep the double quotes
  in `snow://workspace/...` paths).
- **Data:** `CPUC_ED_DB.ENERGY_EFFICIENCY`, shared with other apps. **Every EE
  Ops object is prefixed `EEOPS_`.** Never create, alter or drop an unprefixed
  object, and never modify another app's tables (`CETJOBS`, `OUTPUT*`, `E3*`,
  `CANOPY_*`, CMS tables). Other apps' tables may be *read*.
- **Identity:** SPCS ingress (Snowflake SSO) → header `Sf-Context-Current-User`
  (read in `api/deps.py`). `CURRENT_USER()` on the backend connection is the
  *service*, not the person. Door access = service role `EEOPS_APP!APP_USER`
  (`deploy/05_manage_access_sf.sql`). No in-app roles yet.
- **CSP:** the ingress sends `default-src 'self'`. No CDNs, Google Fonts,
  external images/scripts, or `data:` URIs. Fonts come from `@fontsource`
  packages; `vite.config.ts` sets `assetsInlineLimit: 0`; `01` fails the build
  if built HTML/CSS references another origin.

## Code map

| Path | What |
|---|---|
| `frontend/src/nav.ts` | **The list of pages** — sidebar, routes and page titles all read it |
| `frontend/src/App.tsx` | Router; `PAGES` maps each nav key to its page component |
| `frontend/src/pages/*.tsx` | One file per page (currently empty scaffolds) |
| `frontend/src/components/PageScaffold.tsx` | Standard page frame (title, subtitle, actions, body) |
| `frontend/src/components/Layout.tsx` | App shell: banner, sidebar, topbar |
| `frontend/src/index.css` | Design system ported from Canopy — reuse its classes |
| `frontend/src/lib/api.ts` | `apiFetch` / `postJson` — the only way the browser calls the backend |
| `api/main.py` | FastAPI app, error mapping, `/api/v1/health`, SPA serving (catch-all last) |
| `api/deps.py` | Current user from the ingress header |
| `api/routes/*.py` | One router per area, mounted under `/api/v1/<area>` |
| `eeops/db.py` | **The only module that talks to Snowflake**; bind params only |
| `eeops/config.py` | Connection settings + `fq()` for `EEOPS_` object names |
| `deploy/` | 00–06 pipeline; `deploy/sql/` for idempotent DDL |

## Rules for changes

1. **New page:** add an entry to `NAV` in `frontend/src/nav.ts`, create
   `frontend/src/pages/<Name>.tsx` using `<PageScaffold page="<key>">`, and add
   it to `PAGES` in `App.tsx` (the build fails if you forget). Sub-pages go in
   nested `<Routes>` inside the page (routes are registered as `<path>/*`).
2. **New API:** create `api/routes/<area>.py` with an `APIRouter`, include it in
   `api/main.py` with prefix `/api/v1/<area>` **above** the SPA catch-all, and
   add a test in `tests/`. Keep the frontend path and backend route identical
   (CMS shipped `/auth/me` vs `/me` and got 404s).
3. **Styling:** use the existing Canopy classes (`panel`, `page-header-row`,
   `button button-primary`, `data-table`, `tag badge-*`, `detail-grid`,
   `tab-strip`, ...). Add new classes to `index.css`; keep Canopy's names when
   porting a Canopy component. Avoid inline `style={{}}`.
4. **Schema change:** add an idempotent file under `deploy/sql/` (see its
   README), add it to section 3 of `00_first_time_setup.sql`, and tell the user
   to run it in Snowsight before step 3. Never `DROP` / `CREATE OR REPLACE` an
   `EEOPS_*` table.
5. **SQL safety:** never interpolate request data into SQL. Use `eeops.db.query`
   with `%(name)s` / `%s` binds; only code constants go through `fq()`.
6. **Statelessness:** the image runs uvicorn with 2 workers. Don't keep job
   status or caches that a later request must see in process memory — store it
   in an `EEOPS_` table (CET_2 needed `--workers 1` for exactly this).
7. **Readiness:** `/api/v1/health` must never call Snowflake.
8. **Versions:** `frontend/package.json` and `eeops/__init__.py` must match.
   Only `01_auto_deploy_sf.sh` bumps them — never edit them by hand.
9. **Dependencies:** anything added to `requirements.txt` must ship a manylinux
   x86_64 wheel for CPython 3.11 (the laptop build is `--only-binary`).
10. **Tests before hand-off:**
    `env -u PYTHONPATH python -m pytest -q -p no:cacheprovider tests`
    (run from a copy under `$HOME` if the stage mount is slow; the sandbox sets
    `PYTHONSAFEPATH=1`, which `tests/conftest.py` already handles).

## Deployment rule — do NOT run npm in /workspace

`/workspace` is a stage mount, where `npm install`, `npm ci`, and `npm run build`
hang or fail. When it's time to deploy (frontend build, version bump, changelog
update), **always use the auto-deploy script, with a flag** (its interactive
prompt can't be answered from chat):

```
bash /workspace/deploy/01_auto_deploy_sf.sh --patch    # or --minor | --major
```

It detects changes against `.deploy_manifest.json`, bumps both version files,
updates `CHANGELOG.md`, builds in `$HOME/fe`, CSP-checks the output, copies
`dist/` to `static/`, and saves the manifest.

### After the script finishes, tell the user to:
1. **Commit and push** in the Snowsight Git panel (the git CLI doesn't work on
   the stage mount) — including `static/` and `.deploy_manifest.json`.
2. On their laptop: `git pull`, then `py deploy\02_build_image_laptop.py`.
3. Run `deploy/03_redeploy_sf.sql` in Snowsight. CoCo may run it when asked.
4. Run `deploy/04_verify_sf.sql`, hard-refresh the app, check CPUC Admin →
   System status.
   First deploy only: run `deploy/00_first_time_setup.sql` before step 2 and
   `deploy/05_manage_access_sf.sql` after step 3.

To restart / stop / inspect the running container use
`deploy/06_restart_service_sf.sql`.

### What CoCo should never do
- Don't run `npm install` / `npm ci` / `npm run build` in `/workspace`, or build
  the frontend by hand. The script already does this.
- Don't create ad-hoc build or deploy scripts, and don't add a Dockerfile —
  CPUC laptops have no Docker; the crane build in `02` is the image build.
- Don't push images or download crane from the sandbox — it's blocked (403).
  Step 2 needs the user's PAT on their laptop.
- Don't `SUSPEND`/`RESUME` the service as a deploy (it keeps the old image
  digest). Deploy = `03` (`ALTER SERVICE ... FROM SPECIFICATION`).
- Don't edit `static/` by hand or commit without it after a build.
- Don't load anything from another origin in the frontend (CSP).
- Don't use `SYSTEM_COMPUTE_POOL_CPU`, `CREATE OR REPLACE` on `EEOPS_*`
  tables, or unprefixed object names.
