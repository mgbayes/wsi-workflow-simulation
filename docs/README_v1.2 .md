# Slide_Model v1.2

**Discrete-event simulation of digital pathology slide production, transport, scanner loading, whole-slide imaging, and post-scan availability**

**Version:** 1.2  
**Status:** Explicit multi-scanner dispatch, enabled-fleet capacity accounting, control-message routing, and daily scenario framework validated  
**Model time unit:** hours  
**Development release:** MATLAB / Simulink R2025b  
**Primary technologies:** Simulink, SimEvents, Stateflow

---

## Overview

`Slide_Model` is a discrete-event simulation (DES) framework for studying operational capacity in a digital pathology workflow.

Version 1.2 models the pathway from routine H&E slide availability through rack formation, scheduled courier transport, technician-mediated scanner loading, a configurable six-position scanner bank, slide-level scanning, and post-scan processing to the point at which a slide is available for review.

The model is intended to support questions such as:

- How many scanners are required for a given time-dependent workload?
- How do histology output timing, scanner capacity, and technician availability interact?
- How much work accumulates before scanning?
- How do courier schedules and technician attendance affect throughput?
- When do additional scanners produce diminishing operational returns?
- What fraction of daily slides can become `ReviewReady` by a specified cutoff?
- When does the system transition from scanner-limited to upstream- or staffing-limited behavior?
- Where does work-in-process accumulate under different operational scenarios?
- How can scanner capital planning be linked to measurable service-level targets?

Version 1.2 is a **validated simulation framework**, not a final capacity recommendation. Regression and stress tests establish model behavior; production scenario experiments are what support operational conclusions.

---

## What changed in v1.2

Version 1.2 replaces the v1.1 ordered first-unblocked scanner routing behavior with an explicit, deterministic fleet dispatcher.

The major changes are:

- `ScannerEnabled` is now the authoritative six-element scanner-availability vector.
- `ScannerGate1..6` are still used to enforce enabled/disabled scanner branches physically.
- `ScannerSelectSwitch` is controlled explicitly through its control port rather than using `First port that is not blocked`.
- a `ChooseScanner` MATLAB Function implements the routing rule:
  1. consider enabled scanners only;
  2. choose the first enabled scanner that is not busy;
  3. if all enabled scanners are busy, choose the enabled scanner with the smallest `ScannerQueue.n`;
  4. ties are resolved by the lowest scanner number.
- `scanner_busy` is exported by every `GenericScanner` and represents whether any rack/slide work remains anywhere inside that scanner.
- `SelectionEventToggle` converts each selected-port change into an alternating edge.
- `MessageTrigger` executes on **either** edge of that toggle and emits one control message.
- the control message is replicated:
  - one branch drives `ScannerSelectSwitch`;
  - one branch is received diagnostically to verify exact message delivery.
- `Message Receive` exposes both payload and receive-status outputs so the test harness can distinguish true message arrivals from ordinary sampled output.
- the final v1.2 validation harness no longer attempts to reconstruct SimEvents microstep ordering from independently logged signals at identical timestamps.
- scanner-count, technician-start, technician-check, and workload-level scenario sweeps are integrated into the daily production driver.
- the daily scenario driver now supports scanner counts 1 through 6 rather than only a sparse subset.

The external `ScannerBank` interface remains unchanged.

---

## Repository Components

The core model remains divided into three Simulink files:

```text
Slide_Model.slx
ScannerBank.slx
GenericScanner.slx
```

### `Slide_Model.slx`

Top-level workflow model containing:

- routine H&E workload generation,
- histology rack storage,
- scheduled courier pickup and transit,
- scanner-room loading queue,
- Stateflow technician/loading logic,
- the `ScannerBank` subsystem reference,
- post-scan processing,
- and the `ReviewReady` endpoint.

### `ScannerBank.slx`

Reusable fleet-level subsystem containing six scanner positions, six enable gates, explicit routing logic, fleet-capacity arithmetic, and scanner instrumentation.

Public interface:

```text
Entity input:
    Unscanned_Racks

Signal output:
    free_scan_slots

Entity output:
    Scanned_Slides
```

The rest of `Slide_Model` therefore does not need to know how many of the six scanner positions are enabled or how dispatch is implemented internally.

### `GenericScanner.slx`

Reusable scanner subsystem representing one P480-style scanner abstraction.

Each scanner instance owns:

- rack waiting/reservation capacity,
- reracking time,
- rack load/unload time,
- active-rack control,
- rack-to-slide replication,
- slide waiting,
- sequential slide scanning,
- rack retirement,
- per-scanner queue/counter instrumentation,
- and `scanner_busy`.

The v1.2 `GenericScanner` output contract is:

```text
1. ScannerQueue_n
2. scanner_busy
3. SlideQueue_n
4. RackSink_a
5. SlideScanning_d
6. Scanned_Slides   [entity]
```

All six scanner positions currently reference the same `GenericScanner` definition and use the same scanner timing parameters unless a future heterogeneous-fleet extension is implemented.

---

## High-Level Architecture

