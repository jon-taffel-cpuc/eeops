-- ==========================================================================
-- 04 -- Verify the deploy landed (Snowsight, ~1 minute after 03)
-- ==========================================================================
-- Ask CoCo: "run deploy/04_verify_sf.sql".
-- Checks: (1) registry has the new image, (2) the container runs that digest,
-- (3) the startup log shows the new version, (4) no errors, (5) the URL.

-- 1. What's in the registry? (newest digest at the top)
SHOW IMAGES IN IMAGE REPOSITORY CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_IMAGES;

-- 2. What digest is the container running? image_digest must match the digest
--    above, and status should be READY. (SYSTEM$GET_SERVICE_STATUS is
--    deprecated -- this is its replacement.) restart_count > 0 = crash loop;
--    see 06_restart_service_sf.sql section C for previous-container logs.
SHOW SERVICE CONTAINERS IN SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP;

-- 3. What version did the app log at startup?
--    Expect: "EE Ops backend v<new>, frontend v<new>"
SELECT REGEXP_SUBSTR(
  SYSTEM$GET_SERVICE_LOGS('CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP', 0, 'eeops-app', 1000),
  'EE Ops backend[^\n]*') AS running_version;

-- 4. Recent errors, if any (empty = good)
SELECT REGEXP_SUBSTR_ALL(
  SYSTEM$GET_SERVICE_LOGS('CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP', 0, 'eeops-app', 500),
  '[^\n]*(Error|Traceback|failed)[^\n]*') AS recent_errors;

-- 5. Public URL (open it, then hard-refresh with Ctrl+Shift+R)
SHOW ENDPOINTS IN SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP;

-- Manual checks in the browser:
--   - Banner and sidebar read "EE Ops v<the version you bumped to>"
--   - https://<ingress_url>/api/v1/health returns {"status":"ok","version":...}
--   - CPUC Admin page -> System status: browser bundle, backend and bundle on
--     server all show the same version; "Check Snowflake connection" succeeds
--   - Click through all six pages
