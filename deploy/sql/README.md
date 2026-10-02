# deploy/sql — EE Ops schema files

No tables yet. When a page needs persistent data, add files here.

## Conventions (same as Canopy)

- **Prefix every object `EEOPS_`.** `CPUC_ED_DB.ENERGY_EFFICIENCY` is shared
  with CET_APP (`CETJOBS`, `OUTPUT*`, `E3*`), CMS_APP and Canopy (`CANOPY_*`).
  Never create, alter or drop an unprefixed object or another app's tables.
- **Idempotent only:** `CREATE ... IF NOT EXISTS`,
  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`. Never `DROP` or
  `CREATE OR REPLACE` an `EEOPS_*` table (it destroys data).
- **Numbered by area:** `10_eeops_tables.sql`, `11_<area>_tables.sql`, ...
- Add each new file to section 3 of `deploy/00_first_time_setup.sql`
  (`EXECUTE IMMEDIATE FROM 'snow://workspace/USER$.PUBLIC."eeops"/versions/live/deploy/sql/<file>'`).
- `deploy/01_auto_deploy_sf.sh` flags changes here as schema changes and
  reminds you to run the changed file in Snowsight **before** step 3.
- Snowflake does not enforce CHECK / FK constraints. Validate in the API.