```text
Synthetic routine H&E workload
        ↓
HistoArrival
        ↓
HistoRackStore
        ↓
CourierPickupGate  ←  CourierGateControl
        ↓
CourierTransit
        ↓
LoadingQueue
        ↓
LoadingGate  ←  LoadingGateLogic (Stateflow)
        ↓
ScannerBank
        ├── fleet-capacity calculation
        ├── ChooseScanner
        ├── SelectionEventToggle
        ├── MessageTrigger
        ├── ScannerSelectSwitch
        ├── ScannerGate1 → Scanner_1
        ├── ScannerGate2 → Scanner_2
        ├── ScannerGate3 → Scanner_3
        ├── ScannerGate4 → Scanner_4
        ├── ScannerGate5 → Scanner_5
        └── ScannerGate6 → Scanner_6
                ↓
        merged scanned-slide stream
                ↓
PostScanProcessing
        ↓
ReviewReady
```

The model intentionally separates:

```text
MATLAB      = experiment design, parameters, schedules, random seeds
Stateflow   = operational technician/loading decisions
SimEvents   = physical entities, queues, servers, delays, and flow
```

That separation remains a central design principle.

---

# 1. Workload Generation

## HistoArrival boundary

The current model begins when routine H&E slide workload is considered **available for downstream digitization**.

It does not mechanistically simulate:

- grossing,
- tissue processing,
- embedding,
- microtomy,
- staining,
- coverslipping,
- or other upstream histology production steps.

The current workload generator instead represents the time-dependent output of Histology that becomes available to the downstream digital workflow.

This distinction matters operationally: the model evaluates the ability of the digital workflow to absorb the **temporal pattern** of histology output, not simply a daily slide total.

## Rack entities

One upstream SimEvents entity represents one physical Sakura-style rack.

Nominal rack capacity:

```text
20 slides
```

The rack carries:

```text
entity.SlideCount
```

The current uploaded generator / daily scenario implementation defaults to:

```text
rack_packing_policy = "sequential_fill"
```

Under sequential fill, rack capacity is filled continuously and a case may cross a rack boundary.

An alternative:

```text
"keep_cases_together"
```

is available in the scenario driver for experiments in which a case with <=20 slides should remain on one rack.

The packing policy is therefore an explicit modeling choice and should be reported with experimental results.

## Frozen regression trace

A historical seed-42 five-day regression workload used during model development produces:

```text
Synthetic H&E cases:    332
Synthetic H&E slides:  1592
Rack entities:            82
```

This frozen trace is useful for regression testing. It is not itself a production workload recommendation.

The underlying institutional slide-level dataset is not required to run the frozen regression model and should not be distributed in a public repository unless appropriately deidentified and approved.

---

# 2. Courier Model

Completed racks wait in `HistoRackStore` until a scheduled courier pickup.

The courier is modeled as a scheduled batch transfer:

```text
rack becomes ready
      ↓
HistoRackStore
      ↓
scheduled pickup opens gate
      ↓
all waiting racks released
      ↓
CourierTransit
      ↓
scanner-room workflow
```

Key behaviors:

- racks remain in Histology while the pickup gate is closed;
- all racks waiting at a pickup time are released as one batch;
- racks arriving after a pickup wait for the next scheduled pickup;
- all racks in a courier batch travel concurrently;
- courier transit is represented by an infinite-capacity Entity Server.

Current daily-scenario defaults:

```text
Courier pickups:   08:00, 10:00, 12:00, 14:00, 16:00, 18:00
Transit time:      10 min
```

These values are scenario assumptions and may be changed by the MATLAB driver.

The short gate-open duration used by the control logic is an implementation epsilon, not a physical courier-loading time.

---

# 3. Technician / Loading Controller

`LoadingGateLogic` is implemented in Stateflow.

A technician is modeled as periodically attending to the scanner area rather than continuously monitoring it.

At the beginning of each technician visit, the controller samples:

```text
load_q_n
free_scan_slots
```

and computes:

```text
racks_to_load = min(load_q_n, free_scan_slots)
```

This value is computed **once per visit**.

It is not continuously recomputed while the technician is loading racks.

Newly arriving racks and newly freed scanner capacity therefore wait until a subsequent technician visit.

## Transactional rack release

For each rack assigned during a visit:

```text
release one rack
      ↓
rack reaches scanner reservation boundary
      ↓
RackLoaded() acknowledgement toggles
      ↓
decrement racks_to_load
      ↓
release next rack
```

The explicit acknowledgement prevents the controller from releasing multiple racks because of stale scanner state.

The persistent-toggle pattern is also used for technician-check events so short events are not lost between Stateflow executions.

## Daily scenario technician parameters

Current scenario defaults include:

```text
Technician end:       19:30
Reference checks:     U(10,30) min
```

The primary scenario sweep currently tests technician start times:

```text
08:00, 09:00, 10:00, 11:00, 12:00
```

Check-frequency sensitivity currently uses:

```text
Frequent:       U(5,15) min
Reference:      U(10,30) min
Intermittent:   U(30,60) min
```

These are controlled experiment settings, not universal staffing recommendations.

---

# 4. ScannerBank v2 within Slide_Model v1.2

Version 1.2 contains six physical scanner positions:

```text
ScannerBank
    ├── ScannerGate1 → Scanner_1
    ├── ScannerGate2 → Scanner_2
    ├── ScannerGate3 → Scanner_3
    ├── ScannerGate4 → Scanner_4
    ├── ScannerGate5 → Scanner_5
    └── ScannerGate6 → Scanner_6
```

## Authoritative enable state

Scanner availability is represented by:

```matlab
ScannerEnabled = logical([1 1 1 1 1 1]);
```

or another six-element logical vector.

