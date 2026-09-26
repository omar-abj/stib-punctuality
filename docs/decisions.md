# Decisions and tested hypotheses

This page lists the choices that shape the result, with the alternative that was set aside and the reason. The second part lists hypotheses that were tested during the project and rejected by measurement.

Figures marked *(development)* were measured on an earlier run (44 days, or line 25 only) and illustrate why a decision was taken; published results are in [methodology.md](methodology.md).

## 1. What is measured

**The denominator is the timetable, not what was observed.**
*Alternative:* rate of on-time vehicles among observed vehicles.
*Why:* a vehicle that never runs would simply disappear from an observed-based rate and improve it. Counting against the timetable answers the passenger's question: of the service announced, how much was delivered on time?

**Scheduled stop events the feed can never publish are removed from the denominator.**
*Alternative:* keep them (they would count as missing vehicles), or exclude known cases by hand.
*Why:* the API publishes nothing for arrivals at a terminus, whatever the service. A first version excluded one stop by name; the rule "this line, stop and destination was never published during the period" found that case and others the manual list had missed. The stop events are flagged, not deleted, so the choice can be reviewed.

**The on-time window is −60 / +180 s, and it is presented as a convention of this project.**
*Alternative:* a symmetric window (±60 s or ±120 s).
*Why:* an early departure is worse for a passenger than a late one: someone who arrives on time at the stop misses the vehicle, while a late vehicle still comes. The window encodes that judgement. It is not presented as an official published norm, and its effect on the result is shown in the report (sensitivity curve, section 2 below).

**The main indicator is the on-time rate; the matching rate is reported as coverage.**
*Alternative:* the first version of the project used the share of unmatched stop events as main indicator.
*Why:* the matching rate depends on the matching tolerance, which differs between lines, so it cannot rank lines. The on-time rate can: every line has a tolerance of at least 180 s, so the whole window is measurable everywhere. Both rates are published, never one without the other.

**Analysis window 09:15 to 13:45, inside a collection window of 09:00 to 14:00.**
*Why:* at the edges of the collection window, a vehicle is not followed long enough to be rebuilt. In the first 15 minutes, 26 % of scheduled stop events were unmatched, against 3 to 6 % in the middle of the day *(development)*. Off-peak hours are also a deliberate scope: without peak congestion, structural gaps (timetable, route, stop) are easier to isolate.

## 2. Method

**The time of an observed stop event is the last prediction before the vehicle leaves the feed.**
*Alternative:* none available, the API publishes no arrivals.
*Why:* it is the closest estimate the feed provides. It is always called an estimate, never an observed arrival.

**Quality filters: seen in at least 2 cycles, last prediction at most 180 s before the predicted time.**
*Why:* a vehicle seen once, or announced long in advance and never updated, is unreliable. The cost was measured rather than assumed (`experiments/46_sensibilite_filtres`), and it appears in the report: 14.8 % of the stop events not found are due to these filters.

**Matching tolerance set per line, from the 10th percentile of headways.**
*Alternative:* one tolerance for the whole network (240 s in the first version).
*Why:* on a line with a vehicle every 6 minutes, 240 s reaches the next trip, and a late vehicle would be matched to the following trip and reported as early. The error would be silent. The 10th percentile describes the moments when vehicles are closest together, which is when confusion is most likely.

**The tolerance is stored in a table, not recomputed.**
*Why:* the percentile function used is approximate and not deterministic: two runs gave 184 s and 205 s for the same line *(development)*. Acceptable to set a threshold, not for a published figure. A stored value also cannot change silently if the timetable is reloaded.

**Reciprocal nearest neighbour, one-to-one.**
*Alternative:* an optimal assignment algorithm.
*Why:* the simpler method is enough here. On line 25, the second iteration of the loop added 9 pairs out of 57,415 *(development)*: almost every pair is found at once, so a more complex algorithm would not change the result.

**When GTFS feeds overlap, the most recent one wins.**
*Why:* without a rule, a date covered by two feeds would count its scheduled stop events twice, without any SQL error.

## 3. Data model

