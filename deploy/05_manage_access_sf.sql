-- ==========================================================================
-- 05 -- Access: which Snowflake roles can open EE Ops
-- ==========================================================================
-- The SPCS ingress signs the user in with Snowflake (CPUC SSO) and only lets
-- them through if one of their roles holds the service role
-- EEOPS_APP!APP_USER. There is no separate app login and no app-level role
-- table yet; the API sees the user name in the Sf-Context-Current-User header.
--
-- Run once after the first 03_redeploy_sf.sql, and again whenever a team or
-- role needs access. Changes apply immediately -- no redeploy.
-- Ask CoCo: "run deploy/05_manage_access_sf.sql".
-- ==========================================================================

USE ROLE CPUC_ED_TITLE20_RL;

-- The owner role (CPUC_ED_TITLE20_RL) can already reach the endpoint; the
-- explicit grant documents it. Add one GRANT per additional Snowflake role.
GRANT SERVICE ROLE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP!APP_USER TO ROLE CPUC_ED_TITLE20_RL;
-- GRANT SERVICE ROLE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP!APP_USER TO ROLE <ANOTHER_ED_ROLE>;

-- Revoke:
--   REVOKE SERVICE ROLE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP!APP_USER FROM ROLE <ROLE>;

-- Review: which roles hold the door, and which users hold those roles
SHOW GRANTS OF SERVICE ROLE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_APP!APP_USER;
SHOW GRANTS OF ROLE CPUC_ED_TITLE20_RL;

-- Later (when CPUC Admin needs in-app roles): follow Canopy's pattern --
-- an EEOPS_PROFILES table keyed by Snowflake user name, managed from this
-- file with MERGE, and looked up in api/deps.py. See Canopy
-- deploy/05_manage_access_sf.sql section B.