`ScannerEnabled` is the single source of truth for:

- routing eligibility,
- enabled/disabled gate configuration,
- and enabled-fleet rack-capacity calculation.

Disabled scanners remain physically present in the model but:

- receive no rack entities;
- should never become busy;
- contribute zero completed racks/slides;
- contribute zero `ScannerQueue.n`;
- and are excluded from enabled-fleet capacity.

For the current implementation:

```text
Scanner 1 must remain enabled.
```

This is because the controlled Entity Output Switch starts on port 1 before any selection-change message has been sent.

## Routing policy

`ScannerSelectSwitch` is configured:

```text
Switching criterion: From control port
Outputs:             6
Initial selected port: 1
```

The selected destination is calculated by `ChooseScanner`.

The v1.2 routing rule is:

```text
1. Ignore disabled scanners.

2. Scan enabled scanners in numerical order.
   If an enabled scanner is not busy:
       select the first such scanner.

3. If every enabled scanner is busy:
       select the enabled scanner with the smallest ScannerQueue.n.

4. If queue occupancy ties:
       lowest scanner number wins.
```

Equivalent conceptual logic:

```matlab
for i = 1:6
    if ScannerEnabled(i) && ~scanner_busy(i)
        selectedPort = i;
        return
    end
end

selectedPort = enabled scanner with minimum ScannerQueue_n;
```

This is intended to approximate a human-plausible policy:

- use an empty enabled scanner first;
- otherwise send the rack to the scanner with the most available rack capacity.

The router does **not** currently use:

- remaining slide count in the active rack,
- estimated time to completion,
- scan-progress percentage,
- scanner-specific predicted service time,
- pathologist priority,
- or future workload forecasts.

It is therefore a simple state-aware dispatcher, not an optimization algorithm.

## Why v1.1 routing was replaced

Version 1.1 used:

```text
First port that is not blocked
```

with static gates.

That routing criterion reflects whether a destination can accept an entity, not whether workload is balanced.

As a result, earlier scanner queues could be filled preferentially and sparse workloads could remain concentrated on one branch.

Round-robin routing was also evaluated but was incompatible with closed scanner gates because it could stall when the next round-robin destination was disabled.

Version 1.2 replaces both behaviors with explicit enabled-fleet routing.

---

# 5. Scanner Busy Definition

Every `GenericScanner` exports a Boolean `scanner_busy` signal.

A scanner is considered busy if work exists in any of the following stages:

```text
ScannerQueue
RerackTime
RackLoadUnloadTime
SlideQueue
SlideScanning
```

Conceptually:

```matlab
scanner_busy = ...
    ScannerQueue.n > 0 || ...
    RerackTime.n > 0 || ...
    RackLoadUnloadTime.n > 0 || ...
    SlideQueue.n > 0 || ...
    SlideScanning.n > 0;
```

Including `SlideScanning.n` is important because the final slide of an active rack may be in service even after the upstream slide queue becomes empty.

Therefore:

```text
scanner_busy == false
```

means the scanner is completely empty of modeled work.

---

# 6. selectedPort Signal-to-Message Control Path

The SimEvents `Entity Output Switch` control port requires a control message.

`ChooseScanner` produces an ordinary signal:

```text
selectedPort
```

The v1.2 control path converts each selected-port change into exactly one message:

```text
ChooseScanner.selectedPort
        │
        ├──────────────→ selected_scanner logger
        │
        ├──────────────→ MessageTrigger data input
        │
        └→ SelectionEventToggle
                    │
                    ↓
             MessageTrigger
             trigger = either
                    │
                    ↓
              Message Send
                    │
                    ↓
             Entity Replicator
                /         \
               /           \
diagnostic Message Receive  ScannerSelectSwitch control
```

## `SelectionEventToggle`

`SelectionEventToggle` stores:

- the last selected scanner;
- a persistent toggle state.

Whenever `selectedPort` changes, the toggle state flips:

```text
0 → 1 → 0 → 1 → ...
```

This is preferable to driving a rising-edge Triggered Subsystem directly from `Detect Change`.

Consecutive scanner-selection changes can produce consecutive `true` values from a `Detect Change` block, which creates only one rising edge. The toggle/either-edge architecture guarantees one trigger edge per selection change.

## `MessageTrigger`

`MessageTrigger` is a Triggered Subsystem configured:

```text
Trigger type: either
```

Inside the subsystem:

```text
selectedPort → Message Send
```

The Message Send enable port is not used.

Each toggle edge executes the subsystem once and therefore emits one selected-port control message.

## Diagnostic Message Receive

The diagnostic receive branch is configured to make real message arrivals observable.

Recommended/current settings:

```text
Use internal queue:                     ON
Queue type:                             FIFO
Queue length:                           16
Overwrite oldest if full:               OFF
Show receive status:                    ON
Initial value:                           0
Value source when queue is empty:        Use initial value
Sample time:                            -1
```

Two outputs are logged:

```text
selected_scanner_message
selected_scanner_message_status
```

The receive-status signal identifies actual message-consumption events.

This avoids misinterpreting a held message payload as repeated new messages.

---

# 7. GenericScanner Internal Sequence

The current scanner sequence is:

```text
Unscanned_Racks
      ↓
ScannerQueue
      ↓
RerackTime
      ↓
RackLoadUnloadTime
      ↓
CurrentRackGate
      ↓
UnpackSlides
      ├── original rack → RackSink
      ↓
SlideQueue
      ↓
SlideScanning
      ↓
Scanned_Slides
```

