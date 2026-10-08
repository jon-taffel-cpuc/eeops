# deploy/sql — EE Ops schema files

| File | What | Run |
|---|---|---|
| `11_interval_tables.sql` | Interval page: `EEOPS_PGE_*` copy + lookups, refresh procedure, monthly task (suspended) | From `00` section 3, or on its own; idempotent |
| `12_interval_initial_load.sql` | One-time sorted load of the PG&E interval copy (scans the 6 TB share) | **By hand**, section by section; needs the admin steps in its section A |
| `13_interval_test_batch.sql` | Test batch: two ZIPs, full history, on the Small warehouse; refuses to overwrite a full load | **By hand**, Run All (~1.5 h) |
| `14_raw_landing.sql` | `EEOPS_RAW` stage (`parcels/`, `weather/`, ...) + CSV/Parquet file formats for uploads | Idempotent; from `00` section 3 or on its own |

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
  Exception: one-time data loads like `12` are run by hand, never from `00`.
- `deploy/01_auto_deploy_sf.sh` flags changes here as schema changes and
  reminds you to run the changed file in Snowsight **before** step 3.
- Snowflake does not enforce CHECK / FK constraints. Validate in the API.
