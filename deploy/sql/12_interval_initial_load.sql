-- ==========================================================================
-- 12 -- Interval page: ONE-TIME load of the PG&E electric interval copy
-- ==========================================================================
-- NOT run by 00_first_time_setup.sql: it reads the whole ~6 TB / ~449 B row
-- Recurve share once and writes it back sorted, which costs real credits and
-- takes hours. Run it by hand in Snowsight, section by section, after
-- deploy/sql/11_interval_tables.sql has created the objects.
--
-- Why a full scan is unavoidable: the share has no clustering key and every
-- micro-partition spans nearly every meter AND every date (see 11's header),
-- so neither a meter filter nor a date filter prunes anything. P_SINCE and
-- P_ZIPS (below) therefore do NOT make the scan cheaper -- they only shrink
-- the sort and the copy.
--
-- Measured Oct 2026 (0.1% block samples on CPUC_ED_TITLE20_S_WH, Small;
-- aggregates only): ~5.4 GB per 0.1% => a full scan of all columns is
-- ~85 min on the Small (~3 credits), METERID alone ~35 min. In a 0.1%
-- sample the median meter has 56 rows on 56 different days spread over
-- ~6 years -- rows are scattered uniformly, so a SAMPLE of the share gives
-- no usable per-meter history; a test batch must filter by meter (ZIP).
-- Data: intervals 2018-04-01 .. 2025-03-31; INTERVALENGTH is seconds,
-- mostly 3600 (hourly, ~84% of meters) or 900 (15-min); none estimated.
--
-- Sections:
--   B. TEST BATCH on the Small: two ZIPs (~7k meters), proves the pipeline
--   C. Check the result (no customer data is selected -- counts/metadata only)
--   D. Optional: search optimization on the address index
--   A. Admin (SYSADMIN / ACCOUNTADMIN): larger warehouse + task privilege
--   E. Full-history load (when the test batch looks right)
--   F. Afterwards: shrink the warehouse, resume the monthly DELTA task
-- ==========================================================================


-- --------------------------------------------------------------------------
-- A. Admin -- only needed for E/F. Run ONCE as SYSADMIN (warehouse) and
--    ACCOUNTADMIN (task grant).
-- --------------------------------------------------------------------------
-- The scan itself is fine on the Small (above). What the Small can't do
-- well is the FULL sort of ~449 B rows: little memory, so it spills to
-- remote storage, and the one INSERT OVERWRITE must finish inside the 48 h
-- statement timeout or all of it is lost. It would also hog the single-
-- cluster warehouse that CET_APP and CMS_APP use. Standard rates: X-Large
-- 16 credits/h, 2X-Large 32. Bigger finishes the same work proportionally
-- faster, so total cost is similar. Watch the run in Query History; if the
-- profile shows heavy "Bytes spilled to remote storage", go one size up.
--
-- USE ROLE SYSADMIN;
-- CREATE WAREHOUSE IF NOT EXISTS EEOPS_INTERVAL_LOAD_WH
--   WAREHOUSE_SIZE = '2X-LARGE'
--   AUTO_SUSPEND = 60
--   AUTO_RESUME = TRUE
--   INITIALLY_SUSPENDED = TRUE
--   STATEMENT_TIMEOUT_IN_SECONDS = 172800      -- 48 h cap for the FULL load
--   COMMENT = 'EE Ops Interval: loads/refreshes EEOPS_PGE_ELEC_INTERVAL from the Recurve AMI share';
-- GRANT USAGE, OPERATE, MODIFY ON WAREHOUSE EEOPS_INTERVAL_LOAD_WH TO ROLE CPUC_ED_TITLE20_RL;
--
-- The monthly DELTA task (created SUSPENDED in 11) can only run if the
-- owning role may execute tasks:
-- USE ROLE ACCOUNTADMIN;
-- GRANT EXECUTE TASK ON ACCOUNT TO ROLE CPUC_ED_TITLE20_RL;


-- --------------------------------------------------------------------------
-- B. TEST BATCH -- every premise in two ZIPs, full history, on the Small.
--    Standalone, guarded version: deploy/sql/13_interval_test_batch.sql
--    (prefer that -- it refuses to overwrite a full load).
-- --------------------------------------------------------------------------
-- 93241 (~3.9k linked meters) + 93250 (~3.2k): ~0.1% of the interval rows.
-- Cost is dominated by the one full scan of the share: expect ~1.5 h and
-- ~3 credits on the Small (extrapolated from the samples -- not yet
-- measured end to end). The sort/write is tiny. The scan saturates the
-- Small, so CET_APP / CMS_APP queries slow down while it runs -- prefer
-- after hours. Any ZIP list works; the step-1 log row records it.
USE ROLE CPUC_ED_TITLE20_RL;
USE WAREHOUSE CPUC_ED_TITLE20_S_WH;
USE SCHEMA CPUC_ED_DB.ENERGY_EFFICIENCY;

-- Keep this tab open until it returns. Progress, step by step:
--   SELECT * FROM EEOPS_INTERVAL_REFRESH_LOG ORDER BY LOGGED_AT DESC LIMIT 20;
CALL CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_REFRESH_PGE_INTERVAL('FULL', NULL, '93241,93250');


-- --------------------------------------------------------------------------
-- C. Check the result (counts and metadata only).
-- --------------------------------------------------------------------------
-- Every step OK, last step DONE:
SELECT STEP, STATUS, ROWS_AFFECTED, LOGGED_AT, DETAIL
  FROM CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_REFRESH_LOG
 ORDER BY LOGGED_AT DESC
 LIMIT 10;

-- Sizes of the copy and the lookups:
SELECT TABLE_NAME, ROW_COUNT, ROUND(BYTES / POWER(1024, 3), 1) AS GB
  FROM CPUC_ED_DB.INFORMATION_SCHEMA.TABLES
 WHERE TABLE_SCHEMA = 'ENERGY_EFFICIENCY' AND TABLE_NAME LIKE 'EEOPS\\_PGE\\_%' ESCAPE '\\'
 ORDER BY TABLE_NAME;

-- THE important number: how many micro-partitions overlap any one meter.
-- Expect average_depth of about 1-3 (the share's is ~332,000). If it's much
-- higher, the ORDER BY didn't take -- don't point users at the page yet.
SELECT SYSTEM$CLUSTERING_INFORMATION(
  'CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_ELEC_INTERVAL', '(METER_KEY)');

-- Then open the Interval page, search an address, and check the query in
-- Query History: "Partitions scanned" should be single digits.


-- --------------------------------------------------------------------------
-- D. Optional: search optimization for the address bar.
-- --------------------------------------------------------------------------
-- Without it, each keystroke-search scans EEOPS_PGE_PREMISE's SEARCH_TEXT
-- column (a few hundred MB at most -- ~1 s on the Small warehouse). With
-- it, words of 5+ characters (street names, 5-digit ZIPs) are served from a
-- search access path in well under a second. It has a small background
-- maintenance cost each time the table is rebuilt (every refresh).
-- Requires Enterprise Edition.
-- ALTER TABLE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_PREMISE
--   ADD SEARCH OPTIMIZATION ON SUBSTRING(SEARCH_TEXT);
-- DESCRIBE SEARCH OPTIMIZATION ON CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_PREMISE;


-- --------------------------------------------------------------------------
-- E. Full-history load (same scan as B, much bigger sort -- needs A).
--    Data covers 2018-04-01 .. 2025-03-31; pass a P_SINCE to load less, or
--    NULL for everything. Replaces the test batch (no P_ZIPS = all meters).
-- --------------------------------------------------------------------------
-- USE WAREHOUSE EEOPS_INTERVAL_LOAD_WH;
-- ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS = 172800;
-- CALL CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_REFRESH_PGE_INTERVAL('FULL', NULL);
-- Then re-run section C.


-- --------------------------------------------------------------------------
-- F. Afterwards
-- --------------------------------------------------------------------------
-- The monthly DELTA reads the whole share again (it has no change tracking)
-- but writes only new rows, so a Large is enough. As SYSADMIN:
-- ALTER WAREHOUSE EEOPS_INTERVAL_LOAD_WH SET WAREHOUSE_SIZE = 'LARGE';
--
-- As CPUC_ED_TITLE20_RL (needs EXECUTE TASK from section A):
-- ALTER TASK CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_REFRESH_PGE_INTERVAL_TASK
--   SET WAREHOUSE = EEOPS_INTERVAL_LOAD_WH;
-- ALTER TASK CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_REFRESH_PGE_INTERVAL_TASK RESUME;
--
-- Each DELTA appends one sorted batch, so a meter's rows end up spread over
-- one extra micro-partition per month. Re-check section C's average_depth
-- every few months; when it climbs past ~20, run FULL (E) to compact.