## ScannerQueue as reservation boundary

`ScannerQueue` is interpreted as the scanner-capacity reservation boundary.

The sequence is intentionally:

```text
reserve scanner capacity
      ↓
scanner-specific rerack/load delay
```

This lets the fleet dispatcher commit a rack to a specific scanner before scanner-local handling occurs.

The abstraction is designed for correct capacity accounting and timing. It is not a literal reconstruction of every physical hand movement.

---

# 8. Rack Capacity and Fleet Free-Slot Calculation

For the current P480-style abstraction:

```text
23 waiting/reserved rack positions
+ 1 active rack
= 24 physical rack positions
```

Per scanner:

```matlab
Scanner_RackQueueSize = 23;
```

Enabled-fleet waiting/reservation capacity is:

```matlab
Total_Scanner_Rack_Slots_Available = ...
    nnz(ScannerEnabled) * Scanner_RackQueueSize;
```

Examples:

```text
6 enabled scanners:
6 × 23 = 138 waiting/reservation slots

3 enabled scanners:
3 × 23 = 69 waiting/reservation slots
```

The active rack position is modeled separately and is not included in `free_scan_slots`.

## Fleet queue occupancy

Each scanner exposes its native `ScannerQueue.n`.

`ScannerBank` computes:

```matlab
fleetQueueN = ...
    S1_QueueN + S2_QueueN + S3_QueueN + ...
    S4_QueueN + S5_QueueN + S6_QueueN;
```

The six-way sum is retained even when scanners are disabled.

This is intentional: accidental occupancy on a disabled scanner remains visible to validation.

Fleet free capacity is:

```matlab
free_scan_slots = ...
    Total_Scanner_Rack_Slots_Available ...
    - fleetQueueN;
```

This scalar is returned to the top-level technician/loading controller.

The top-level controller therefore does not need scanner-specific capacity information.

---

# 9. Rack-to-Slide Conversion

The current model transports workload upstream as rack entities and converts the active rack to slide entities at the scanner.

The rack carries:

```text
SlideCount = N
```

`UnpackSlides` creates the corresponding slide-level workload.

The original rack entity is retired separately at `RackSink`.

This keeps courier/loading behavior rack-based while allowing scanning and post-scan behavior to occur at slide level.

Version 1.2 does **not** yet preserve a persistent independently generated slide entity from Histology through rack transport. Persistent slide identity remains a future extension.

---

# 10. Slide Scanning

Slides from the active rack enter `SlideQueue` and are scanned sequentially by `SlideScanning`.

Core regression / deterministic stress configuration can use:

```text
SlideScanning capacity: 1
Fixed scan time:        110 sec/slide
```

The daily production scenario driver uses a stochastic scan-time abstraction by default.

Current provisional default:

```text
Distribution: lognormal
Median:       58 sec
Mean:         110 sec
```

These values are development/scenario parameters and should be replaced or refined when raw empirical scan-time data are available.

They should not be interpreted as universal P480 performance values.

---

# 11. Post-Scan Processing

After scan completion:

```text
SlideScanning
      ↓
PostScanProcessing
      ↓
ReviewReady
```

`PostScanProcessing` represents aggregate latency between successful scan completion and availability for clinical review.

It may conceptually include:

- image transfer,
- network transit,
- storage or cloud ingestion,
- image-management processing,
- indexing,
- downstream workflow registration,
- viewer availability,
- and LIS/EHR linkage.

These mechanisms are not separately simulated in v1.2.

## Infinite-capacity abstraction

```text
PostScanProcessing Capacity = Inf
```

Each slide independently receives its own post-scan delay.

The current default daily-scenario distribution is lognormal with:

```text
Median: 20 min
P95:    120 min
```

This represents independent per-slide latency rather than a finite shared infrastructure bottleneck.

If future data demonstrate network, storage, cloud, or ingestion contention, the stage can be replaced with explicit finite resources without redesigning the upstream scanner architecture.

---

# 12. ReviewReady Boundary

`ReviewReady` is the endpoint of `Slide_Model` v1.2.

It means:

> The newly scanned slide has completed all modeled post-scan processing and is available for pathologist review.

The current model does not include:

- pathologist diagnostic interpretation time,
- case sign-out,
- case assignment,
- case completeness logic,
- later retrieval of archived WSIs,
- viewer rendering performance,
- cache behavior,
- or long-term storage retrieval.

---

# 13. Parameter Ownership

Scenario parameters should be supplied by MATLAB rather than embedded permanently in model logic.

Important variables include:

```matlab
% Histology workload
igt_hr
rack_slide_count

% Courier
courier_igt_hr
courier_transit_hr

% Technician
on_duty_ts
check_toggle_ts

% Scanner fleet
ScannerEnabled
Scanner_RackQueueSize
Total_Scanner_Rack_Slots_Available
Scanner_RerackTime
Scanner_RackLoadTime
Scanner_SlideQueueSize
Scanner_SlideScanTime

% Stochastic scan-time parameters
ScanTime_Mu
ScanTime_Sigma

% Post-scan processing
PostScan_Mu
PostScan_Sigma
```

This enables:

- scenario sweeps,
- sensitivity analyses,
- Monte Carlo replications,
- alternative staffing schedules,
- alternative courier schedules,
- scanner-count experiments,
- scanner-speed experiments,
- and future empirical distribution fitting

