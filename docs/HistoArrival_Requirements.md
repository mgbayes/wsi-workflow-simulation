# HistoArrival Entity Generator Requirements and Validation

## Purpose

This document captures the requirements, assumptions, implementation
decisions, and validation results for the **HistoArrival** component of
the digital pathology discrete-event simulation (DES). The component
represents routine H&E workload becoming available for downstream
digital pathology operations.

The intent is to make the model implementation reproducible and to
distinguish:

-   observations supported by the source data,
-   operational assumptions used by the model,
-   implementation choices made for SimEvents, and
-   validation criteria used to freeze the component.

This document describes the current **v1 routine H&E generator**. It
does not define the later courier, scanner-room queue, scanner loading,
scanner-bank, or post-scan logic.

------------------------------------------------------------------------

## 1. Model Boundary

### 1.1 Upstream boundary

The HistoArrival model begins when routine H&E slides are considered
**available for downstream digitization**.

The model does **not** currently simulate:

-   grossing,
-   tissue processing,
-   embedding,
-   microtomy,
-   staining,
-   coverslipping, or
-   other upstream histology production steps.

The timing observed in the source data is therefore used as a proxy for
downstream slide availability rather than as a mechanistic simulation of
the complete histology laboratory.

### 1.2 Entity definition

The SimEvents entity emitted by HistoArrival is a **physical Sakura
rack**, not an individual slide and not an individual case.

Each rack represents up to:

``` text
20 slides
```

The rack entity carries workload metadata that can be consumed by
downstream processes.

Current required entity attribute:

``` text
SlideCount
```

Planned/useful attributes may include:

``` text
RackID
NumCases
```

Additional timing or routing attributes may be added later if required,
but the event time itself can represent rack readiness.

------------------------------------------------------------------------

## 2. Source Data and Routine H&E Definition

The generator parameters are derived from the deidentified slide-level
source dataset.

For the current v1 model, a routine H&E slide is defined using the exact
slide-name match:

``` text
SlideName == "H&E"
```

This intentionally excludes other H&E-related categories such as:

-   H&E recuts,
-   H&E levels,
-   frozen-section H&E,
-   molecular H&E, and
-   other separately named H&E workflows.

Those categories may enter later asynchronous workload streams.

The current weekday routine H&E dataset contains approximately:

``` text
131 weekdays
9,136 H&E cases
44,269 H&E slides
```

Observed slides per routine H&E case:

``` text
Mean:        4.85
Median:      3
95th pct:   14
Maximum:   141
```

The empirical distribution is strongly right-skewed and contains
workflow-related structure that is not well represented by a simple
Poisson distribution.

------------------------------------------------------------------------

## 3. Case Availability Timing

### 3.1 Availability proxy

For each case, the **latest routine-H&E TaskDateTime** is used as the
case-level availability proxy.

This is a modeling proxy. It should not be interpreted as a directly
observed courier pickup time or scanner-room arrival time.

### 3.2 Hourly workload

Cases are aggregated by weekday and hour.

The hourly case process is overdispersed relative to a Poisson process.
Therefore, active hourly case counts are modeled using a **negative
binomial distribution** when observed variance exceeds the mean.

For an hourly empirical mean `mu` and variance `v`:

``` text
r = mu^2 / (v - mu)
p = mu / v
```

If an hourly bin does not satisfy the overdispersion condition, a
Poisson fallback may be used.

### 3.3 Within-hour timing

After the number of cases for an hour is sampled, individual case
availability times are randomized within the hour.

Conceptually:

``` matlab
case_time = hour_start + rand(...)
```

The model does not evenly space cases within an hour.

This preserves the empirical hourly workload profile while avoiding
artificial deterministic spacing.

------------------------------------------------------------------------

## 4. Slides per Case

Routine H&E slides per case are sampled from an **empirical discrete
distribution** rather than a single fitted parametric distribution.

This choice preserves important characteristics of the observed
workload, including:

-   the strong right tail,
-   protocol-related spikes in case size, and
-   differences in case-size distributions by time of day.

The implementation currently uses broad time bands:

``` text
Early:       04:00-07:59
Morning:     08:00-11:59
Afternoon:   12:00-15:59
Late:        16:00-19:59
```

A global empirical distribution is available as a fallback outside the
modeled bands.

Observed band-level case-size characteristics used during development
were approximately:

  Time band     Cases   Mean slides/case   Median   P95
  ----------- ------- ------------------ -------- -----
  Early         5,078               4.16        3    13
  Morning       2,110               6.70        5    23
  Afternoon     1,263               4.47        4     9
  Late            683               4.92        4     9

Sampling from these empirical distributions still produces a **synthetic
simulation**. It is not a replay of individual patient cases.

------------------------------------------------------------------------

## 5. Rack Formation

### 5.1 Rack capacity

Routine H&E workload is packed into Sakura racks with a modeled capacity
of:

``` text
20 slides per rack
```

### 5.2 Packing policy

The current model uses **sequential capacity fill**.

Requirements:

