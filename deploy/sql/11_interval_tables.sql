-- ==========================================================================
-- 11 -- Interval page: re-sorted PG&E electric AMI interval copy + lookups
-- ==========================================================================
-- Idempotent (CREATE ... IF NOT EXISTS; the procedure is CREATE OR REPLACE,
-- which never touches data). Run from 00_first_time_setup.sql section 3, or
-- on its own in Snowsight as CPUC_ED_TITLE20_RL. Creating these objects is
-- cheap; LOADING them is not -- see deploy/sql/12_interval_initial_load.sql.
--
-- WHY A COPY (measured with metadata only, Oct 2026):
--   EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC.RECURVE_ELEC_CONSUMPTION_INTERVAL_PGE
--   is ~449 billion rows / ~6 TB in 332,985 micro-partitions with no
--   clustering key. SYSTEM$CLUSTERING_INFORMATION average depth:
--       METERID              332,215 / 332,985
--       INTERVALENDTIME      306,334 / 332,985
--       RECORDSTAGEDATETIME  306,400 / 332,985
--   i.e. every partition spans (nearly) every meter and every date, so NO
--   filter prunes: one address's interval data = a full 6 TB scan, every
--   time, for every user. Change tracking is OFF on the share, so a consumer
--   can't build dynamic tables / streams / incremental MVs on it either.
--
-- THE FIX: scan the share once per refresh and keep an EE Ops copy that is
--   * keyed by a small integer METER_KEY instead of the VARCHAR METERID
--     (exact integer min/max pruning, better compression, and raw meter IDs
--     never leave the lookup table),
--   * physically sorted by (METER_KEY, INTERVALENDTIME) -- every load is an
--     INSERT ... ORDER BY, so one meter's whole history sits in ~1-3
--     micro-partitions (plus ~1 per later DELTA batch, each also sorted). A
--     year of 15-minute data becomes a point lookup (milliseconds) instead
--     of a 6 TB scan.
--   * NOT given a CLUSTER BY: tables clustered after Sep 2026 use Optima
--     Clustering, billed per GB ingested, so a key would charge again for
--     every reload of data the ORDER BY already sorted. If DELTA batches
--     ever fragment it, re-run FULL (it rewrites the table in order).
--   * TRANSIENT with 1-day Time Travel: it is a derived copy that can always
--     be rebuilt from the share, so it skips the 7-day Fail-safe that would
--     otherwise keep every overwritten multi-TB version billable for a week.
--   * fronted by small address/premise->meter lookups, so the address bar
--     never touches the 82M-row RECURVE_ID_RELATIONS or 21M-row
--     RECURVE_PREMISE at request time.
--
-- PII: these tables hold customer addresses and consumption. Only
-- CPUC_ED_TITLE20_RL (and SYSADMIN, the schema owner) have USAGE on
-- CPUC_ED_DB.ENERGY_EFFICIENCY today -- re-check before granting the schema
-- to anyone else.
-- ==========================================================================

USE ROLE CPUC_ED_TITLE20_RL;
USE SCHEMA CPUC_ED_DB.ENERGY_EFFICIENCY;

-- Surrogate integer key per PG&E meter -------------------------------------
CREATE SEQUENCE IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER_SEQ
  COMMENT = 'EE Ops Interval: METER_KEY values for EEOPS_PGE_METER';

CREATE TABLE IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER (
  METER_KEY      NUMBER(38,0) NOT NULL DEFAULT CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER_SEQ.NEXTVAL,
  METERID        VARCHAR      NOT NULL,
  ENERGYTYPE     VARCHAR(10),
  FIRST_INTERVAL TIMESTAMP_TZ(9),   -- earliest INTERVALENDTIME in EEOPS_PGE_ELEC_INTERVAL
  LAST_INTERVAL  TIMESTAMP_TZ(9),   -- latest INTERVALENDTIME
  INTERVAL_ROWS  NUMBER(38,0),      -- rows in the copy (incl. restaged duplicates)
  UPDATED_AT     TIMESTAMP_TZ(9)
) COMMENT = 'EE Ops Interval: PG&E METERID <-> METER_KEY, energy type, data range. Contains meter IDs.';