without rewriting the core DES architecture.

---

# 14. v1.2 Validation Strategy

Development uses progressive subsystem validation rather than relying on only a final end-to-end simulation.

## Why timestamp-reconstructed oracles were retired

SimEvents can execute multiple ordered microsteps at the same simulation time.

Separately logged `To Workspace` signals retain timestamps and values but do not necessarily preserve enough information to reconstruct the exact internal event ordering across independent signals.

Early v1.2 test harnesses attempted to compare separately logged queue, busy, and selected-port signals point-by-point at identical times.

That produced apparent contradictions even when:

- the physical routing result was correct;
- the direct fleet-capacity signals were bounded correctly;
- and the exact control-message sequence was lossless.

The final validation strategy therefore avoids treating reconstructed same-time microstep ordering as a pass/fail oracle.

Instead it combines:

- static architecture/wiring audits;
- local scanner-capacity bounds;
- fleet-capacity bounds;
- direct `free_scan_slots` range/complement checks;
- Boolean `scanner_busy` checks;
- exact selected-port transition counting;
- exact toggle-edge counting;
- exact Message Receive status-event counting;
- exact control-message payload sequence comparison;
- enabled/disabled scanner behavior;
- physical per-scanner rack distribution;
- and cumulative counter monotonicity.

---

# 15. Final ScannerBank v1.2 Stress Validation

The final harness is:

```text
run_loader_scanner_model_multi_stress_v1_2_final_verified.m
```

Architecture under test:

```text
TestRackGenerator
      ↓
LoadingQueue
      ↓
LoadingGate / LoadingGateLogic
      ↓
ScannerBank
      ├── ChooseScanner
      ├── SelectionEventToggle
      ├── MessageTrigger
      ├── Entity Replicator
      ├── diagnostic Message Receive
      ├── ScannerSelectSwitch
      ├── ScannerGate1..6
      └── GenericScanner × 6
      ↓
SlideSink
```

Five stress scenarios are used:

1. six-scanner baseline;
2. three scanners with one waiting slot each under heavy backlog;
3. sparse rack supply with three enabled scanners;
4. noncontiguous enabled fleet `[1 0 1 0 1 0]` with slow handling;
5. three-day shift-boundary run with all six scanners enabled.

Representative validated physical outcomes include:

```text
Six-scanner heavy backlog:
racks completed by scanner ≈ 39 / 39 / 39 / 38 / 38 / 38

Three-scanner tiny-capacity stress:
racks completed = 22 / 22 / 22

Noncontiguous enabled scanners 1 / 3 / 5:
racks completed = 23 / 23 / 23
disabled scanners = 0

Three-day six-scanner stress:
117 racks completed on each scanner
```

The exact control-message path was also validated.

For example, in the six-scanner baseline:

```text
selected_scanner transitions
        =
SelectionEventToggle edges
        =
Message Receive status events
```

and the received message payload sequence exactly matched the selected-scanner transition sequence.

The same property held in the long multi-day stress run.

The final stress harness reports all five scenarios as passing.

---

# 16. Daily Scenario / Pilot Framework

The current production-scenario driver is:

```text
run_slide_model_daily_scenarios_v2_scannerbank_v2.m
```

The script is designed around the primary operational question:

> For a representative daily H&E workload and resource configuration, what percentage of that day's slides are `ReviewReady` by a chosen cutoff?

## Primary experiment

Current design:

```text
target daily workload
    ×
active scanners
    ×
technician start time
```

Default target mean workload levels:

```text
Low:       500 slides/day
Medium:   1000 slides/day
High:     2000 slides/day
```

Active scanners:

```text
1, 2, 3, 4, 5, 6
```

Technician start:

```text
08:00, 09:00, 10:00, 11:00, 12:00
```

Technician end:

```text
19:30
```

Primary cutoff:

```text
17:30
```

Cutoff curves are also generated across:

```text
12:00 to 20:00 in 30-min increments
```

## Check-frequency sensitivity

At a reference technician start time, the driver can compare:

```text
Frequent       U(5,15) min
Reference      U(10,30) min
Intermittent   U(30,60) min
```

across scanner counts.

## One-day replication design

Each scenario replication is one independent modeled day.

There is no carryover backlog from one production-scenario replication to another.

This is intentional for the current PathVisions-oriented experiment.

The core model and separate stress harness support multi-day simulation, but multi-day deferred-work policies are not part of the current primary experiment.

## Daily denominator

For:

```text
% ReviewReady by cutoff
```

the denominator is **all slides generated in that modeled day**.

Therefore late histology availability remains part of the whole-workflow service-level result.

This is an important interpretation point:

A slide that becomes histology-ready too late to complete scanning/post-scan processing before the cutoff still counts against same-day performance.

This lets the model test the whole workflow rather than scanner throughput in isolation.

## Reused workload realizations

Within each workload replication, the same generated workload realization is reused across resource configurations.

This supports paired comparisons between scanner/staffing scenarios.

Realized slide totals are stochastic around the target mean workload.

Therefore labels such as:

```text
500 slides/day
1000 slides/day
2000 slides/day
```

should be interpreted as **target mean / nominal workload levels**, not a guarantee that each replication contains exactly that number of slides.

---

# 17. Pilot Outputs

The pilot framework generates:

```text
daily_scenario_run_results.csv
daily_scenario_summary.csv
daily_cutoff_curves.csv
workload_realizations.csv
expected_hourly_workload_profiles.csv
daily_scenario_results.mat
```

and figures including:

```text
figure_workload_profiles
figure_primary_heatmaps
figure_cutoff_curves_medium
figure_check_sensitivity
```

The pilot run is intended to verify:

- that scenario ranges span both constrained and unconstrained operating regions;
- that scanner-count effects are monotonic or plausibly saturating;
- that staffing effects are visible;
- that stochastic variability is measurable;
- and that the production experiment is worth running with larger replication counts.

Pilot results should not be treated as final capacity recommendations.

---

# 18. Operational Interpretation Emerging from the Pilot

The current pilot suggests that the model is capturing more than scanner throughput alone.

The whole-system result depends on the interaction of:

```text
time-dependent histology output
        ×
courier timing
        ×
technician availability / check behavior
        ×
scanner fleet capacity
        ×
post-scan latency
```

This means a digital laboratory cannot necessarily reach a same-day service target by adding scanners alone.

At low workload, additional scanners can reach a region of diminishing returns because another part of the workflow becomes limiting.

At intermediate workload, scanner count and staffing interact strongly.

At high workload, scanner capacity may remain the dominant constraint even with the full tested fleet.

These are **pilot observations** that motivate the production experiment. They are not yet final quantitative recommendations.

---

# 19. Current v1.2 Assumptions and Limitations

Version 1.2 deliberately simplifies several parts of the real workflow.

## Workload scope

The main generator currently represents newly produced routine H&E workload.

It does not yet include independent streams for:

- H&E levels,
- recuts,
- IHC,
- special stains,
- rescans,
- pulled/archive material,
- cytology,
- hematopathology,
- electron microscopy,
- or frozen-section workflows.

## Histology production

Histology is represented as a workload-availability boundary rather than a mechanistic processing laboratory.

Therefore the current model cannot yet evaluate:

- microtome count,
- staining capacity,
- coverslipper capacity,
- histotechnologist task allocation,
- processor schedules,
- or upstream histology resource contention.

It can, however, test how the observed/synthetic time-dependent Histology output interacts with downstream digital capacity.

## Rack representation

Slides are represented upstream by a rack-level `SlideCount` attribute rather than as persistent individual slide objects.

## Scanner fleet

The current bank contains six identical `GenericScanner` instances.

It does not yet model:

- heterogeneous scanner types,
- AT2 versus P480 fleet mixtures,
- scanner-specific slide compatibility,
- scanner failures,
- maintenance,
- backup-only operation,
- priority routing,
- or specialty scanners with different service distributions.

## Scanner routing

The v1.2 router is state-aware but intentionally simple.

It uses:

```text
enabled
scanner_busy
ScannerQueue.n
```

It does not predict future completion time or remaining scan work.

## Technician model

Technician availability is represented through:

- coverage hours,
- scanner-check frequency,
- and scanner-local rack-handling delays.

A technician is **not yet an explicit SimEvents shared resource** across the scanner fleet.

Because scanner capacity is reserved before scanner-local rerack/load stages, handling delays on different scanner paths can overlap in v1.2.

This is a documented abstraction, not an assertion that one physical technician can perform multiple loading tasks simultaneously.

## Post-scan processing

Post-scan delay is modeled as independent per-slide latency with infinite capacity.

Network, storage, cloud, and ingestion contention are not explicitly modeled.

## Case-level logic

The current model is slide/rack oriented after workload generation.

It does not yet model:

- case completeness,
- case-level `ReviewReady`,
- pathologist case assignment,
- pathologist sign-out capacity,
- or case-priority rules.

---

# 20. Planned v2 / Post-v1.2 Extensions

Several extensions have already been identified.

These are roadmap items, not part of the validated v1.2 implementation.

## Persistent slide entities

A future version can generate individual slide entities in Histology:

```text
synthetic case
      ↓
individual slide entities
      ↓
Composite Entity Creator
      ↓
rack composite entity
      ↓
courier / scanner loading
      ↓
Composite Entity Splitter
      ↓
original slide entities
      ↓
scanning
```

Potential attributes:

```text
CaseID
SlideID
Protocol
TissueType
Magnification
FileSize
Priority
```

This would preserve slide identity throughout the entire workflow.

## Explicit technician resource

Racks could acquire technicians from a shared SimEvents Resource Pool:

```text
rack waiting
      ↓
acquire ScannerTech
      ↓
rerack / load
      ↓
release ScannerTech
```

This would make technician count an explicit finite resource.

## Heterogeneous scanners

Future scanner positions may have independent parameter namespaces.

Candidate scanner-specific parameters include:

```text
scanner type
enabled / disabled state
rack queue capacity
slide queue capacity
rerack requirement
load time
scan-time distribution
slide compatibility
priority
maintenance / downtime state
```

This would support mixed fleets such as:

```text
production P480 scanners
AT2-style scanners
backup scanners
specialty / low-volume scanners
```

while preserving the external `ScannerBank` abstraction.

## Expanded workload streams

Future versions can add asynchronous workload for:

- levels,
- recuts,
- IHC,
- special stains,
- rescans,
- and archive/pulled-slide workflows.

## Bottleneck attribution at a clinical cutoff

A useful extension is to classify every non-ReviewReady slide at a chosen cutoff into the state where it remains:

```text
not yet histology-ready
waiting for courier
waiting for technician loading
waiting in scanner
actively scanning
post-scan processing
ReviewReady
```

This would allow the simulation to show **why** a service target was missed and how the dominant bottleneck moves as scanner capacity changes.

## Tiered multi-day turnaround policy

A future multi-day experiment can evaluate a tiered service policy such as:

```text
Histology-ready by noon:
    eligible for same-day ReviewReady target

Histology-ready after noon:
    intentionally deferred into next-day workload
```

The model can then ask:

- what fleet/staffing level meets the same-day service class;
- what fleet/staffing level clears deferred next-day work;
- whether backlog remains stable over repeated days;
- and whether deliberate deferral smooths downstream pathologist workload.

This is different from simply maximizing same-day scanner throughput.

## Cost / ROI coupling

Simulation outputs can later be coupled to external ROI or capital-planning frameworks.

Potential outputs include:

```text
scanner count
staffing requirement
same-day SLA attainment
next-day SLA attainment
scanner utilization
deferred workload
backlog stability
```

These can be compared with:

- scanner capital cost,
- service/maintenance cost,
- labor cost,
- space/infrastructure cost,
- avoided manual handling,
- productivity gains,
- and other ROI assumptions.

The DES should supply the operating-point performance; the financial model should supply the economic valuation.

## Pathologist workload coupling

With case-level logic, future versions can measure the timing of completed cases delivered to pathologists.

This would allow optimization not only for scanner throughput but also for:

- hourly pathologist workload,
- late-day work release,
- overnight deferred workload,
- and workload smoothing between days.

---

# 21. Design Principles Established Through v1.2

The following principles should be preserved as the model evolves.

1. **Separate physical storage from processing capacity.**  
   Rack storage, active scanning, and downstream latency are different resources.

2. **Separate human availability from unattended scanner operation.**  
   Personnel control replenishment; loaded scanners can continue operating without continuous human attendance.

3. **Keep exogenous schedules and stochastic parameters in MATLAB.**  
   This supports reproducible scenario sweeps and Monte Carlo analysis.

4. **Use Stateflow for operational decision logic.**  
   The technician visit controller owns state and transactional sequencing.

5. **Use SimEvents for physical/entity behavior.**  
   Queues, servers, capacity, movement, and service times remain in the DES layer.

6. **Use explicit routing when “not blocked” is not equivalent to the desired operational decision.**  
   A physically available scanner queue is not necessarily the scanner a human operator would choose.

7. **Prefer native SimEvents statistics for validation.**  
   Avoid unnecessary continuously updated custom counters when `.n`, `.a`, or `.d` statistics already expose the required state.

8. **Do not reconstruct SimEvents microstep order from independent workspace logs unless ordering information is explicitly preserved.**  
   Same-time timestamps are not sufficient to recover every internal event ordering.

9. **Validate control paths as well as physical outcomes.**  
   In v1.2 the selected-port signal, toggle event, control message, and physical scanner destination are all tested.

10. **Validate conservation and invariants at subsystem boundaries.**  
    A simulation is not considered validated merely because it runs.

11. **Preserve subsystem interfaces when increasing fidelity.**  
    Scanner internals can evolve without forcing redesign of the entire workflow.

12. **Distinguish assumptions from measured operational facts.**  
    Development and sensitivity parameters must remain explicit and configurable.

13. **Do not infer production recommendations from regression tests.**  
    Regression validates architecture; scenario experiments answer operational questions.

14. **Treat daily volume and temporal workload shape as different information.**  
    The same daily slide count can produce different resource requirements depending on when the slides become available.

---

# 22. Recommended Regression Tests

Before accepting major changes, run the scanner-bank stress harness:

```text
run_loader_scanner_model_multi_stress_v1_2_final_verified.m
```

The harness should report all five stress scenarios as passing.

For daily integration / experiment development, use:

```text
run_slide_model_daily_scenarios_v2_scannerbank_v2.m
```

Recommended workflow:

```text
1. run_mode = "smoke"
2. inspect CSV/MAT outputs and figures
3. run_mode = "pilot"
4. inspect variance and scenario behavior
5. run_mode = "production" only after pilot behavior is acceptable
```

The scenario driver performs static architecture/instrumentation checks before the sweep and fails fast on structural violations.

---

# 23. Validation Instrumentation

The v1.2 ScannerBank retains persistent workspace diagnostics.

Important signals include:

```text
selected_scanner
scanner_select_change
selected_scanner_message
selected_scanner_message_status

S1_QueueN ... S6_QueueN
S1_ScannerBusy ... S6_ScannerBusy
S1_SlideQueueN ... S6_SlideQueueN
S1_Racks ... S6_Racks
S1_Slides ... S6_Slides

total_scanner_queue_n
free_scan_slots_bank
```

`scanner_select_change` currently records the persistent selection-event toggle state.

The name is historical; semantically it is an alternating event toggle, not a one-sample pulse.

The validation scripts should:

- discover existing `To Workspace` blocks recursively by `VariableName`;
- use saved model instrumentation rather than creating duplicate permanent loggers;
- avoid relocating or deleting instrumentation during test execution;
- and treat instrumentation as observational only.

Diagnostic instrumentation must not participate in routing/control decisions.

---

# 24. Working Directory Recommendation

