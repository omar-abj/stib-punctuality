# Methodology

This page explains how the on-time rate is built, from the raw real-time feed to the four categories shown in the report. The script that implements each step is given in brackets; see [`sql/README.md`](../sql/README.md) for the full run order.

## 1. What is measured

**Unit of measure: the scheduled stop event**, one vehicle due at one stop at one time according to the published timetable (GTFS).

**Indicator: the on-time rate**, the share of scheduled stop events served within the STIB punctuality window, **from 60 s early to 180 s late**.

```
on-time rate = scheduled stop events served on time / scheduled stop events (observable)
```

The denominator is the **timetable**, not what was observed. A scheduled stop event with no vehicle found counts against the network, as a late or early one does. The indicator answers the question a passenger would ask: "of the service that was announced, how much was delivered on time?"

**Scope**: 1 July to 26 August 2026 (52 days of collection; 4, 5, 6, 11 and 12 July are missing), 09:15 to 13:45, all day lines (night lines excluded).

## 2. Data sources

| Source | Content | Collection |
|---|---|---|
| STIB real-time API, `WaitingTimes` | For each stop, line and destination: predicted arrival of the next vehicles | Every 3 minutes, 09:00 to 14:00 (100 calls a day, the API limit), Python job run by Windows Task Scheduler |
| STIB GTFS | Published timetable: trips, stops, times, calendars | Three consecutive feeds covering the period |
| Open-Meteo (ERA5) | Hourly weather | Not used in the published results |

The collection window (09:00 to 14:00) is wider than the analysis window (09:15 to 13:45): a vehicle due at 09:16 must have been followed for several cycles before it passes, so the first and last 15 minutes are dropped to avoid edge effects.

## 3. From predictions to observed stop events

The API does not publish arrivals. It publishes, every cycle, **predictions**: "the next vehicle of line 25 towards Rogier arrives at this stop at 10:42:30". The observed side of the analysis has to be rebuilt from them.

1. **Keep the next vehicle only** (`21_wrk_prochain`). Each cycle lists several upcoming vehicles. Only the earliest prediction per stop, line and destination is kept, otherwise the next step would compare the 2nd vehicle of one cycle with the 1st of the next.
2. **Group successive predictions into one stop event** (`22_wrk_passages`). While the predicted time stays stable from one cycle to the next, it is the same vehicle approaching. When it jumps forward by more than **240 s**, the previous vehicle has left the feed and the API now announces the next one. This is a *gaps and islands* problem, solved with `LAG` and a running sum of breaks.
3. **Take the last prediction** before the vehicle disappears as its time at the stop.

> **This time is an estimate, not a measurement.** It is a very short-term prediction: for the stop events kept, it was made at most 3 minutes before the predicted time. The report never presents it as an observed arrival.

**Quality filters** (`45_int_appariement`): an observed stop event is kept only if it was seen in at least 2 cycles (a single prediction may be a glitch) and if its last prediction was made between 120 s after and 180 s before the predicted time (a stale prediction is not reliable). The cost of these filters was measured (`experiments/46_sensibilite_filtres`) and is reported with the causes of unmatched stop events (section 7).

## 4. Linking the two systems

The real-time feed and the timetable do not share identifiers, and the feed has **no trip identifier**. Three reference tables make the link.

| Problem | Solution | Script |
|---|---|---|
| Stop codes differ: GTFS adds platform suffixes (`5102F`), the API does not (`5102`) | Match on the numeric root of the code: 2,292 stops, 97.7 % of real-time stop codes | `04_stop_id_racine`, `06_map_arret` |
| The only link to a trip is the destination announced on the vehicle | Map each announced destination to a GTFS headsign, per line: exact, diverted route, abbreviation. Covers 99.2 % of the traffic | `25_map_destination` |
| The three GTFS feeds overlap in time | For each date, the most recent feed wins, so a scheduled stop event is never counted twice | `05_ref_feed_periode` |

## 5. The denominator: observable scheduled stop events

Some scheduled stop events can never appear in the feed, whatever the quality of the service. The `WaitingTimes` endpoint is a passenger service: it announces vehicles to people who want to board, so it publishes nothing for an arrival at a terminus. Counting these as missing vehicles would penalise the network for a limit of the API.

A scheduled stop event is flagged **not observable** (`41_est_observable`) when:

1. its stop has no equivalent in the real-time feed;
2. its line, stop and destination combination was **never** published by the feed during the whole period;
3. its line is outside the scope (no measurable headway, for example a residual service of 3 trips).

The rule is based on what the feed actually publishes, not on a list of stops written by hand. It removes 173,771 of 3,602,475 scheduled stop events (4.8 %). They are flagged, not deleted, so the decision can be reviewed.

## 6. Matching scheduled and observed stop events

Without a trip identifier, each observed stop event has to be paired with the scheduled stop event it corresponds to (`45_int_appariement`).

**Candidates.** A scheduled and an observed stop event are candidates if they share the date, line, stop and destination, and if the gap between them is within the **line's matching tolerance**.

**Tolerance per line** (`44_ref_tolerance_ligne`). A fixed tolerance does not work. On a line with a vehicle every 6 minutes, a 4-minute tolerance reaches the next trip: a late vehicle would be matched to the following scheduled trip and reported as early. The error would be silent. So the tolerance is set per line:

