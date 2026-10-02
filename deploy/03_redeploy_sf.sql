-- ==========================================================================
-- 03 -- Activate the newly pushed eeops-app:latest image (Snowsight)
-- ==========================================================================
-- Run after 02_build_image_laptop pushes a new image. Ask CoCo:
-- "run deploy/03_redeploy_sf.sql".
--
-- First deploy: CREATE SERVICE builds the service from the spec below.
-- Every deploy: ALTER SERVICE ... FROM SPECIFICATION re-resolves :latest.
--   (CMS lesson: an ALTER-only 03 fails on the first deploy because the
--    service doesn't exist yet -- hence CREATE ... IF NOT EXISTS first.)
--
-- SUSPEND/RESUME does NOT deploy -- the service pins the image *digest* at
-- the time the spec was last applied; only re-applying the spec picks up the
-- new image. KEEP THE TWO SPEC BLOCKS BELOW IDENTICAL.
--
-- Spec notes
--   * serviceRoles app_user: Snowflake roles allowed to open the app are
--     granted EEOPS_APP!APP_USER in 05_manage_access_sf.sql.
--   * The ingress signs users in with Snowflake and adds the header
--     Sf-Context-Current-User, which the API uses as the user identity.
--   * Resources are sized for the scaffold (FastAPI + static SPA). The pool
--     is shared with CET_APP and CMS_APP; raise requests only when a page
--     needs it (e.g. pandas work), in BOTH blocks.
-- ==========================================================================

USE ROLE CPUC_ED_TITLE20_RL;

CREATE SERVICE IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP
  IN COMPUTE POOL CPUC_ED_SNOWPARK_POOL
  FROM SPECIFICATION $$
spec:
  containers:
  - name: eeops-app
    image: /cpuc_ed_db/energy_efficiency/eeops_images/eeops-app:latest
    env:
      EEOPS_DATABASE: CPUC_ED_DB
      EEOPS_SCHEMA: ENERGY_EFFICIENCY
      EEOPS_WAREHOUSE: CPUC_ED_TITLE20_S_WH
    readinessProbe:
      port: 8080
      path: /api/v1/health
    resources:
      requests: {memory: 1G, cpu: 0.25}
      limits: {memory: 2G, cpu: 1}
  endpoints:
  - name: app
    port: 8080
    public: true
serviceRoles:
- name: app_user
  endpoints:
  - app
$$
  QUERY_WAREHOUSE = CPUC_ED_TITLE20_S_WH
  MIN_INSTANCES = 1 MAX_INSTANCES = 1
  COMMENT = 'EE Ops - CPUC Energy Division internal operations app';

ALTER SERVICE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP FROM SPECIFICATION $$
spec:
  containers:
  - name: eeops-app
    image: /cpuc_ed_db/energy_efficiency/eeops_images/eeops-app:latest
    env:
      EEOPS_DATABASE: CPUC_ED_DB
      EEOPS_SCHEMA: ENERGY_EFFICIENCY
      EEOPS_WAREHOUSE: CPUC_ED_TITLE20_S_WH
    readinessProbe:
      port: 8080
      path: /api/v1/health
    resources:
      requests: {memory: 1G, cpu: 0.25}
      limits: {memory: 2G, cpu: 1}
  endpoints:
  - name: app
    port: 8080
    public: true
serviceRoles:
- name: app_user
  endpoints:
  - app
$$;

-- Service restarts. Wait ~1 min, then run 04_verify_sf.sql.
-- First deploy only: run 05_manage_access_sf.sql once to let users in.
