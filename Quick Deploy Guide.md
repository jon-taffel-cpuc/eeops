# Quick Deploy Guide — EE Ops on Snowflake

> EE Ops runs entirely inside Snowflake: one Snowpark Container Services
> (SPCS) service, `CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP`, serves the React
> app and a FastAPI backend; sign-in is Snowflake's own (CPUC SSO). Every
> deploy follows the same four steps. All scripts live in `deploy/`.
> This is the CET_2 pipeline, with the fixes later learned on Canopy and CMS
> (see `deploy/LESSONS_LEARNED.md`).

---

## File layout

```
deploy/
  00_first_time_setup.sql       One-time infra: image repo, pool check, (future) DDL  (Snowsight)
  01_auto_deploy_sf.sh          Version bump + CHANGELOG + frontend build -> static/ (CoCo)
  02_build_image_laptop.py      Build + push image to the Snowflake registry         (laptop)
  02_build_image_laptop.ps1     Windows wrapper for 02                               (laptop)
  03_redeploy_sf.sql            Create/refresh the service with the new image        (Snowsight)
  04_verify_sf.sql              Post-deploy checks                                    (Snowsight)
  05_manage_access_sf.sql       Which Snowflake roles can open EE Ops                 (Snowsight)
  06_restart_service_sf.sql     Restart / stop / start / logs                         (Snowsight)
  sql/                          Idempotent DDL for EEOPS_* objects (none yet)
  LESSONS_LEARNED.md            Every pipeline pitfall hit so far, and its fix
```

| Item | Value |
|---|---|
| Account identifier (CLI) | `californiapublicutilitiescommission-cpuc_aws_us_west_2` (**not** `cpuc` — the display name makes the CLI hang) |
| Role / warehouse | `CPUC_ED_TITLE20_RL` / `CPUC_ED_TITLE20_S_WH` |
| Database / schema | `CPUC_ED_DB` / `ENERGY_EFFICIENCY` |
| Image repository | `CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_IMAGES` |
| Registry host | `californiapublicutilitiescommission-cpuc-aws-us-west-2.registry.snowflakecomputing.com` |
| Image | `/cpuc_ed_db/energy_efficiency/eeops_images/eeops-app:latest` |
| Service / container | `EEOPS_APP` / `eeops-app` (port 8080, health `/api/v1/health`) |
| Compute pool | `CPUC_ED_SNOWPARK_POOL` (shared with `CET_APP`, `CMS_APP`) |
| Workspace | `USER$.PUBLIC."eeops"` |

---

## Prerequisites (one time)