```
tolerance = 10th percentile of scheduled headways / 2, between 120 s and 300 s
```

The 10th percentile describes the moments when vehicles are closest together, which is when confusion is most likely. The values obtained range from 180 s to 300 s. They are stored in a table, so they cannot change silently if the timetable is reloaded.

**Algorithm: reciprocal nearest neighbour, one-to-one.** At each iteration, each scheduled stop event picks its closest remaining observed one, and each observed stop event picks its closest remaining scheduled one. Only mutual choices are kept, then removed from the pool. The loop stops when no new pair is found. Ties are broken by identifiers, so the result is deterministic.

The result is one of three outcomes: **matched**, **scheduled only** (no vehicle found), **observed only** (a vehicle with no scheduled counterpart).

**Consequence to keep in mind.** The measured deviation is censored at the line's tolerance, which differs between lines. Raw median delays and matching rates are therefore **not comparable across lines**. The on-time rate is: every line has a tolerance of at least 180 s, so the whole punctuality window (−60 / +180 s) can be measured everywhere.

## 7. Classification: the four categories

Every observable scheduled stop event falls into exactly one category (`61_fact_ecart_postes`), so the four add up to 100 % of the timetable:

| Category | Rule | Share |
|---|---|---|
| **On time** | Matched, deviation between −60 s and +180 s | **64.6 %** |
| Early | Matched, more than 60 s early | 17.7 % |
| Late | Matched, more than 180 s late | 5.5 % |
| Not found | No observed stop event matched | 12.1 % |

The four counters are stored as 0/1 columns in the fact table, so every rate is a ratio of two sums and stays correct at any level of aggregation (network, mode, line, stop, day).

**Two rates that must not be confused**

- **Matching rate** (87.9 %): the share of the timetable for which a deviation could be measured. It describes the **coverage** of the method.
- **On-time rate** (64.6 %): the share of the timetable served within the window. It describes the **service**.

### Why stop events are not found

The 12.1 % not found were traced back to their cause (`63_diag_non_apparies`) by looking again at all raw observed stop events of the same line, stop and destination that day:

| Cause | Nature | Share of not found |
|---|---|---|
| No observed vehicle within the tolerance | Service | 75.0 % |
| A vehicle was there but removed by the quality filters | Method | 14.8 % |
| A vehicle was there but matched to another scheduled stop event | Method | 5.8 % |
| No data collected for this combination that day | Method | 4.5 % |

Three quarters of the not found stop events reflect the service. The remaining quarter is a limit of the processing chain, and is stated as such in the report.

## 8. Reading the result correctly

**Early running is not a tendency of the network, it is a consequence of the norm.** Early running weighs three times more than late running in the result (17.7 % against 5.5 %). This does not mean vehicles tend to run early: the distribution of deviations is roughly centred on zero. The window tolerates 60 s early but 180 s late, so the same spread around zero produces more "early" than "late". Measured during development, a symmetric ±60 s window gives slightly more late than early stop events. The asymmetry of the norm is deliberate: an early departure is worse for a passenger than a late one, since someone who arrives on time at the stop misses the vehicle.

**The result depends on the window.** The report shows the on-time rate for symmetric tolerances from ±30 s to ±180 s. Even at ±180 s (3 minutes either way), about one stop event in five is not on time: the result does not come from a strict definition.

## 9. Comparisons between lines and stops

- **Ranking of lines** (`62_dim_ligne_classement`). A line is ranked only if it runs in the first 7 **and** the last 7 days of the period. This excludes lines that appear or disappear during the period (summer works), without excluding lines that do not run on Sundays. Four lines are excluded this way (M1, M5, T7, 35), each checked against STIB works notices. They remain in every network total.
- **Stops**. A stop's on-time rate is shown only above 200 scheduled stop events, so that a rarely served stop does not appear red or green by chance. The **stop-specific effect** compares the rate observed at a stop with the rate expected from the lines serving it (each line's rate over its whole route, weighted by its stop events at that stop). A negative effect means the stop does worse than its lines elsewhere.
- **Segments** (`70_analyse_spatiale`). The time lost between two consecutive stops is the median gap between actual and scheduled running time, kept only for segments observed on at least 100 trips. A systematic loss with ordinary dispersion (for example tram 25, Patrie to Meiser, about +24 s in both directions) points to a timetable that allows too little time rather than to an unreliable section.

Delays are summarised with **medians**, never means: the distributions are asymmetric and the deviations are censored at the tolerance.

## 10. Limitations

- **Estimated times.** Observed times are last predictions, not measured arrivals.
- **Cancelled or very late.** Without a trip identifier, a cancelled trip and a delay beyond the tolerance look the same: both are "not found".
- **Terminus arrivals** are not published by the API. Routes end at the last observed stop.
- **Period.** One summer, including major roadworks, off-peak hours only (09:15 to 13:45). The results describe this period, not a typical year or peak hours.
- **Missing days.** Five collection days are missing (4, 5, 6, 11 and 12 July).
- **Unmapped stops.** 54 real-time stop codes have no GTFS equivalent (0.57 % of predictions), and five codes that first appeared after 19 August are not in the stop mapping. Both are excluded from the analysis.