-- The big one: PG&E electric intervals, sorted by meter -----------------------
CREATE TRANSIENT TABLE IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_ELEC_INTERVAL (
  METER_KEY               NUMBER(38,0)    NOT NULL,
  INTERVALENDTIME         TIMESTAMP_TZ(9) NOT NULL,
  INTERVALENGTH           NUMBER(10,0),
  KWHDELIVERED            NUMBER(19,6),
  KWHRETURNED             NUMBER(19,6),
  ISKWHDELIVEREDESTIMATED BOOLEAN,
  ISKWHRETURNEDESTIMATED  BOOLEAN,
  RECORDSTAGEDATETIME     TIMESTAMP_TZ(9)  -- kept: latest restage wins at read time; refresh watermark
)
DATA_RETENTION_TIME_IN_DAYS = 1
COMMENT = 'EE Ops Interval: copy of RECURVE_ELEC_CONSUMPTION_INTERVAL_PGE sorted by METER_KEY for point lookups. Contains customer consumption (PII).';

-- Premise -> meter links (RECURVE_ID_RELATIONS, PG&E, meters with interval data)
CREATE TABLE IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_PREMISE_METER (
  PREMISEID      VARCHAR      NOT NULL,
  METER_KEY      NUMBER(38,0) NOT NULL,
  SERVICEPOINTID VARCHAR,
  START_DATE     TIMESTAMP_TZ(9),
  END_DATE       TIMESTAMP_TZ(9)    -- NULL = link still open
) COMMENT = 'EE Ops Interval: PG&E premise -> meter links (from RECURVE_ID_RELATIONS).';

-- Address search index: one row per PG&E premise that has interval data ------
-- SEARCH_TEXT = ' ' || upper-cased address/city/zip with every non-[A-Z0-9]
-- run collapsed to one space. The leading space lets the API match each typed
-- word at a word start with a plain LIKE '% WORD%' on the raw column (no
-- function around it, so search optimization can serve it -- see 12).
-- eeops/interval_data.py normalize() must stay identical to this expression.
CREATE TABLE IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_PREMISE (
  PREMISEID     VARCHAR NOT NULL,
  FULLADDRESS   VARCHAR,
  CITY          VARCHAR,
  ZIPCODE5      VARCHAR,
  SEARCH_TEXT   VARCHAR,
  METER_COUNT   NUMBER(38,0),
  LAST_INTERVAL TIMESTAMP_TZ(9)
) COMMENT = 'EE Ops Interval: searchable PG&E premise addresses with interval data. Contains addresses (PII).';

-- One row per refresh step; the Interval page shows the last DONE row -------
CREATE TABLE IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_REFRESH_LOG (
  RUN_ID        VARCHAR NOT NULL,
  UTILITY       VARCHAR NOT NULL,
  MODE          VARCHAR NOT NULL,
  STEP          VARCHAR NOT NULL,
  STATUS        VARCHAR NOT NULL,   -- OK | WARN | FAILED
  LOGGED_AT     TIMESTAMP_TZ(9) NOT NULL,
  ROWS_AFFECTED NUMBER(38,0),
  DETAIL        VARCHAR
) COMMENT = 'EE Ops Interval: refresh history for EEOPS_PGE_* tables.';

-- Who opened which premise's interval data (written by the API on every
-- premise open and every chart query). The search text is never logged.
CREATE TABLE IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_ACCESS_LOG (
  USER_NAME   VARCHAR NOT NULL,     -- Snowflake user from the SPCS ingress header
  SOURCE      VARCHAR NOT NULL,     -- e.g. pge_elec
  ACTION      VARCHAR NOT NULL,     -- premise | series
  PREMISEID   VARCHAR NOT NULL,
  DETAIL      VARCHAR,              -- series: window + resolution
  ACCESSED_AT TIMESTAMP_TZ(9) NOT NULL
) COMMENT = 'EE Ops Interval: audit of premise interval-data lookups (PII access).';

