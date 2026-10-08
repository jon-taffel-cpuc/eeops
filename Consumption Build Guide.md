# Consumption Build Guide

How to build the **Consumption** section of EE Ops, stage by stage: address
lookup and charts first, then bills, weather-normalized end uses (PRISM),
building attributes, income and program participation, ending in total,
heating, cooling and base-load **energy and $ per square foot**, by climate
zone, vintage, income and participation.

Each stage lists what **you** do (uploads, runs, decisions), a **prompt** to
paste to CoCo, what CoCo builds, and how you know it's done. Do the stages in
order: each one's checks feed the next one's design.

> **Ground rules (all stages)**
> - Customer data is PII. Everything stays in `CPUC_ED_DB.ENERGY_EFFICIENCY`
>   as `EEOPS_*` objects, behind the app's access logging. Reports show
>   aggregates with small cells (< 15 premises) suppressed.
> - CoCo never selects customer rows to "look at the data": only counts,
>   percentiles and metadata, unless you explicitly ask.
> - Schema changes are idempotent files in `deploy/sql/` (see its README).
>   App releases go through `deploy/01_auto_deploy_sf.sh` → commit/push →
>   `02` on the laptop → `03` → `04` (`Quick Deploy Guide.md`).
> - Build on the **development cohort** (Stage 5) first; run statewide only
>   once the outputs are settled (Stage 13).

---

## What's in the Recurve share (`EXT_CEC_PRD_AMIDATA_DB.CPUC_SHARE_SC`)

| Table | Rows | Size | Used for |
|---|---|---|---|
| `RECURVE_PREMISE` | 21.4M | 0.6 GB | Service addresses (one ID per utility) |
| `RECURVE_ID_RELATIONS` | 82M | 1.6 GB | Premise ↔ service account ↔ meter |
| `RECURVE_METER` | 26M | 0.2 GB | Meter, utility, fuel (E/G) |
| `RECURVE_ELEC_BILLING` / `RECURVE_GAS_BILLING` | ~1.1B each | 6.7 GB each | $ per bill period (by service account) |
| `RECURVE_GAS_CONSUMPTION_MONTHLY` | 1.6B | 13 GB | Therms per bill period (by meter) + rate/flags |
| `RECURVE_ELEC_CONSUMPTION_MONTHLY` | 124B (?) | 832 GB | kWh per bill period (by meter) + rate/flags — row count needs explaining (Stage 2) |
| `RECURVE_ELEC_CONSUMPTION_INTERVAL_{PGE,SCE,SDGE,SMUD}` | 449B / 415B / 182B / 34B | 5.6 / 4.9 / 1.5 / 0.4 TB | Interval kWh — address charts and load shape only |

Meters: 14.1M electric (PG&E 5.39M, SCE 4.87M, LADWP 1.65M, SDG&E 1.48M,
SMUD 0.69M) and 12.2M gas (SoCalGas 6.23M, PG&E 4.89M, SDG&E 1.04M). That
includes non-residential. None of the tables is clustered, so every query
reads the whole table: ~1 GB/s on the Small warehouse (~85 min for the PG&E
interval table, seconds for billing). **PRISM and $/sq ft need only the
billing and monthly tables, not the intervals.**

---

## Stage 0 — Foundation ✅ (done)

- `deploy/sql/11_interval_tables.sql` — interval copy, lookups, refresh
  procedure, monthly task (suspended). Run.
- `deploy/sql/14_raw_landing.sql` — `@EEOPS_RAW` upload stage + file
  formats. Run.
- App v0.2.x — Consumption page (address bar + interval chart). Built.

## Stage 1 — Test batch + first deploy

**You:**
1. Run `deploy/sql/13_interval_test_batch.sql` (Run All, ~1.5 h, ideally
   after hours). Leave the tab open.
2. Ship the app: CoCo runs `01` (prompt below), then you commit + push in
   the Git panel, run `02` on the laptop, then `03` and `04`.

**Prompt:**
> 13 finished. Check its results (refresh log, counts, clustering depth) and
> tell me if the design held. Then run `bash deploy/01_auto_deploy_sf.sh --patch`.

**Done when:** every refresh step is `OK`, `average_depth` is ~1–3, and the
Consumption page charts a real address in ZIP 93241 or 93250 in about a second.

## Stage 2 — Probe the billing and monthly tables (counts only)

Open questions that decide the table design:
- Why does `RECURVE_ELEC_CONSUMPTION_MONTHLY` have 124B rows? (TOU-period
  rows? restages? daily rows?)
- Is LADWP in the monthly table? (It has no interval table.)
- Which `RATESCHEDULECD` values are residential?
- What share of accounts are NEM, levelized (budget) billing, CCA,
  gas transport-only, EV or medical-rate?
