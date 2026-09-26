# SQL pipeline

The whole transformation, from raw staging tables to the star schema read by Power BI, is written in T-SQL (SQL Server 2022, database `TFE_STIB`). One script builds one object. Scripts are numbered and run in numeric order, with one exception explained below.

Each script starts with a header, in French, that states **what** it builds, **why** it is built that way, its inputs and outputs, and how the result was checked.

## Layers and naming

| Prefix | Layer | Rebuilt by the scripts? |
|---|---|---|
| `staging_*`, `stg_*` | Raw data as loaded by Python (real-time feed, GTFS, weather, Statbel) | **No.** Created only if absent, never dropped |
| `ref_*`, `map_*` | Reference and mapping tables (feed validity, stop and destination mapping, matching tolerance) | Yes |
| `wrk_*` | Working tables on the real-time side: cleaning, passage reconstruction, analysis period | Yes |
| `int_*` | Intermediate tables: timetable, matching, spatial analysis | Yes |
| `dim_*`, `fact_*`, `diag_*` | Star schema read by Power BI | Yes |

## Folders

```
00_ddl/        staging tables and reference tables
20_transform/  real-time cleaning, timetable, matching
30_model/      dimensions, fact table, diagnostics
70_analyse/    spatial analysis (where along a route is time lost?)
90_checks/     non-regression checks, KPI decomposition, backup
experiments/   sensitivity test of the quality filters (not part of the run)
```

## Run order

```
00_ddl        01 → 02 → 03 → (load data with python/) → 04 → 05 → 06
20_transform  20 → 21 → 22 → 23 → 24 → 25 → 40 → 41* → 44 → 41 → 45
30_model      51 → 52 → 53 → 54 → 55 → 56 → 57 → 60 → 61 → 62 → 63 → 64 → 65 → 66 → 67
70_analyse    70
90_checks     93 → 94     (read only)      99 (backup)
```

**\* The 41 / 44 bootstrap.** `41_est_observable` and `44_ref_tolerance_ligne` read each other: 41 uses the tolerance per line, and 44 computes it only on observable scheduled stop events. On a fresh database, the first run of 41 stops at step 3d because the tolerance table does not exist yet. This is expected. Run 44, then run 41 again: the script is idempotent.

## What each script builds

### 00_ddl: sources and references

| Script | Builds | Why it matters |
|---|---|---|
| `01_staging_temps_reel` | `staging_waiting_times`, `staging_vehicle_positions`, `staging_stop_details` | Receives the real-time feed (~33.5 M predictions). **Irreproducible**: the API only publishes the present moment, so this script never drops anything |
| `02_staging_gtfs` | `stg_calendar`, `stg_calendar_dates`, `stg_routes`, `stg_stops`, `stg_trips`, `stg_stop_times` | The three GTFS feeds in the same tables. `feed_version` is in every key: a `trip_id` is only unique within one feed |
| `03_staging_sources_externes` | `staging_meteo`, `staging_line_exploitation`, `staging_secteur_stat`, `staging_revenu_commune` | Weather (Open-Meteo ERA5), line operating type, Statbel data |
| `04_stop_id_racine` | Column `stop_id_racine` on `stg_stop_times` (+ index) | GTFS suffixes platforms (`2351` / `2351F`), the real-time feed does not. The numeric root links them |
| `05_ref_feed_periode` | `ref_feed_periode` | The three GTFS feeds overlap. For each date, the most recent feed wins, so no scheduled stop event is counted twice |
| `06_map_arret` | `map_arret` | Links each real-time `point_id` to a GTFS `stop_id` (2,292 matches, 97.7 %) |

### 20_transform: from predictions to matched stop events

| Script | Builds | Why it matters |
|---|---|---|
| `20_wrk_observations` | `wrk_observations` | Types and cleans the raw predictions (~31 M rows). Heaviest step of the pipeline |
| `21_wrk_prochain` | `wrk_prochain` | Keeps only the **next vehicle** per collection cycle. Without it, step 22 would compare the 2nd vehicle of one cycle with the 1st of the next and split passages wrongly |
| `22_wrk_passages` | `wrk_passages` | Rebuilds observed stop events from successive predictions (gaps and islands, 240 s break threshold). The time kept is the **last prediction** before the vehicle disappears: an estimate, not a measured arrival |
| `23_wrk_jours` | `wrk_jours` | **Single source of the analysis period** (parameter `@date_fin`). Both sides of the matching read it |
| `24_wrk_service_date` | `wrk_service_date` | Turns the GTFS calendar (weekday flags + exceptions) into an explicit list of service dates |
| `25_map_destination` | `map_destination` | Links destinations announced by the API to GTFS headsigns (exact, diverted, abbreviated...). The destination is a matching key, since the feed has no trip identifier |
| `40_int_passage_theorique` | `int_passage_theorique` | Scheduled stop events on collected days, within the 09:15 to 13:45 window |
| `41_est_observable` | Columns `est_observable`, `motif_inobservable` | Flags scheduled stop events the feed never publishes (e.g. arrivals at a terminus). They are flagged, not deleted, and leave the denominator |
| `44_ref_tolerance_ligne` | `ref_tolerance_ligne` | Matching tolerance per line: half of the 10th percentile of headways, capped at 300 s. Stored in a table so it cannot change silently |
| `45_int_appariement` | `int_appariement` | One-to-one matching by reciprocal nearest neighbour. Output: matched, scheduled only, observed only |