For repeated simulations, parameter sweeps, or Monte Carlo experiments, use a local working directory that is not actively synchronized by OneDrive or another cloud-sync client.

Example:

```text
C:\MATLAB\Slide_Model\
```

Repeated Simulink load/close operations may create or delete autosave/cache files. Cloud-sync clients can temporarily lock these files and produce unrelated permission warnings.

Generated Simulink cache and code-generation files may also be redirected to a local scratch directory.

Version-controlled or archival copies can be maintained separately.

---

# 25. Repository Layout

The public v1.2 research release keeps the runnable model, validation harness, and
experiment driver together in the repository root because the current MATLAB
scripts expect these dependencies to be colocated.

```text
wsi-workflow-simulation/
│
├── README.md
├── LICENSE
├── .gitignore
│
├── Slide_Model.slx
├── ScannerBank.slx
├── GenericScanner.slx
├── Loader_Scanner_Model_Multi.slx
├── he_case_parameters.mat
│
├── run_slide_model_daily_scenarios_v2_scannerbank_v2.m
├── run_loader_scanner_model_multi_stress_v1_2_final_verified.m
├── export_model_artifacts_v2.m
│
├── results/
│   └── v1.2-pilot/
│       ├── README.md
│       ├── daily_scenario_run_results.csv
│       ├── daily_scenario_summary.csv
│       ├── daily_cutoff_curves.csv
│       ├── workload_realizations.csv
│       └── expected_hourly_workload_profiles.csv
│
└── docs/
    ├── README_v1.2.md
    ├── HistoArrival_Requirements.md
    ├── index.html
    ├── .nojekyll
    ├── diagrams/
    ├── figures/
    ├── poster/
    ├── stylesheets/
    └── support/
```

Generated working directories such as `daily_scenario_outputs/` and
`model_artifacts/` are not part of the source release. The files under
`results/v1.2-pilot/`, `docs/figures/`, `docs/diagrams/`, and `docs/poster/`
are intentionally archived release artifacts supporting reproducibility,
documentation, and the associated Pathology Visions 2026 presentation.

---

# 26. Version History

## v1.0

Established the end-to-end rack/slide workflow:

```text
Histology
→ courier
→ technician loading
→ scanner
→ post-scan
→ ReviewReady
```

and demonstrated exact rack/slide conservation in the frozen regression case.

## v1.1

Added:

- configurable scanner enable/disable gates;
- enabled-fleet capacity calculation;
- validation instrumentation organization;
- static scanner-count experimentation.

Routing remained based on `First port that is not blocked`.

That architecture was useful for enable/disable validation but was later shown to create an ordered-fill artifact rather than the desired balanced fleet behavior.

## v1.2

Adds and validates:

- explicit six-position scanner routing;
- `ScannerEnabled` as authoritative fleet state;
- idle-first / shortest-queue dispatch;
- deterministic tie-breaking;
- complete `scanner_busy` definition;
- robust signal-to-message conversion using `SelectionEventToggle`;
- exact routing-message instrumentation;
- noncontiguous enabled-fleet support;
- improved validation semantics for SimEvents same-time events;
- integrated 1-6 scanner scenario sweeps;
- technician-start and technician-check sensitivity experiments;
- stochastic daily workload replications;
- and pilot output/figure generation.

Version 1.2 is the first release in which the scanner bank behaves as an explicit state-aware fleet dispatcher rather than an ordered set of independent queues.

---

# 27. v1.2 Milestone

As of v1.2, the following architecture is considered validated:

```text
synthetic routine H&E workload
        ↓
rack formation
        ↓
histology rack storage
        ↓
scheduled courier pickup
        ↓
courier transit
        ↓
scanner-room LoadingQueue
        ↓
visit-batch technician admission
        ↓
ScannerBank v2
        ↓
enabled-fleet dispatch
        ↓
first enabled non-busy scanner
        OR
least-occupied enabled ScannerQueue
        ↓
one-shot control message
        ↓
enabled scanner gate
        ↓
rack-to-slide conversion
        ↓
sequential slide scanning
        ↓
independent post-scan latency
        ↓
ReviewReady
```

The validated scanner-bank stress suite includes:

```text
six enabled scanners
three enabled scanners
tiny local capacity
sparse workload
noncontiguous enabled fleet
slow handling
multi-day shift boundaries
```

and confirms:

```text
enabled-fleet capacity bounds
disabled-scanner isolation
per-scanner queue bounds
scanner_busy behavior
selection validity
one selected-port transition → one toggle edge
one toggle edge → one received control message
message payload sequence = selected-scanner transition sequence
balanced physical routing under deterministic heavy backlog
```

The daily scenario framework has also reached pilot operation.

The next phase is not another routing rewrite.

The next phase is:

```text
model-fidelity refinement
+ production experiment design
+ replication / uncertainty analysis
+ bottleneck attribution
+ future multi-day / ROI / case-level extensions
```

---

## Citation / Use Note

If this model is used in a poster, manuscript, presentation, or public repository, clearly distinguish:

- source-data-derived parameters;
- synthetic simulation outputs;
- operational assumptions;
- provisional development parameters;
- pilot results;
- production results;
- and validated model behavior.

No capacity, staffing, equipment, or financial recommendation should be presented as a consequence of regression tests alone.

The model is designed to quantify operational tradeoffs; the validity of any recommendation depends on the quality of the empirical inputs and the appropriateness of the scenario assumptions.