-- ==========================================================================
-- Refresh procedure
-- ==========================================================================
-- CALL EEOPS_REFRESH_PGE_INTERVAL('FULL');            rebuild everything (one-time load; occasional re-sync)
-- CALL EEOPS_REFRESH_PGE_INTERVAL('FULL', '2023-01-01'); same, only intervals on/after that date (cheaper)
-- CALL EEOPS_REFRESH_PGE_INTERVAL('FULL', NULL, '94607,94110'); TEST BATCH: only premises in those ZIPs
-- CALL EEOPS_REFRESH_PGE_INTERVAL('DELTA');           append rows restaged since the last load + new meters
-- CALL EEOPS_REFRESH_PGE_INTERVAL('LOOKUPS');         rebuild only meter ranges / premise links / address index
--
-- EXECUTE AS CALLER so it runs on the caller's warehouse. Each FULL/DELTA
-- reads the whole share once (measured Oct 2026 on the Small: ~85 min for
-- all columns) -- unavoidable without provider-side clustering or change
-- tracking. The sort + write is what scales with the amount loaded.
--
-- P_ZIPS (comma-separated ZIPCODE5 list) limits step 1 to meters linked to
-- premises in those ZIPs; every later step joins through EEOPS_PGE_METER, so
-- the copy, links and address index all shrink to that subset. Meter keys
-- already in EEOPS_PGE_METER stay in scope, so to go from a test batch to
-- the full set just run FULL without P_ZIPS. Don't resume the monthly DELTA
-- task while the tables hold a test batch.
--
-- The PG&E UTILITYPROVIDERCODE is read from the PG&E interval table itself
-- (no hard-coded code to get wrong).

-- The 2-argument version (before P_ZIPS) would make 2-argument CALLs
-- ambiguous; a no-op once it's gone. (Procedures only -- never tables.)
DROP PROCEDURE IF EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_REFRESH_PGE_INTERVAL(VARCHAR, DATE);

CREATE OR REPLACE PROCEDURE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_REFRESH_PGE_INTERVAL(
  P_MODE VARCHAR, P_SINCE DATE DEFAULT NULL, P_ZIPS VARCHAR DEFAULT NULL)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'EE Ops Interval: refresh EEOPS_PGE_* from EXT_CEC_PRD_AMIDATA_DB (FULL | DELTA | LOOKUPS)'
EXECUTE AS CALLER
AS
$$
DECLARE
  v_mode     VARCHAR DEFAULT UPPER(TRIM(P_MODE));
  v_since    TIMESTAMP_TZ DEFAULT P_SINCE::TIMESTAMP_TZ;
  v_run      VARCHAR DEFAULT UUID_STRING();
  v_code     VARCHAR;
  v_wm       TIMESTAMP_TZ;
  v_max_key  NUMBER DEFAULT 0;
  v_rows     NUMBER DEFAULT 0;
  v_step     VARCHAR DEFAULT 'START';
  v_status   VARCHAR DEFAULT 'OK';
  v_zips     VARCHAR DEFAULT NULLIF(REGEXP_REPLACE(COALESCE(P_ZIPS, ''), '[^0-9,]', ''), '');
