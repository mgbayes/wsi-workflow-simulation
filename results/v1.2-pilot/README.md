# v1.2 Pilot Results

This directory contains the curated CSV outputs from the Slide_Model v1.2 pilot scenario experiment.

The pilot was designed to verify experiment behavior across constrained and unconstrained operating regions before a larger production replication study. It uses **3 replications per scenario** and should not be interpreted as a final staffing, scanner-capacity, or capital recommendation.

## Pilot design

Primary experiment:

- target mean workload: 500, 1000, and 2000 slides/day;
- active scanners: 1–6;
- scanner technician start: 08:00–12:00;
- technician end: 19:30;
- reference scanner checks: uniform 10–30 minutes;
- same-day endpoint: percent of daily slides `ReviewReady` by 17:30.

Technician-check sensitivity compares:

- Frequent: uniform 5–15 minutes;
- Reference: uniform 10–30 minutes;
- Intermittent: uniform 30–60 minutes.

Daily workload realizations are stochastic. A label such as `1000 slides/day` denotes a target mean workload, not an exact slide count in every replication.

## Files

| File | Contents |
|---|---|
| `daily_scenario_run_results.csv` | Run-level scenario results and validation fields |
| `daily_scenario_summary.csv` | Scenario-level summary statistics |
| `daily_cutoff_curves.csv` | Time-resolved percentage `ReviewReady` across cutoff times |
| `workload_realizations.csv` | Realized cases, slides, and racks for the reused workload replications |
| `expected_hourly_workload_profiles.csv` | Expected hourly slide-availability profiles for the nominal workload levels |

The corresponding publication-ready figures are in [`../../docs/figures/`](../../docs/figures/), and the Pathology Visions 2026 poster is in [`../../docs/poster/`](../../docs/poster/).

The canonical experiment driver is [`../../run_slide_model_daily_scenarios_v2_scannerbank_v2.m`](../../run_slide_model_daily_scenarios_v2_scannerbank_v2.m).