- Does `BILLCHARGE` include CCA generation charges? (Ask Recurve if the
  data can't tell.)
- How well do bill periods (by service account) line up with consumption
  periods (by meter)?

**Prompt:**
> Do Stage 2 of the Consumption Build Guide: counts-only probes of the
> billing and monthly consumption tables. Answer each open question, and
> propose the residential filter.

**Done when:** each question has an answer (or a question to Recurve), and
you've agreed the residential filter and exclusion rules.

## Stage 3 — Upload the outside data

Upload to `@CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_RAW/<folder>/`, one folder per
source. Files ≤ 250 MB go through Snowsight (Ingestion → Add Data → Load files
into a Stage). Bigger files: split them, or `PUT` from the laptop. Parquet is
preferred; CSV with a header row, gzipped, is fine. **Not** the workspace (it
syncs to git).

| Folder | What | Must have | Nice to have |
|---|---|---|---|
| `weather/` | Daily weather, 2017-01-01 → latest (bill periods start before the first intervals) | station ID, date, Tmax and Tmin (or Tavg), units | precipitation, data-quality flags |
| `weather_stations/` | Station list | station ID, lat, lon | elevation, name, CEC climate zone |
| `weather_normals/` | Typical-year weather for normalization: CEC **CZ2022** files (hourly, one per climate zone) or 30-year normals per station | zone or station, hour or day of year, temperature | — |
| `parcels/` | Statewide parcels (one file per county is fine) | APN, county, situs address (number, street, unit, city, ZIP), lat/lon or geometry, land-use code, year built, building/living sq ft, unit count | stories, bedrooms, heating/cooling type, pool, lot size |
| `climate_zones/` | CEC Building Climate Zones (16 zones) | polygons (WKT or GeoJSON), or a ZIP → zone table | — |
| `census/` | ACS 5-year median household income (B19013) by census tract, and tract boundaries (TIGER) or centroids | tract GEOID, income, polygon or centroid | MOE, population, households |
| `claims/` | EE claims, ~1M rows a year | claim ID, program, PA, measure, claim year/quarter, install date, kWh / therm savings | incentive $, measure category, delivery type |
| `claim_sites/` | The address table the claims link to | claim/site ID, address fields, ZIP | utility account or premise ID (makes matching far easier) |

**Prompt (once per folder, after uploading):**
> I uploaded `<folder>` to `@EEOPS_RAW/<folder>/`. List the files (names and
> sizes), read the schema with `INFER_SCHEMA`, propose the `EEOPS_` table, and
> load it with `COPY INTO`. Report row counts and load errors — counts only.

**Done when:** each source is in an `EEOPS_` table, row counts match what you
expected, and load errors are zero or explained.

## Stage 4 — Clean and standardize the outside data

CoCo builds:
- **Weather:** a daily table by station with gaps flagged and filled (from
  nearest stations), °F throughout.
- **Normals:** degree-days per station or zone for the normal year.
- **Parcels:** standardized addresses (same normalization as the address
  search), a property-type class (single-family / multifamily / other) and
  a vintage bucket by Title 24 era (pre-1978, 1978–91, 1992–2000, 2001–07,
  2008–13, 2014+).
- **Geography:** climate zone and census tract for every parcel (spatial
  join), and income per tract.

**Prompt:**
> Do Stage 4: build the cleaned weather, normals, parcel, climate-zone and
> tract tables. Report coverage: stations with gaps, parcels missing sq ft
> or year built, and the parcel count by property type and climate zone.

## Stage 5 — Choose the development cohort

One or two ZIPs per CEC climate zone (16–30 ZIPs, ~1% of homes). Mix
dense, suburban and rural ZIPs, and both PG&E/SDG&E (one premise ID for both
fuels) and SCE+SoCalGas (two utilities, so electric and gas premises must be
matched).

**Prompt:**
> Do Stage 5: propose the development cohort ZIPs (1–2 per climate zone),
> with meter and premise counts per ZIP by utility and fuel. Counts only.

**You:** approve or edit the ZIP list. CoCo saves it as
`EEOPS_COHORT_ZIP`; every later stage filters to it until Stage 13.

## Stage 6 — The premise crosswalk (the hardest stage)

One row per **building**, tying together the utility premise IDs,
electric and gas service accounts and meters, the parcel (APN), climate
zone, tract and claim sites.

- Match on standardized address (number + street + unit + ZIP); fall back
  to geocode → parcel polygon.
- Electric ↔ gas across utilities (e.g. SCE + SoCalGas) goes through the
  parcel.
- Single-family first: one premise per parcel. Multifamily (many premises
  or one master meter per parcel) waits for a unit-level sq ft rule.

**Prompt:**
> Do Stage 6 on the cohort: build the premise crosswalk. Report match rates
> by utility, fuel and property type, and the top reasons for non-matches.
> Show any example addresses only if I ask.

**You:** review the match rates (aim for > 90% of single-family premises
matched to a parcel) and decide how to handle the misses.

## Stage 7 — Bill periods

One row per building × fuel × bill period: start and end dates, days, kWh
or therms, $, rate schedule, and flags (NEM, levelized, CCA, transport-only,
EV, medical, estimated).

**Prompt:**
> Do Stage 7 on the cohort: build the bill-period table from billing +
> monthly consumption via the crosswalk, with the exclusion flags agreed in
> Stage 2. Report coverage: bills per building-year, and the share flagged.

## Stage 8 — Degree-days per bill period

For every bill period: heating and cooling degree-days summed over its
days, at base temperatures from 45°F to 75°F, from the building's assigned
station.

**Prompt:**
> Do Stage 8: assign each cohort building a weather station (nearest with
> complete data, same climate zone) and compute HDD/CDD per bill period for
> the 45–75°F grid.

## Stage 9 — PRISM fits

Per building × fuel × year:
`use/day = base + β_heat·HDD(τh)/day + β_cool·CDD(τc)/day`

- Gas: heating-only. Electric: best of heating + cooling / cooling-only /
  heating-only / base-only.
- Balance points chosen by grid search; slopes kept only if positive and
  significant; ≥ 10 bills and a minimum R² required.
- Weather-normalized annual split: base × 365, β_heat × HDD_normal,
  β_cool × CDD_normal.

**Prompt:**
> Do Stage 9 on the cohort: fit PRISM per building, fuel and year. Report
> the fit-rate, R² distribution, balance-point distribution by climate zone,
> and the share of buildings per model type.

**You:** sanity-check by climate zone (e.g. the coast should be mostly
heating-only with high balance points; the Central Valley should show strong
cooling) and agree the quality thresholds.

## Stage 10 — $ and per square foot

- Split each bill's `BILLCHARGE` into base / heating / cooling by that
  period's fitted shares (so cooling picks up summer rates). Use annual
  totals only for levelized-billing accounts.
- Per building-year: kWh/sq ft, therms/sq ft, $/sq ft, each for total /
  heating / cooling / base; site EUI = kWh × 3.412 + therms × 100 (kBtu/sq ft).

**Prompt:**
> Do Stage 10 on the cohort: allocate bill $ to end uses and compute the
> per-sq-ft metrics and EUI. Report medians and IQRs by climate zone and
> fuel.

## Stage 11 — Attributes, participation and segments

- Join climate zone, vintage, tract income, CARE/FERA (`LOWINCOMEPROGRAM`),
  property type and sq ft band.
- Join claims through the crosswalk: participant flag, claim year, measure
  category and claimed savings. Keep pre/post years for later comparisons.
- Segment views: medians, IQRs and counts per cell, suppressing cells under
  15 buildings.

**Prompt:**
> Do Stage 11: join the attributes and claims, and build the segment views
> for $/sq ft and EUI by climate zone × vintage × income band ×
> participation. Report cell counts and how many cells are suppressed.

## Stage 12 — App features

Add to the Consumption page:
- **For an address:** monthly bills ($, kWh, therms), and the PRISM split
  (base / heating / cooling) with the fitted line against degree-days.
- **Segment explorer:** pick climate zone / vintage / income / participation
  and see $/sq ft and EUI distributions by end use.

**Prompt:**
> Do Stage 12: add bill history and the PRISM end-use split for the
> selected address, plus a segment-explorer tab, then run the deploy script.

## Stage 13 — Statewide

Re-run Stages 6–11 without the cohort filter. Billing and monthly tables
are small, so this is a few scans, not a week, but crosswalk matching will
need QA per county.

Optional, separately decided:
- **Interval data statewide**, for address charts and load-shape features
  (TOU, peaks). PG&E alone is a ~5 TB copy and ~25–45 nightly batches on the
  Small. Cheaper alternative: a daily table per meter (~100–200 GB) with
  peak and 4–9 pm kWh. Get the storage budget agreed first: all of
  `CPUC_ED_DB` is ~0.3 GB today.
- **Other utilities' interval data** (SCE, SDG&E, SMUD): same pattern as
  PG&E.

**Prompt:**
> Do Stage 13: run the crosswalk, bills, degree-days, PRISM, $/sq ft and
> segments statewide. Report match and fit rates by county and utility
> against the cohort's.

## Stage 14 — Keep it current

- Recurve updates the share (last altered 2026-10-01). Refresh bills,
  monthly use and PRISM when it changes. The billing and monthly tables
  re-scan cheaply.
- New weather and claims: upload into the same `@EEOPS_RAW` folders and ask
  CoCo to append.
- The interval DELTA task stays suspended until the interval data is
  loaded beyond the test batch.

**Prompt:**
> The Recurve share was updated. Refresh Stages 7–11 (bills through
> segments) and tell me what changed.

---

## Decisions you'll be asked to make

| Stage | Decision |
|---|---|
| 2 | Residential filter; how to treat NEM, levelized, CCA, transport-only, EV |
| 3 | Weather source (station data vs a Marketplace provider) and normal year (CZ2022 vs 30-year normals) |
| 5 | Cohort ZIPs |
| 6 | Acceptable match rate; multifamily approach |
| 9 | PRISM quality thresholds (min bills, R², significance) |
| 11 | Income bands; participation definition (any claim? by measure type? years before/after) |
| 13 | Whether to port interval data statewide (storage budget) |