BEGIN
  IF (v_mode <> 'FULL' AND v_mode <> 'DELTA' AND v_mode <> 'LOOKUPS') THEN
    RETURN 'P_MODE must be FULL, DELTA or LOOKUPS';
  END IF;

  -- PG&E's code as stored by Recurve (stops at the first non-null row).
  v_step := 'UTILITY_CODE';
  SELECT UTILITYPROVIDERCODE INTO :v_code
    FROM EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC.RECURVE_ELEC_CONSUMPTION_INTERVAL_PGE
   WHERE UTILITYPROVIDERCODE IS NOT NULL
   LIMIT 1;

  IF (v_mode <> 'LOOKUPS') THEN
    -- 1. Meter keys: every PG&E meter reachable from a premise (an interval
    --    row whose meter has no RECURVE_ID_RELATIONS link can't be reached
    --    from an address, so it isn't copied).
    v_step := 'METERS';
    SELECT COALESCE(MAX(METER_KEY), 0) INTO :v_max_key FROM CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER;
    MERGE INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER k
    USING (
      SELECT r.METERID, ANY_VALUE(m.ENERGYTYPE) AS ENERGYTYPE
        FROM EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC.RECURVE_ID_RELATIONS r
        LEFT JOIN EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC.RECURVE_METER m
          ON m.METERID = r.METERID AND m.UTILITYPROVIDERCODE = r.UTILITYPROVIDERCODE
       WHERE r.UTILITYPROVIDERCODE = :v_code AND r.METERID IS NOT NULL
         AND (:v_zips IS NULL OR r.PREMISEID IN (
               SELECT p.PREMISEID
                 FROM EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC.RECURVE_PREMISE p
                WHERE p.UTILITYPROVIDERCODE = :v_code
                  AND p.ZIPCODE5 IN (SELECT TRIM(z.VALUE) FROM TABLE(SPLIT_TO_TABLE(:v_zips, ',')) z)))
       GROUP BY r.METERID
    ) s
    ON k.METERID = s.METERID
    WHEN MATCHED AND k.ENERGYTYPE IS DISTINCT FROM s.ENERGYTYPE THEN
      UPDATE SET ENERGYTYPE = s.ENERGYTYPE, UPDATED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN
      INSERT (METERID, ENERGYTYPE, UPDATED_AT) VALUES (s.METERID, s.ENERGYTYPE, CURRENT_TIMESTAMP());
    v_rows := SQLROWCOUNT;
    INSERT INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_REFRESH_LOG
      SELECT :v_run, 'PGE', :v_mode, :v_step, 'OK', CURRENT_TIMESTAMP(), :v_rows,
             'utility code ' || :v_code || IFF(:v_zips IS NULL, '', ' -- TEST BATCH, ZIPs ' || :v_zips);

    -- 2. Intervals. The ORDER BY is the whole optimisation: it writes each
    --    meter's rows into adjacent micro-partitions, so the API's
    --    METER_KEY IN (...) filter prunes to a handful of them.
    v_step := 'INTERVALS';
    IF (v_mode = 'FULL') THEN
      INSERT OVERWRITE INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_ELEC_INTERVAL
        SELECT k.METER_KEY, i.INTERVALENDTIME, i.INTERVALENGTH, i.KWHDELIVERED, i.KWHRETURNED,
               i.ISKWHDELIVEREDESTIMATED, i.ISKWHRETURNEDESTIMATED, i.RECORDSTAGEDATETIME
          FROM EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC.RECURVE_ELEC_CONSUMPTION_INTERVAL_PGE i
          JOIN CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER k ON k.METERID = i.METERID
         WHERE i.INTERVALENDTIME IS NOT NULL
           AND (:v_since IS NULL OR i.INTERVALENDTIME >= :v_since)
         ORDER BY k.METER_KEY, i.INTERVALENDTIME;
      v_rows := SQLROWCOUNT;
    ELSE
      -- DELTA: rows restaged after the newest row we hold, plus the full
      -- history of meters that got a key in step 1 (their older rows would
      -- otherwise be skipped by the watermark). One scan of the share.
      SELECT MAX(RECORDSTAGEDATETIME) INTO :v_wm FROM CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_ELEC_INTERVAL;
      IF (v_wm IS NULL) THEN
        RETURN 'EEOPS_PGE_ELEC_INTERVAL is empty -- run FULL first';
      END IF;
      INSERT INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_ELEC_INTERVAL
        SELECT k.METER_KEY, i.INTERVALENDTIME, i.INTERVALENGTH, i.KWHDELIVERED, i.KWHRETURNED,
               i.ISKWHDELIVEREDESTIMATED, i.ISKWHRETURNEDESTIMATED, i.RECORDSTAGEDATETIME
          FROM EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC.RECURVE_ELEC_CONSUMPTION_INTERVAL_PGE i
          JOIN CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER k ON k.METERID = i.METERID
         WHERE i.INTERVALENDTIME IS NOT NULL
           AND (i.RECORDSTAGEDATETIME > :v_wm OR k.METER_KEY > :v_max_key)
           AND (:v_since IS NULL OR i.INTERVALENDTIME >= :v_since)
         ORDER BY k.METER_KEY, i.INTERVALENDTIME;
      v_rows := SQLROWCOUNT;
      -- A DELTA that copies >20% of the table means Recurve restaged history;
      -- the duplicates are harmless (latest restage wins) but slow lookups
      -- down, so flag it -- the fix is a FULL rebuild.
      SELECT IFF(:v_rows > 0.2 * COUNT(*), 'WARN', 'OK') INTO :v_status
        FROM CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_ELEC_INTERVAL;
    END IF;
    INSERT INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_REFRESH_LOG
      SELECT :v_run, 'PGE', :v_mode, :v_step, :v_status, CURRENT_TIMESTAMP(), :v_rows,
             IFF(:v_wm IS NULL, NULL, 'watermark ' || TO_VARCHAR(:v_wm))
             || IFF(:v_status = 'WARN', ' -- large restage, run FULL to compact', '');
  END IF;

  -- 3. Per-meter data range (reads 2 columns of the copy, not the share).
  v_step := 'METER_RANGES';
  IF (v_mode = 'FULL') THEN
    -- Clear first so meters with no rows left after the rebuild drop out.
    UPDATE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER
       SET FIRST_INTERVAL = NULL, LAST_INTERVAL = NULL, INTERVAL_ROWS = NULL
     WHERE INTERVAL_ROWS IS NOT NULL;
  END IF;
  UPDATE CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER k
     SET FIRST_INTERVAL = s.F, LAST_INTERVAL = s.L, INTERVAL_ROWS = s.N, UPDATED_AT = CURRENT_TIMESTAMP()
    FROM (SELECT METER_KEY, MIN(INTERVALENDTIME) AS F, MAX(INTERVALENDTIME) AS L, COUNT(*) AS N
            FROM CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_ELEC_INTERVAL
           GROUP BY METER_KEY) s
   WHERE k.METER_KEY = s.METER_KEY;
  v_rows := SQLROWCOUNT;
  INSERT INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_REFRESH_LOG
    SELECT :v_run, 'PGE', :v_mode, :v_step, 'OK', CURRENT_TIMESTAMP(), :v_rows, NULL;

  -- 4. Premise -> meter links, only meters that have interval data.
  --    Sorted by PREMISEID so a premise lookup prunes to ~1 partition.
  v_step := 'PREMISE_METERS';
  INSERT OVERWRITE INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_PREMISE_METER
    SELECT r.PREMISEID, k.METER_KEY, ANY_VALUE(r.SERVICEPOINTID), MIN(r.STARTDATE),
           IFF(COUNT_IF(r.ENDDATE IS NULL) > 0, NULL, MAX(r.ENDDATE))
      FROM EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC.RECURVE_ID_RELATIONS r
      JOIN CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER k ON k.METERID = r.METERID
     WHERE r.UTILITYPROVIDERCODE = :v_code
       AND r.PREMISEID IS NOT NULL
       AND k.INTERVAL_ROWS > 0
     GROUP BY r.PREMISEID, k.METER_KEY
     ORDER BY r.PREMISEID;
  v_rows := SQLROWCOUNT;
  INSERT INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_REFRESH_LOG
    SELECT :v_run, 'PGE', :v_mode, :v_step, 'OK', CURRENT_TIMESTAMP(), :v_rows, NULL;

  -- 5. Address search index (latest restage of each premise's address).
  v_step := 'PREMISES';
  INSERT OVERWRITE INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_PREMISE
    SELECT p.PREMISEID, p.FULLADDRESS, p.CITY, p.ZIPCODE5,
           ' ' || TRIM(REGEXP_REPLACE(UPPER(CONCAT_WS(' ', COALESCE(p.FULLADDRESS, ''),
                                                          COALESCE(p.CITY, ''),
                                                          COALESCE(p.ZIPCODE5, ''))),
                                      '[^A-Z0-9]+', ' ')),
           pm.METER_COUNT, pm.LAST_INTERVAL
      FROM (SELECT PREMISEID, FULLADDRESS, CITY, ZIPCODE5
              FROM EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC.RECURVE_PREMISE
             WHERE UTILITYPROVIDERCODE = :v_code AND PREMISEID IS NOT NULL
             QUALIFY ROW_NUMBER() OVER (PARTITION BY PREMISEID ORDER BY RECORDSTAGEDATETIME DESC NULLS LAST) = 1) p
      JOIN (SELECT x.PREMISEID, COUNT(*) AS METER_COUNT, MAX(k.LAST_INTERVAL) AS LAST_INTERVAL
              FROM CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_PREMISE_METER x
              JOIN CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_PGE_METER k ON k.METER_KEY = x.METER_KEY
             GROUP BY x.PREMISEID) pm
        ON pm.PREMISEID = p.PREMISEID
     ORDER BY p.PREMISEID;
  v_rows := SQLROWCOUNT;
  INSERT INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_REFRESH_LOG
    SELECT :v_run, 'PGE', :v_mode, :v_step, 'OK', CURRENT_TIMESTAMP(), :v_rows, NULL;

  v_step := 'DONE';
  INSERT INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_REFRESH_LOG
    SELECT :v_run, 'PGE', :v_mode, :v_step, 'OK', CURRENT_TIMESTAMP(), NULL, NULL;
  RETURN 'EEOPS_REFRESH_PGE_INTERVAL ' || v_mode || ' done, run ' || v_run;

EXCEPTION
  WHEN OTHER THEN
    LET v_err VARCHAR := SQLERRM;
    INSERT INTO CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_INTERVAL_REFRESH_LOG
      SELECT :v_run, 'PGE', :v_mode, :v_step, 'FAILED', CURRENT_TIMESTAMP(), NULL, :v_err;
    RAISE;
END;
$$;

-- ==========================================================================
-- Monthly DELTA refresh -- created SUSPENDED (tasks always are). Resume it
-- only after the FULL load in 12 has succeeded:
--   ALTER TASK CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_REFRESH_PGE_INTERVAL_TASK RESUME;
-- Each run scans the whole share once (see header), so it needs a long
-- timeout; give it a larger warehouse if one is provisioned.
-- ==========================================================================
CREATE TASK IF NOT EXISTS CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_REFRESH_PGE_INTERVAL_TASK
  WAREHOUSE = CPUC_ED_TITLE20_S_WH
  SCHEDULE = 'USING CRON 0 2 3 * * America/Los_Angeles'   -- 02:00 on the 3rd of each month
  USER_TASK_TIMEOUT_MS = 43200000                          -- 12 h
  COMMENT = 'EE Ops Interval: monthly DELTA refresh of EEOPS_PGE_* from the Recurve share'
AS
  CALL CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_REFRESH_PGE_INTERVAL('DELTA');

SHOW TABLES LIKE 'EEOPS_%' IN SCHEMA CPUC_ED_DB.ENERGY_EFFICIENCY;