### Laptop (Windows, no admin rights, no Docker)
1. **Python 3.9+** — use `py` (if `python` opens the Microsoft Store, that's the alias).
2. **Snowflake CLI** (optional — only for `snow` commands; the build doesn't need it):
   ```powershell
   py -m pip install --user snowflake-cli
   ```
3. **CLI connection** (paste **one line at a time** in PowerShell — multi-line pastes mangle flags):
   ```powershell
   snow connection add --connection-name cpuc_sso --account californiapublicutilitiescommission-cpuc_aws_us_west_2 --user <your.email>@cpuc.ca.gov --role CPUC_ED_TITLE20_RL --warehouse CPUC_ED_TITLE20_S_WH --database CPUC_ED_DB --schema ENERGY_EFFICIENCY --authenticator externalbrowser --default --no-interactive
   ```
   ```powershell
   snow connection test -c cpuc_sso
   ```
4. **Programmatic Access Token (PAT)** for the image registry — session tokens
   get a silent `401`. Snowsight → profile → **Settings → Authentication →
   Programmatic access tokens → Generate new token**, restricted to role
   `CPUC_ED_TITLE20_RL`. Copy it (shown once). The build script reuses a PAT
   already saved by CET_2 / Canopy / CMS (`~/.snowflake/*_pat.json`), or
   prompts and offers to save it to `~/.snowflake/eeops_pat.json`.
5. **Clone the repo** (same GitHub repo the `eeops` workspace is connected to).

### Snowsight / CoCo
- Workspace `USER$.PUBLIC."eeops"` connected to the GitHub repo (Git panel).
- Role `CPUC_ED_TITLE20_RL`, warehouse `CPUC_ED_TITLE20_S_WH`.

---

## First deploy (once)

| # | Where | Do |
|---|---|---|
| 0 | Snowsight | Run `deploy/00_first_time_setup.sql` — creates image repo `EEOPS_IMAGES`, checks the pool. |
| 1–4 | — | Run the four standard steps below. **Step 3 creates the service** `EEOPS_APP` (`CREATE SERVICE IF NOT EXISTS`, then `ALTER`). |
| 5 | Snowsight | Run `deploy/05_manage_access_sf.sql` — grants the app's door (`EEOPS_APP!APP_USER`) to Snowflake roles. |

The first container start pulls the image (~1–3 min). The URL is the
`ingress_url` from `SHOW ENDPOINTS IN SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP;`
and stays the same across redeploys (it changes only if the service is dropped).

---

## Standard deploy (every change)

### Step 1 — Version bump + frontend build (CoCo)
```bash
bash /workspace/deploy/01_auto_deploy_sf.sh          # recommends patch/minor/major, then prompts
bash /workspace/deploy/01_auto_deploy_sf.sh --patch  # or force: --patch | --minor | --major
```
Detects changes against `.deploy_manifest.json`, bumps the version in
`frontend/package.json` **and** `eeops/__init__.py`, updates `CHANGELOG.md`,
builds the frontend in `$HOME/fe` (npm hangs on `/workspace`), fails if the
build references any external origin (CSP), and copies `dist/` into `static/`.
If it warns *"deploy/sql changed"*, run the changed `deploy/sql/*.sql` file(s)
in Snowsight before step 3 (they are idempotent).

**Version numbers** count like decimals and never roll over:
`0.8.0 → 0.9.0 → 0.91.0 → 0.92.0 … 0.99.0 → 0.991.0`; patch the same way
(`0.9.9 → 0.9.91`); major is a plain counter and resets the others.

Then **commit + push in the Snowsight Git panel** — include `static/` (new
hashed file names *and* the deletions of the old ones), `.deploy_manifest.json`,
`CHANGELOG.md`, `frontend/package.json`, `eeops/__init__.py`.

### Step 2 — Build and push the image (laptop)
```powershell
cd C:\Users\<you>\Code\eeops
```
```powershell
git pull
```
```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\02_build_image_laptop.ps1
```
(or `py deploy\02_build_image_laptop.py`). `git pull` must list `static/`
files — if it only shows docs, step 1 wasn't committed and the old UI would
ship. The script refuses to build if `static/version.json`,
`frontend/package.json` and `eeops/__init__.py` disagree.

| Flag | Effect |
|---|---|
| `--reuse-layer` | Re-push the existing layer **byte-for-byte** (retry a failed push only — code changes since are NOT included) |
| `--skip-push` | Build the layer only (dry run) |
| `--clear-pat` | Forget the saved EE Ops PAT and prompt again |

### Step 3 — Activate the new image (Snowsight)
Run `deploy/03_redeploy_sf.sql` (or ask CoCo: *"run deploy/03_redeploy_sf.sql"*).

> **SUSPEND/RESUME does NOT deploy.** The service pins the image digest from
> the last time its spec was applied. Only `ALTER SERVICE … FROM SPECIFICATION`
> re-resolves `:latest`.

### Step 4 — Verify (Snowsight, ~1 minute later)
Run `deploy/04_verify_sf.sql`: the running `image_digest` must equal the newest
digest in `SHOW IMAGES`, and the log must read `EE Ops backend v<new>, frontend v<new>`.
Then open the `ingress_url`, **hard-refresh** (Ctrl+Shift+R), and check:
- the banner/sidebar shows the new version;
- **CPUC Admin → System status** shows the same version three times (browser
  bundle, backend, bundle on server) and *Check Snowflake connection* succeeds;
- all six pages open.

```
┌──────────────────────────── CoCo (Snowsight) ────────────────────────────┐
│ bash deploy/01_auto_deploy_sf.sh --patch → bump, CHANGELOG, build, CSP    │
│ Git panel: commit + push (include static/ and .deploy_manifest.json)      │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │ git pull
┌───────────────────────────────▼──────── Laptop ──────────────────────────┐
│ py deploy/02_build_image_laptop.py → wheels + layer → crane push          │
└───────────────────────────────┬──────────────────────────────────────────┘
┌───────────────────────────────▼──────── Snowsight ───────────────────────┐
│ deploy/03_redeploy_sf.sql → CREATE IF NOT EXISTS + ALTER … FROM SPEC      │
│ deploy/04_verify_sf.sql   → digest, version log, errors, endpoint         │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Restarting the container

`deploy/06_restart_service_sf.sql`, one section at a time:

| Need | Section |
|---|---|
| Container stuck/unhealthy, same code | **A** — `SUSPEND` then `RESUME` (same image) |
| Pick up a newly pushed image | **B** — run `03_redeploy_sf.sql` |
| Why did it crash? | **C** — current and previous-container logs |
| Stop billing / start again | **D** — `SUSPEND`; opening the URL auto-resumes it |
| Status | **E** — containers, endpoint, pool |

---

## Access

`deploy/05_manage_access_sf.sql`: the SPCS ingress lets a user in only if one
of their Snowflake roles holds `EEOPS_APP!APP_USER`.
`GRANT SERVICE ROLE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP!APP_USER TO ROLE <role>;`
Takes effect immediately. Sign-out goes to `/sfc-endpoint/logout`.

---

## Common issues

| Problem | Fix |
|---|---|
| 401 pushing the image | PAT expired, or a session token was used → `py deploy\02_build_image_laptop.py --clear-pat` |
| PAT also 401 / `PAT_USER_MISMATCH` in login history | Use your LOGIN_NAME (email), not the short user name (`DESCRIBE USER <you>`) |
| `py` / `snow` not found on Windows | `py -m pip install --user snowflake-cli`; use `py`, not `python` |
| PowerShell blocks the `.ps1` | Use `-ExecutionPolicy Bypass` as shown (no admin needed) |
| 01 says "No changes detected" | Nothing changed since the last manifest. To force: delete `.deploy_manifest.json` and re-run |
| 01 fails "CSP" | The build loads something from another origin. Self-host it (npm package or `frontend/public/`) |
| Old UI after deploy | Step 1 not committed/pulled, `--reuse-layer` after code changes, or no hard-refresh |
| Service doesn't exist (first deploy) | Run `03` — it creates the service. `04` will error until then |
| Service stuck PENDING | Pool at capacity → `DESCRIBE COMPUTE POOL CPUC_ED_SNOWPARK_POOL`; logs via `06` C |
| `restart_count` climbing | Crash loop → `06` section C (previous-container logs) |
| User gets "not authorized" on the URL | Their role lacks `EEOPS_APP!APP_USER` → `05` |
| "does not exist or not authorized" inside the app | A `deploy/sql` file wasn't run, or the object isn't `EEOPS_`-prefixed as the code expects |
| Console: "violates the following Content Security Policy directive" | Something loads from another origin — see the 01 CSP row |
| API 404 from the browser | Frontend path and backend route differ, or the router isn't included in `api/main.py` |