### 30_model: star schema

| Script | Builds | Why it matters |
|---|---|---|
| `51_dim_arret` | `dim_arret` | Stops. No unknown member on purpose: an unknown stop must stop the pipeline (foreign key error in 60) |
| `52_dim_desserte` | `dim_desserte` | Line × direction × stop, with the geographic order of stops along the route |
| `53_dim_date` | `dim_date` | Continuous calendar 1 July to 31 August. Days not collected are kept with `est_collecte = 0`, so a gap stays visible |
| `54_dim_heure` | `dim_heure` | 15-minute slots. The fact table links to the **scheduled** time, never the observed one |
| `55_dim_ligne` | `dim_ligne` | Lines, with the real mode from `route_type` (the `M1` prefix is the replaced mode, not the actual one) |
| `56_dim_meteo` | `dim_meteo` | Hourly weather |
| `57_dim_course` | `dim_course` | Trips as published (`feed_version`, `trip_id`), with truncation flags |
| `60_fact_ecart` | `fact_ecart` | **Fact table**, one row per stop event (scheduled, observed, or both). 3.67 M rows, 7 foreign keys |
| `61_fact_ecart_postes` | Columns on `fact_ecart` | Additive 0/1 counters of the cascade (on time, early, late) for the −60 / +180 s window. The window is a methodological choice, so it lives in SQL, not in DAX |
| `62_dim_ligne_classement` | Columns on `dim_ligne` | Ranking rule: a line is ranked only if it runs in the first **and** last 7 days of the period (71 of 75 lines). Excluded lines stay in every total |
| `63_diag_non_apparies` | `diag_non_apparies` | The four causes of unmatched stop events (service or method) |
| `64_dim_ligne_ordre` | Column `ordre_ligne` | Numeric sort order of lines (otherwise "10" sorts before "2") |
| `65_dim_direction` | `dim_direction` | Shared direction dimension (outbound, inbound, unknown) |
| `66_fact_ecart_direction` | Column `direction_id` on `fact_ecart` + foreign key | Lets one direction slicer filter the whole report |
| `67_dim_arret_correspondances` | Columns on `dim_arret` | Number of ranked lines serving each physical stop (grouped by name), and interchange class |

### 70_analyse, 90_checks, experiments

| Script | Builds | Why it matters |
|---|---|---|
| `70_analyse_spatiale` | `int_profil_arret`, `int_segment` | Delay profile along each route and time lost per segment (Zoom page) |
| `93_checks_fact_ecart` | Nothing (read only) | Non-regression checks on the fact table |
| `94_decomposition_kpi` | Nothing (read only) | Answers "what is in the 35 % that is not on time?": the cascade (part A) and the causes of unmatched stop events (part B) |
| `99_backup` | `.bak` files | Backup of the database, mainly for the irreproducible real-time data |
| `experiments/46_sensibilite_filtres` | `int_appariement_sensib` | Cost of the quality filters on the matching rate (development phase, line 25). Does not touch the main pipeline |

## Parameters

| Where | Parameter | Value used |
|---|---|---|
| `23_wrk_jours` | `@date_fin` | `2026-08-26` (52 days). `2026-08-18` reproduces the earlier 44-day figures |
| `40_int_passage_theorique` | `@sec_debut`, `@sec_fin` | `33300` / `49500` (09:15 included to 13:45 excluded) |
| `40`, `45`, `52`, `57` | `@ligne` | `NULL` for the whole network, `'25'` for the development line |
| `70_analyse_spatiale` | `#param.ligne` | `NULL` for the whole network |

## Rebuilding after a change

- **Foreign keys protect the fact table.** `fact_ecart` references 7 dimensions, so a dimension cannot be dropped while it exists. To rebuild a dimension, drop `fact_ecart` first, then replay from that dimension to 67.
- **Some scripts add columns to earlier tables.** Rebuilding `dim_ligne` (55) removes the columns added by 62 and 64; rebuilding `dim_arret` (51) removes those added by 67; rebuilding `dim_direction` (65) removes the foreign key added by 66. Replay the whole chain from the rebuilt script onwards.
- **`06_map_arret` depends on the collected data.** Collecting more days can add new `point_id` values and change everything downstream. Compare the new table with the previous one before replaying.

## Reference figures (52 days, 1 July to 26 August 2026)

| | Value |
|---|---|
| Scheduled stop events (raw) | 3,602,475 |
| Scheduled stop events kept (denominator) | 3,428,704 |
| Matched | 3,012,361 (87.86 %) |
| On time | 2,216,461 (**64.64 %**) |
| Not matched | 416,343 (12.14 %) |

`94_decomposition_kpi` reproduces these figures. The reference values written in the header of `93_checks_fact_ecart` are those of the earlier 44-day run.
