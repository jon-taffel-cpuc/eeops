-- ==========================================================================
-- 00 -- First-time setup for EE Ops on SPCS (run ONCE, in Snowsight)
-- ==========================================================================
-- Creates what the app needs *before* the first image is pushed:
--   1. Image repository            CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_IMAGES
--   2. Compute pool check          CPUC_ED_SNOWPARK_POOL (shared with CET_APP, CMS_APP)
--   3. Schema objects              deploy/sql/1x_*.sql (none yet -- see below)
--
-- The SERVICE itself is created by 03_redeploy_sf.sql once an image exists
-- (CREATE SERVICE needs a pushed image; 03 does CREATE IF NOT EXISTS + ALTER).
-- Every statement is idempotent -- safe to re-run.
--
-- Run as CPUC_ED_TITLE20_RL (the role that owns ENERGY_EFFICIENCY objects).
-- Ask CoCo: "run deploy/00_first_time_setup.sql".
-- ==========================================================================

USE ROLE CPUC_ED_TITLE20_RL;
USE WAREHOUSE CPUC_ED_TITLE20_S_WH;
USE SCHEMA CPUC_ED_DB.ENERGY_EFFICIENCY;

-- 1. Image repository -------------------------------------------------------
CREATE IMAGE REPOSITORY IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_IMAGES
  COMMENT = 'EE Ops web app images (eeops-app:latest)';
SHOW IMAGE REPOSITORIES LIKE 'EEOPS_IMAGES' IN SCHEMA CPUC_ED_DB.ENERGY_EFFICIENCY;
-- repository_url must match REGISTRY/IMAGE in deploy/02_build_image_laptop.py:
--   californiapublicutilitiescommission-cpuc-aws-us-west-2.registry.snowflakecomputing.com/cpuc_ed_db/energy_efficiency/eeops_images

-- 2. Compute pool -----------------------------------------------------------
-- EE Ops shares the ED pool with CET_APP and CMS_APP (CPU_X64_XS, 1-3 nodes,
-- auto-resume). SYSTEM_COMPUTE_POOL_CPU rejects general services -- do not use it.
-- If the pool is ever missing, an ACCOUNTADMIN must run:
--   CREATE COMPUTE POOL CPUC_ED_SNOWPARK_POOL MIN_NODES = 1 MAX_NODES = 3
--     INSTANCE_FAMILY = CPU_X64_XS AUTO_RESUME = TRUE AUTO_SUSPEND_SECS = 3600;
--   GRANT USAGE, MONITOR ON COMPUTE POOL CPUC_ED_SNOWPARK_POOL TO ROLE CPUC_ED_TITLE20_RL;
DESCRIBE COMPUTE POOL CPUC_ED_SNOWPARK_POOL;
SHOW SERVICES IN COMPUTE POOL CPUC_ED_SNOWPARK_POOL;

-- 3. Schema objects ---------------------------------------------------------
-- None yet. When a page needs tables, add an idempotent file under
-- deploy/sql/ (see deploy/sql/README.md) and run it from here, e.g.:
-- EXECUTE IMMEDIATE FROM 'snow://workspace/USER$.PUBLIC."eeops"/versions/live/deploy/sql/10_eeops_tables.sql';
-- (The workspace name is lower-case "eeops", so it must stay double-quoted.)

-- Next: 01_auto_deploy_sf.sh (CoCo) -> 02 (laptop) -> 03 -> 05 -> 04.

-- ==========================================================================
-- Maintenance (ad hoc, not part of a deploy) -- see 06_restart_service_sf.sql
-- ==========================================================================
-- Drop entirely (endpoint URL changes if re-created):
--   DROP SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP;