1.  Cases are processed in modeled availability order.
2.  Slides are placed into the current rack until its 20-slide capacity
    is reached.
3.  Multiple cases may share one rack.
4.  A large case may span multiple racks.
5.  A full rack closes immediately when it reaches 20 slides.
6.  Rack composition is fixed once the rack is formed.
7.  Unused rack capacity does not carry across modeled days.

This represents an **assumed efficient upstream rack-loading policy**.

It should **not** be described as a measured rack-utilization rate or as
confirmed current institutional practice.

### 5.3 End-of-day partial racks

At the end of each modeled day, any nonempty partial rack is closed and
emitted.

This is explicitly a:

> **modeling boundary assumption**

It is not an observed operational rule.

No arbitrary rack dwell timer is currently used.

### 5.4 Rack readiness

`RackReadyTime` represents the time at which the modeled rack has been
formed and is available in Histology.

It does **not** represent:

-   courier pickup,
-   arrival in the scanning room,
-   scanner loading, or
-   scan start.

Those processes belong downstream.

------------------------------------------------------------------------

## 6. Relationship to Physical Workflow

The model assumes routine H&E slides are associated with Sakura racks
upstream of scanning. Racks may contain multiple cases, and a
sufficiently large case may occupy more than one rack.

For the P480 workflow, Sakura racks can proceed downstream as rack-level
workload.

For other scanner types, such as workflows requiring a different
carrier, downstream reracking may be required. That activity should be
modeled as part of **scanner-room loading**, not as part of
HistoArrival.

The generator therefore stops at the point where a completed rack is
available for downstream transport.

------------------------------------------------------------------------

## 7. Workload Scope

### Included in HistoArrival v1

``` text
Newly produced routine H&E slides
```

### Excluded from HistoArrival v1

The following should not be silently mixed into the initial routine H&E
case stream:

``` text
H&E levels
H&E recuts
IHC
special stains
rescans
pulled/archive cases
cytology
hematopathology slide workflows
electron microscopy
frozen/intraoperative workflows
```

Levels, recuts, IHC, special stains, and rescans are expected to be
modeled later as **asynchronous slide workload**, because they commonly
arise piecemeal after initial case production.

Pulled/archive cases may eventually be represented as case-associated
batches, but the current dataset does not provide a reliable basis for
quantifying that stream.

------------------------------------------------------------------------

## 8. SimEvents Implementation

### 8.1 Entity generation timing

The Entity Generator uses a MATLAB-action intergeneration-time vector:

``` text
igt_hr
```

The generator does not emit an entity at simulation start.

The current implementation uses a persistent index to traverse the
intergeneration-time vector.

### 8.2 Entity payload

The Generate action uses a separate persistent rack index to populate
rack attributes.

Conceptually:

``` matlab
persistent rack_idx

if isempty(rack_idx)
    rack_idx = 1;
end

entity.SlideCount = rack_slide_count(rack_idx);

rack_idx = rack_idx + 1;
```

When additional rack attributes are added, they must use the **same rack
index** so all metadata remain synchronized:

``` matlab
entity.RackID     = rack_id(rack_idx);
entity.SlideCount = rack_slide_count(rack_idx);
entity.NumCases   = rack_num_cases(rack_idx);

rack_idx = rack_idx + 1;
```

Separate counters should not be created for individual attributes.

### 8.3 Model workspace

The current generated vectors are explicitly assigned to the
`Slide_Model` model workspace.

This is important because stale model-workspace values can take
precedence over base-workspace variables and previously caused incorrect
entity counts.

------------------------------------------------------------------------

## 9. End-to-End Attribute Validation

A temporary validation path was constructed to prove that `SlideCount`
is not only calculated in MATLAB but is actually attached to and
propagated with each SimEvents rack entity.

Architecture:

``` text
HistoArrival
     |
     | rack entity with SlideCount
     v
Entity Terminator
     |
     | Entry action
     v
recordSlideCount(entity.SlideCount)
     |
     v
Simulink Function
     |
     v
To Workspace
```

The Entity Terminator Entry action calls:

``` matlab
recordSlideCount(entity.SlideCount);
```

The Simulink Function passes the value to a `To Workspace` block
producing:

``` matlab
out.rackSlideCountLog
```

The resulting timeseries contained:

``` text
82 time points
82 SlideCount values
```

This proves the attribute survives the SimEvents path and can be read by
a downstream component.

------------------------------------------------------------------------

## 10. Seed-42 Validation Case

For the frozen five-day, 1.00x workload validation run:

``` text
Simulation days:        5
Seed:                  42
Synthetic H&E cases:  332
Synthetic H&E slides: 1592
Rack capacity:         20
Rack entities:         82
Full racks:            77
Partial racks:          5
Mean rack fill:       97.1%
Median rack fill:    100.0%
Minimum rack size:      3
Maximum rack size:     20
```

