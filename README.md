# How punctual is the Brussels public transport network?

An end-to-end data project measuring the service quality of the **STIB-MIVB** network (Brussels metro, tram and bus) by comparing the **real-time feed** of the operator with its **published timetable**.

Two months of real-time data were collected by a scheduled Python job, cleaned and matched to the GTFS timetable in SQL Server, modelled as a star schema and presented in a Power BI report.

> **Stack**: Python (requests, pyodbc) · SQL Server 2022 (T-SQL) · Power BI (PBIP, DAX) · Windows Task Scheduler
> **Period**: 1 July to 26 August 2026, 52 days of collection
> **Author**: Omar Abajtour, Data Analyst (Brussels)

---

## The question

A timetable is a promise. How much of the announced service actually runs on time, where does the network drift from it, and can the losses be located precisely enough to act on?

The report answers three business questions:

1. **What share of the announced service runs on time?** Every scheduled passage falls into exactly one of four categories (on time, early, late, not found), so the four add up to 100 % of the timetable.
2. **Where do the gaps concentrate, and does the transport mode explain them?** Ranking of 71 lines and comparison of metro, tram and bus.
3. **Where along a route is time lost?** Stop-by-stop analysis of one line at a time, to separate schedule problems from reliability problems.

## Key results

| Indicator | Value |
|---|---|
| Real-time predictions collected | ~33.5 million |
| Passage events in the fact table | 3.67 million |
| Lines ranked | 71 of 92 |

Every scheduled passage falls into exactly one category, measured against the STIB punctuality window (60 s early to 180 s late):

| Scheduled passages | Share |
|---|---|
| **On time** | **64.6 %** |
| Early (more than 60 s) | 17.7 % |
| Late (more than 180 s) | 5.5 % |
| Not found in the real-time feed | 12.1 % |

**Early running matters as much as late running.** Early departures are a bigger problem for passengers than late ones: someone who arrives on time at the stop misses the vehicle. The STIB punctuality window reflects this (60 s tolerated early, 180 s late). The report shows that the distribution of delays is roughly centred on zero; what makes early running weigh so much in the result is the asymmetry of the norm, not an actual tendency to run early.

**A time loss can be a timetable problem.** On tram line 25, the section Patrie to Meiser loses about 24 seconds (median) in both directions, with an ordinary spread. A systematic loss with normal dispersion points to a **schedule calibration** issue rather than congestion or unreliability, which is a different, and cheaper, fix.

## The report

<!-- Add screenshots to docs/img/ and uncomment.
![Summary page](docs/img/01_synthese.png)
![Lines and modes](docs/img/02_lignes.png)
![Line zoom](docs/img/03_zoom.png)
![Method and reliability](docs/img/04_methode.png)
-->

The Power BI project itself is in [`powerbi/`](powerbi/) in PBIP format (text files, readable and versioned). The data is not included, see [Reproducibility](#reproducibility).

## How it works

```
 STIB real-time API ──► Python collector (every 3 min) ──┐
 GTFS timetable (3 feeds) ──► import notebook ────────────┤
 Open-Meteo, Statbel ──► import notebooks ───────────────┤
                                                         ▼
                                            SQL Server : staging
                                                         │  numbered, idempotent T-SQL scripts
                                                         ▼
                            reconstruct real passages ──► match to timetable
                                                         │
                                                         ▼
                                  star schema : fact_ecart + 8 dimensions
                                                         │
                                                         ▼
                                                 Power BI report
```

### The main technical difficulty: there is no trip identifier

The real-time feed does not say **which scheduled trip** a vehicle is running. It only publishes, at each stop, the predicted waiting time for the next vehicles towards a destination. Three problems follow, each solved in its own script:

- **Rebuilding real passages from predictions.** A vehicle appears in several consecutive predictions before it passes. The collector keeps the next vehicle per cycle, then groups consecutive predictions into one passage (gaps and islands). The passage time is the **last prediction before the vehicle disappears from the feed**: an estimate, never presented as an observed arrival time. (`21_wrk_prochain`, `22_wrk_passages`)
- **Linking two identifier systems.** Real-time stop codes and GTFS stop codes differ (platform suffixes such as `5102` / `5102F`). A mapping table links them by numeric root, and a second one links announced destinations to timetable headsigns, including diversions and spelling variants, for 99.2 % of the traffic. (`06_map_arret`, `25_map_destination`)
- **Matching without a key.** Each real passage is matched to at most one scheduled passage by a **reciprocal nearest-neighbour** algorithm (one-to-one, iterative). The matching tolerance depends on the line: half of the 10th percentile of its headways, capped at 300 s, so that a late vehicle is not matched to the following trip and reported as early. (`44_ref_tolerance_ligne`, `45_int_appariement`)

### Modelling choices worth knowing

- **Grain of the fact table: one passage event.** A real passage that matches nothing has no scheduled trip, so a grain of "stop x trip x date" could not hold it. Scheduled, real and matched passages live in the same table with additive 0/1 counters, so every rate is a simple ratio of sums.
- **Unknown members (`-1`)** in the dimensions allow real foreign keys on every link of the fact table.
- **Medians, not means**, for delays: the distributions are asymmetric.
- **Line exclusions are rule-based**: a line is ranked only if it runs during the first and the last week of the period. Four lines excluded this way (partial service due to summer works) were checked against STIB works notices.

## Repository layout

```
python/                 collection and import
  collecte.py             real-time collector (run by Windows Task Scheduler)
  import_*.ipynb          GTFS, weather, Statbel and line-type imports
sql/                    the whole pipeline, one script per object, run in numeric order
  00_ddl/                 source tables and reference tables
  20_transform/           cleaning, real passages, timetable, matching
  30_model/               dimensions and fact table
  70_analyse/             spatial analysis (question 3)
  90_checks/              non-regression checks, KPI decomposition, backup
  experiments/            sensitivity test of the quality filters (development phase, line 25)
powerbi/                Power BI project (PBIP)
docs/                   screenshots and PDF export of the report
```

Every SQL script starts with a header explaining **what** it builds, **why** it is built that way and how it was **checked**. Comments are in French.

## Reproducibility

- **The data is not in the repository.** The raw real-time table (~33.5 million rows) cannot be downloaded again: the API only publishes the present moment. It is kept as a SQL Server backup outside GitHub.
- **Everything else is scripted.** From the staging tables, the numbered scripts rebuild the whole model. The scripts that create the raw tables never drop anything, so they can be re-run safely on the existing database.
- **To run the collector**, set the API key as an environment variable (never in the code):

  ```
  setx STIB_API_KEY "your_key"
  pip install -r python/requirements.txt
  python python/collecte.py
  ```

  The import notebooks start with a configuration cell (server name, source folder) to adapt to your machine.

## Limitations

- One summer only, during a period of major roadworks: the results describe summer 2026, not a typical year.
- Collection covers 09:00 to 14:00; the analysis window is 09:15 to 13:45 to avoid edge effects. Peak hours are not covered.
- Five collection days are missing (4, 5, 6, 11 and 12 July).
- Real passage times are estimates derived from the last prediction, not measured arrivals.
