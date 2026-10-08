-- ==========================================================================
-- 13 -- Interval page: TEST BATCH load (two ZIP codes, full history)
-- ==========================================================================
-- HOW TO RUN: open this file in Snowsight and click "Run All". Leave the tab
-- open until the last result appears (~1.5 h). Nothing else is needed --
-- no admin, no other warehouse, no other file.
--
-- WHAT IT DOES
--   Loads every PG&E premise in ZIPs 93241 and 93250 (~7,100 meters, full
--   2018-2025 history) into the EE Ops interval tables, then shows checks.
--   The share has no clustering, so this reads the whole Recurve table once
--   (~85 min on the Small, ~3 credits, measured from samples); the sort and
--   write are tiny.
--
-- WHAT IT TOUCHES -- and nothing else:
--   writes:  CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER
--            CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_ELEC_INTERVAL
--            CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_PREMISE_METER
--            CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_PREMISE
--            CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_REFRESH_LOG
--   reads:   EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC (read-only share)
--   No other app's tables, no DDL, no grants, no tasks resumed.
--
-- SAFETY
--   * Refuses to run if EEOPS_PGE_METER already holds more than a test
--     batch (> 50,000 meters) -- so it can never overwrite a full load.
--   * Re-running it is safe: it rebuilds the same test batch.
--   * Statements are capped at 4 h for this session, so a surprise can't
--     tie up the shared Small warehouse for the default 48 h.
--   * The scan uses the whole Small warehouse while it runs, so CET_APP /
--     CMS_APP queries slow down -- prefer after hours.
--   * Results below are counts and metadata only -- no addresses or usage.
--
-- To stop it: Snowsight Query History -> select the running query -> Cancel.
-- A cancelled run changes nothing (each step is all-or-nothing).
-- ==========================================================================

USE ROLE CPUC_ED_TITLE20_RL;
USE WAREHOUSE CPUC_ED_TITLE20_S_WH;
USE SCHEMA CPUC_ED_DB.ENERGY_EFFICIENCY;
ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS = 14400;   -- 4 h cap, this session only
ALTER SESSION SET QUERY_TAG = 'eeops_interval_test_batch';

-- 1. Guard + load (one block, so the load can't run if the guard fails).
EXECUTE IMMEDIATE $$
DECLARE
  already_full EXCEPTION (-20001, 'EEOPS_PGE_METER holds more than a test batch -- not overwriting it. Use 12_interval_initial_load.sql section E instead.');
  n_meters NUMBER;
  result   VARCHAR;
BEGIN
  SELECT COUNT(*) INTO :n_meters FROM CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER;
  IF (n_meters > 50000) THEN
    RAISE already_full;
  END IF;
  CALL CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_REFRESH_PGE_INTERVAL('FULL', NULL, '93241,93250') INTO :result;
  RETURN result;
END;
$$;

-- 2. Every step should be OK; the newest row should be DONE.
SELECT STEP, STATUS, ROWS_AFFECTED, LOGGED_AT, DETAIL
  FROM CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_REFRESH_LOG
 ORDER BY LOGGED_AT DESC
 LIMIT 10;

-- 3. Size of what was loaded (expect ~7k meters, a few thousand premises,
--    and a few hundred million interval rows at most).
SELECT (SELECT COUNT(*) FROM EEOPS_PGE_METER)                              AS meters,
       (SELECT COUNT(*) FROM EEOPS_PGE_METER WHERE INTERVAL_ROWS > 0)      AS meters_with_data,
       (SELECT COUNT(*) FROM EEOPS_PGE_PREMISE)                            AS premises_searchable,
       (SELECT COUNT(*) FROM EEOPS_PGE_ELEC_INTERVAL)                      AS interval_rows,
       (SELECT MIN(INTERVALENDTIME) FROM EEOPS_PGE_ELEC_INTERVAL)          AS first_interval,
       (SELECT MAX(INTERVALENDTIME) FROM EEOPS_PGE_ELEC_INTERVAL)          AS last_interval;

-- 4. The number that proves the design: micro-partitions overlapping a
--    meter. Look at "average_depth" -- expect about 1-3 (the share's is
--    ~332,000). With a small test batch the table may be only a few
--    partitions in total, which is fine.
SELECT SYSTEM$CLUSTERING_INFORMATION(
  'CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_ELEC_INTERVAL', '(METER_KEY)') AS clustering;

ALTER SESSION UNSET QUERY_TAG;
ALTER SESSION UNSET STATEMENT_TIMEOUT_IN_SECONDS;