Daily workload:

  Day             Cases      Slides   Expected racks
  ----------- --------- ----------- ----------------
  1                  84         376               19
  2                  68         386               20
  3                  63         255               13
  4                  67         303               16
  5                  50         272               14
  **Total**     **332**   **1,592**           **82**

The theoretical rack count is:

``` text
ceil(376/20)
+ ceil(386/20)
+ ceil(255/20)
+ ceil(303/20)
+ ceil(272/20)
= 19 + 20 + 13 + 16 + 14
= 82 racks
```

The five end-of-day partial racks were:

``` text
Day 1: 16 slides
Day 2:  6 slides
Day 3: 15 slides
Day 4:  3 slides
Day 5: 12 slides
```

These occurred at rack positions:

``` text
19, 39, 52, 68, 82
```

Thus the SimEvents output reconciles not only in aggregate but also with
the expected day-by-day packing boundaries.

Validation commands:

``` matlab
x = out.rackSlideCountLog.Data;

fprintf('Rack entities: %d\n', numel(x));
fprintf('Total slides: %d\n', sum(x));
fprintf('Full racks: %d\n', sum(x == 20));
fprintf('Partial racks: %d\n', sum(x < 20));
fprintf('Min rack size: %d\n', min(x));
fprintf('Max rack size: %d\n', max(x));
```

Expected frozen validation result:

``` text
Rack entities: 82
Total slides: 1592
Full racks: 77
Partial racks: 5
Min rack size: 3
Max rack size: 20
```

------------------------------------------------------------------------

## 11. Long-Run Generator Validation

A separate 5,000-day validation of the hourly case-count generator
showed approximately:

``` text
Mean absolute percent error of active-hour means: 1.63%
Mean absolute percent error of active-hour variances: 4.55%
Maximum absolute mean error: 0.130 cases/hour
Maximum absolute variance error: 3.479
```

These results support the stochastic hourly generation logic
independently of the five-day end-to-end rack test.

------------------------------------------------------------------------

## 12. Acceptance Requirements

HistoArrival should be considered valid only when all of the following
are satisfied:

-   [x] Hourly synthetic case generation reproduces the intended
    empirical hourly mean/variance behavior.
-   [x] Within-hour case times are stochastic rather than
    deterministically evenly spaced.
-   [x] Slides per case are sampled from empirical distributions.
-   [x] Rack capacity is limited to 20 slides.
-   [x] Multiple cases may occupy a rack.
-   [x] Cases may span rack boundaries.
-   [x] No slides are lost during rack packing.
-   [x] Rack count equals the theoretical day-specific capacity
    calculation.
-   [x] Full and partial rack counts reconcile with daily slide totals.
-   [x] Each SimEvents entity represents one rack.
-   [x] `SlideCount` is attached to the entity.
-   [x] A downstream SimEvents component can read `entity.SlideCount`.
-   [x] End-to-end rack entities sum to the same total slide workload
    produced by the generator.
-   [x] The model distinguishes rack readiness from later transport and
    scanner-room arrival.
-   [x] End-of-day partial closure is documented as a modeling
    assumption rather than an observed operational fact.

With these conditions met, the **HistoArrival component is frozen for
the current model version** unless source data, workflow knowledge, or
model scope changes.

------------------------------------------------------------------------

## 13. Downstream Interface

The output of HistoArrival should be interpreted as:

> **A completed Sakura rack, containing `SlideCount` routine H&E slides,
> becoming available in Histology for downstream transport.**

The next modeled processes are expected to be:

``` text
HistoArrival
    |
    v
HistoStaging
    |
    v
Courier / periodic pickup
    |
    v
RacksToScan (scanner-room queue)
    |
    v
ScannerLoading
    |
    v
Scanner bank
```

The following must remain separate downstream concepts:

1.  rack ready in Histology,
2.  waiting for courier pickup,
3.  transport to the scanning room,
4.  waiting in the scanner-room queue,
5.  technician loading activity, and
6.  scanner processing.

This separation allows courier frequency, staffing, scanner count, and
scanner performance to be varied independently during sensitivity
analysis.

------------------------------------------------------------------------

## 14. Reproducibility Notes for Repository Use

For a public repository, the implementation should ideally include:

``` text
README.md
model/Slide_Model.slx
scripts/estimate_he_case_parameters.m
scripts/config_histo_arrival_rack_final.m
docs/HistoArrival_Requirements.md
```

The repository should **not require distribution of the underlying
institutional slide-level dataset**.

Derived/deidentified parameter files may be distributed only if
permitted by the applicable institutional/data-governance requirements.

The README should clearly distinguish:

-   source-data-derived parameters,
-   synthetic simulation output,
-   workflow assumptions, and
-   institution-specific observations versus generalizable model
    structure.

------------------------------------------------------------------------

## 15. Version Status

**Component:** HistoArrival / routine H&E rack generator\
**Status:** Validated and frozen for current model iteration\
**Validation configuration:** 5-day simulation, seed 42, 1.00x workload\
**Validated output:** 332 cases -\> 1,592 slides -\> 82 rack entities\
**Next component:** HistoStaging and courier/pickup logic