**Grain of the fact table: one stop event, in a single table.**
*Alternative:* "stop × trip × date", or two tables (matched and unmatched).
*Why:* an observed stop event with no scheduled counterpart has no trip. Two tables would force the main indicator to add denominators from two places. See [data_model.md](data_model.md).

**Additive 0/1 counters, computed in SQL.**
*Alternative:* a status column, with the categories computed in DAX.
*Why:* a ratio of sums is correct at any level of aggregation. The on-time window is a methodological choice, so it lives in a numbered, versioned script and not in a formula inside the report.

**One database, layers separated by table prefixes.**
*Alternative:* a separate database for the warehouse.
*Why:* SQL Server does not allow foreign keys across databases, and the derived tables can be rebuilt from the scripts at any time.

**Surrogate keys stored in tables, never generated in views.**
*Why:* a `ROW_NUMBER()` in a view is recalculated at every query. A key could point to another stop the next day, without any error.

## 4. Analysis choices

**Medians, not means, for delays.**
*Why:* the distributions are asymmetric and the deviations are censored at the tolerance.

**Lines excluded from rankings by a rule on dates, not on volume.**
*Alternative:* a minimum number of stop events, or of days.
*Why:* volume mixes duration and frequency. Line 72 (4,900 stop events over 44 days, one bus an hour) and T7 (4,834 over 11 days, normal frequency) have the same total but nothing in common *(development)*. A minimum number of days would have excluded lines that simply do not run on Sundays. The rule "present in the first 7 and the last 7 days" excludes only lines that appear or disappear during the period. The four lines excluded (M1, M5, T7, 35) were each checked against STIB works notices, and they remain in every network total.

**Replacement services stay in the ranking, labelled.**
*Why:* removing them would be one more exclusion to justify. Showing them with a label costs one sentence.

**Stops: a reliability threshold and a comparison with their own lines.**
*Why:* under 200 scheduled stop events, a rate can be red or green by chance. A stop served by unpunctual lines will look bad even if the stop itself causes nothing; the stop-specific effect compares each stop with the rate its lines achieve elsewhere.

**Line 25 was the development line, and it is not typical.**
*Why it matters:* line 25 runs early far more often than the network (29.7 % more than 60 s early, against 19.8 % for the network, on symmetric thresholds *(development)*). Any profile built on it describes a particularly early line and is labelled as such.

**Weather dropped as an explanatory axis.**
*Why:* summer 2026 in Brussels offered too little variation (almost no rain during the analysis window) to separate a weather effect from a calendar effect. This is a negative result, stated as such. The weather dimension remains in the model.

## 5. Hypotheses tested and rejected

**"Vehicles run early three times more often than late."**
The raw result (17.7 % early, 5.5 % late) suggests it. On a symmetric window, on the range where no line is censored, the result reverses: 19.8 % early against 22.9 % late at ±60 s, 6.8 % against 9.0 % at ±120 s, with a median deviation of −2 s *(development)*. The factor of three comes from the asymmetric window, not from the vehicles. *The distribution is centred; what tilts is the norm.*

**Tram 25, Patrie to Meiser: the time loss comes from the timetable's timing points.**
Rejected: the timing points in the GTFS do not coincide with the points where time is lost.

**The same section: the loss is a composition effect (different trips at different stops).**
Rejected: restricted to the trips that serve all stops, the profile is almost identical. The result was confirmed through the full star schema and holds over the full period: +24 s and +22 s median depending on the direction, on 1,300 to 1,400 trips each.

**Early running on line 25 comes from a shift in the matching (a missing vehicle makes the next one look early).**
Measured and insufficient: it explains about 5 % of the early stop events *(development)*.

**Early running comes from times interpolated by the GTFS between timing points.**
Not supported: early running does not concentrate at interpolated stops, and the median deviation does not follow the share of early running. What the data show instead is a spread that grows along the route: the typical vehicle does not gain time, but the extremes accumulate small gains until they run well ahead of schedule.

**The regular 60 s pattern in the distribution of deviations comes from real-time times rounded to the minute.**
Rejected: if the feed rounded to the minute, deviations that are exact multiples of 60 s would dominate; they rank 11th. The cause remains open (the timetable grid or the matching). It does not affect the shape or position of the distribution, nor any conclusion.
