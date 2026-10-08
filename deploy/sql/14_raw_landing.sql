-- ==========================================================================
-- 14 -- Raw landing zone for uploaded source data (parcels, weather, ...)
-- ==========================================================================
-- Idempotent (CREATE ... IF NOT EXISTS). Creates an empty internal stage and
-- two file formats; nothing is loaded here.
--
-- WHERE TO PUT FILES
--   @CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_RAW/parcels/...
--   @CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_RAW/weather/...
--   (one folder per source; add more, e.g. claims/, as needed)
--
-- HOW TO UPLOAD
--   * Files <= 250 MB: Snowsight -> Ingestion -> Add Data -> "Load files into
--     a Stage" -> CPUC_ED_DB / ENERGY_EFFICIENCY / EEOPS_RAW, path parcels/.
--   * Bigger files: split them (100-250 MB each also loads fastest), or PUT
--     from the laptop with the same connection 02_build_image_laptop.py uses:
--       PUT file://C:/data/parcels/*.parquet @CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_RAW/parcels/
--           AUTO_COMPRESS = FALSE;      -- TRUE for CSV (gzips it)
--   * NOT the workspace: workspace files sync to git.
--
-- FORMATS: Parquet preferred (typed, compressed, INFER_SCHEMA reads its
-- columns). CSV fine (gzip it). For parcel geometry, a WKT/WKB column or
-- GeoParquet loads into a GEOGRAPHY column.
--
-- Encryption is server-side (SNOWFLAKE_SSE) so staged files can be listed,
-- previewed and downloaded in Snowsight; the directory table is refreshed
-- by hand: ALTER STAGE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_RAW REFRESH;
-- ==========================================================================

USE ROLE CPUC_ED_TITLE20_RL;
USE SCHEMA CPUC_ED_DB.ENERGY_EFFICIENCY;

CREATE STAGE IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_RAW
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'EE Ops: raw uploads (parcels/, weather/, ...) before COPY INTO EEOPS_ tables. Not for app reads.';

-- CSV with a header row; PARSE_HEADER lets INFER_SCHEMA name the columns.
CREATE FILE FORMAT IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_CSV_HEADER
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL', 'NA', 'N/A')
  EMPTY_FIELD_AS_NULL = TRUE
  TRIM_SPACE = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE
  COMMENT = 'EE Ops: header CSV (gzip or plain) for INFER_SCHEMA / COPY INTO';

CREATE FILE FORMAT IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PARQUET
  TYPE = PARQUET
  COMMENT = 'EE Ops: Parquet for INFER_SCHEMA / COPY INTO';

SHOW STAGES LIKE 'EEOPS_RAW' IN SCHEMA CPUC_ED_DB.ENERGY_EFFICIENCY;

-- After uploading, see what landed (file names and sizes only):
--   ALTER STAGE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_RAW REFRESH;
--   SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED
--     FROM DIRECTORY(@CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_RAW) ORDER BY 1;
-- Then the target tables (EEOPS_PARCEL, EEOPS_WEATHER_DAILY) get their own
-- deploy/sql file, with columns taken from INFER_SCHEMA on the real files.
