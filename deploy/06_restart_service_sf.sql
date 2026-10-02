-- ==========================================================================
-- 06 -- Restart, stop, start, and troubleshoot the EE Ops container
-- ==========================================================================
-- Run one section at a time (select it, then Run). Ask CoCo, e.g.:
-- "run section A of deploy/06_restart_service_sf.sql".
--
--   A. Restart the SAME image          (container stuck / unhealthy)
--   B. Restart on the NEWEST image     (= deploy; runs 03)
--   C. Logs                            (current + previous crashed container)
--   D. Stop billing / start again      (cost control)
--   E. Status at a glance
--
-- There is no ALTER SERVICE ... RESTART. SUSPEND then RESUME recreates the
-- containers from the image digest pinned by the last spec apply -- it never
-- picks up a newly pushed :latest. To deploy new code use B (03).
-- ==========================================================================

USE ROLE CPUC_ED_TITLE20_RL;

-- --------------------------------------------------------------------------
-- A. Restart the same image
-- --------------------------------------------------------------------------
ALTER SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP SUSPEND;
-- wait until SHOW SERVICES shows status SUSPENDED (a few seconds), then:
ALTER SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP RESUME;
-- ~1 minute later, confirm READY:
SHOW SERVICE CONTAINERS IN SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP;

-- --------------------------------------------------------------------------
-- B. Restart on the newest pushed image
-- --------------------------------------------------------------------------
-- Run deploy/03_redeploy_sf.sql (ALTER SERVICE ... FROM SPECIFICATION).
-- Re-applying the spec re-resolves eeops-app:latest and restarts the container.

-- --------------------------------------------------------------------------
-- C. Logs
-- --------------------------------------------------------------------------
-- Current container, last 200 lines, one row per line:
SELECT value AS log_line
FROM TABLE(SPLIT_TO_TABLE(
  SYSTEM$GET_SERVICE_LOGS('CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP', 0, 'eeops-app', 200), '\n'));

-- Previous container (after a crash/restart -- errors only if restart_count = 0):
SELECT value AS log_line
FROM TABLE(SPLIT_TO_TABLE(
  SYSTEM$GET_SERVICE_LOGS('CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP', 0, 'eeops-app', 200, TRUE), '\n'));

-- --------------------------------------------------------------------------
-- D. Stop billing / start again
-- --------------------------------------------------------------------------
-- Stop (containers deleted, URL kept):
--   ALTER SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP SUSPEND;
-- Start: either run RESUME, or just open the app URL -- AUTO_RESUME is TRUE
-- by default, so the first ingress request resumes it (first load is slow).
--   ALTER SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP RESUME;
-- Optional idle auto-suspend (preview feature, minimum 300 s):
--   ALTER SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP SET AUTO_SUSPEND_SECS = 3600;

-- --------------------------------------------------------------------------
-- E. Status at a glance
-- --------------------------------------------------------------------------
SHOW SERVICES LIKE 'EEOPS_APP' IN SCHEMA CPUC_ED_DB.ENERGY_EFFICIENCY;
SHOW SERVICE CONTAINERS IN SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP;
SHOW ENDPOINTS IN SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP;
-- Pool pressure (service stuck PENDING = pool at capacity):
DESCRIBE COMPUTE POOL CPUC_ED_SNOWPARK_POOL;
