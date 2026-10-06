%% run_slide_model_daily_scenarios.m
% Daily production scenario sweep for Slide_Model v1.1
%
% Primary question:
%   For a representative daily H&E workload and resource configuration,
%   what percentage of the day's slides are ReviewReady by a chosen cutoff?
%
% Primary experiment:
%   target daily workload x active scanners x technician start time
%
% Secondary sensitivity:
%   target daily workload x active scanners x technician check behavior
%
% IMPORTANT DESIGN CHOICES
% ------------------------
% - Each replication is ONE independent modeled day. There is no carryover
%   backlog from one simulated day to another.
% - The empirical hourly H&E case-availability shape is preserved. Daily
%   workload is scaled by multiplying the fitted hourly case-count means while
%   preserving the fitted variance-to-mean ratio.
% - The denominator for "% ReviewReady by cutoff" is ALL slides generated in
%   that modeled day. Late histology availability therefore remains part of
%   the whole-workflow service-level result.
% - Scanner count is controlled by ScannerGate1..ScannerGate6. The switch uses
%   "First port that is not blocked".
% - This script uses the To Workspace instrumentation ALREADY SAVED in the
%   current Slide_Model / ScannerBank files. It does not add logger blocks.
% - Scanner scan time is stochastic in the scenario study. The default
%   lognormal fit uses the provisional P480 40x summary discussed for this
%   project: median 58 s, mean 110 s. Replace with an empirical distribution
%   when the raw scan-time data are available.
% - Post-scan latency remains the v1 independent, infinite-capacity lognormal
%   abstraction (default median 20 min, P95 120 min).
%
% CURRENT HISTO PACKING NOTE
% --------------------------
% The uploaded config_histo_arrival_rack_final.m uses sequential capacity fill:
% a case MAY cross a rack boundary and courier timing does NOT change rack
% composition. To avoid silently changing the current workload generator, this
% script defaults to "sequential_fill".
%
% A "keep_cases_together" option is also implemented below for the alternative
% policy discussed during model development (do not split a <=20-slide case
% across racks). If that becomes the intended v1.1 behavior, switch the option
% and validate the resulting rack statistics before using poster results.
%
% MODEL TIME UNIT: hours.
%
% Expected files beside this script:
%   Slide_Model.slx
%   ScannerBank.slx
%   GenericScanner.slx
%   he_case_parameters.mat
%
% Recommended workflow:
%   1. Run with run_mode = "smoke".
%   2. Inspect the CSV/MAT outputs and figures.
%   3. Run with run_mode = "pilot".
%   4. Use run_mode = "production" only after the pilot behaves as expected.

clearvars;
clc;

%% ========================================================================
% USER CONFIGURATION
% ==========================================================================

run_mode = "smoke";       % "smoke" | "pilot" | "production"

run_primary_experiment   = true;
run_check_sensitivity    = true;

model_file       = 'Slide_Model.slx';
model_name       = 'Slide_Model';

bank_ref_file    = 'ScannerBank.slx';
bank_ref_name    = 'ScannerBank';
bank_block       = [model_name '/ScannerBank'];

scanner_ref_file = 'GenericScanner.slx';
scanner_ref_name = 'GenericScanner';

parameter_file   = 'he_case_parameters.mat';

output_dir = 'daily_scenario_outputs';

% Representative TARGET MEAN daily H&E slide volumes.
% Realized daily slide count is stochastic.
target_daily_slides_all = [500 1000 2000];
volume_labels_all       = ["Low" "Medium" "High"];

% Primary resource sweep.
scanner_levels_all  = 1:6;

% First courier pickup is currently 08:00, so technician starts before ~08:00
% have little/no effect unless the courier schedule is also changed.
tech_start_levels_all = [8 9 10 11 12];
tech_end_hr            = 19.5;

% Baseline technician check behavior from the validated harness.
reference_check_min_min = 10;
reference_check_max_min = 30;

% Check-behavior sensitivity at a fixed reference technician start.
check_sensitivity_tech_start_hr = 8.0;
check_policy_name = ["Frequent"; "Reference"; "Intermittent"];
check_policy_min  = [5; 10; 30];
check_policy_max  = [15; 30; 60];

% Courier assumptions held fixed in the primary experiment.
courier_pickup_daily_hr = [8 10 12 14 16 18];
courier_transit_min     = 10;
courier_transit_hr      = courier_transit_min / 60;
courier_gate_open_hr    = 1e-6;

% Daily service-level analysis.
primary_cutoff_hr = 17.5;            % 17:30
cutoff_grid_hr    = (12:0.5:20)';    % full cutoff curve for poster
simulation_stop_hr = 24;             % one independent modeled day

% Histology / rack generation.
rack_capacity       = 20;
rack_packing_policy = "sequential_fill"; % current uploaded generator behavior

% P480-style scanner assumptions held fixed except active scanner count.
scanner_physical_rack_positions = 24;
Scanner_RackQueueSize = scanner_physical_rack_positions - 1; % 23 waiting
Scanner_RerackTime     = 3 / 60;
Scanner_RackLoadTime   = 5 / 60;
Scanner_SlideQueueSize = Inf;

% -------------------------------------------------------------------------
% Scanner scan-time distribution.
% -------------------------------------------------------------------------
ScanTime_Dist       = "lognormal_mean_median"; % or "fixed"
ScanTime_Median_sec = 58;
ScanTime_Mean_sec   = 110;
ScanTime_Fixed_sec  = 110;

% -------------------------------------------------------------------------
% Post-scan processing distribution.
% -------------------------------------------------------------------------
PostScan_Dist       = "lognormal"; % or "fixed"
PostScan_Median_min = 20;
PostScan_P95_min    = 120;
PostScan_Fixed_min  = 20;

% Reproducibility seeds.
base_workload_seed = 42000;
base_tech_seed     = 52000;
base_sim_seed      = 62000;

% Fail immediately if a structural/instrumentation invariant is violated.
fail_fast = true;

%% ========================================================================
% RUN MODE
% ==========================================================================

switch lower(run_mode)
    case "smoke"
        n_replications     = 1;
        target_daily_slides = target_daily_slides_all;
        volume_labels       = volume_labels_all;
        scanner_levels      = [1 3 6];
        tech_start_levels   = [8 10 12];

    case "pilot"
        n_replications      = 3;
        target_daily_slides = target_daily_slides_all;
        volume_labels       = volume_labels_all;
        scanner_levels      = scanner_levels_all;
        tech_start_levels   = tech_start_levels_all;

    case "production"
        n_replications      = 30;
        target_daily_slides = target_daily_slides_all;
        volume_labels       = volume_labels_all;
        scanner_levels      = scanner_levels_all;
        tech_start_levels   = tech_start_levels_all;

    otherwise
        error('Unsupported run_mode: %s', run_mode);
end

assert(numel(target_daily_slides) == numel(volume_labels), ...
    'target_daily_slides and volume_labels must have the same length.');

if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

fprintf('\n============================================================\n');
fprintf(' DAILY SLIDE_MODEL SCENARIO EXPERIMENT\n');
fprintf('============================================================\n');
fprintf('Run mode:                 %s\n', run_mode);
fprintf('Replications/scenario:    %d\n', n_replications);
fprintf('Target mean volumes:      %s slides/day\n', ...
    strjoin(string(target_daily_slides), ', '));
fprintf('Scanner levels:           %s\n', ...
    strjoin(string(scanner_levels), ', '));
fprintf('Tech start levels:        %s hr\n', ...
    strjoin(string(tech_start_levels), ', '));
fprintf('Primary cutoff:           %.1f hr (17:30 = 17.5)\n', ...
    primary_cutoff_hr);
fprintf('Histo packing policy:     %s\n', rack_packing_policy);
fprintf('Output directory:         %s\n', output_dir);
fprintf('============================================================\n');

%% ========================================================================
% FILE / MODEL LOAD
% ==========================================================================

assert(isfile(model_file), ...
    'Cannot find %s. Put this script beside the canonical model files.', model_file);
assert(isfile(bank_ref_file), ...
    'Cannot find %s.', bank_ref_file);
assert(isfile(scanner_ref_file), ...
    'Cannot find %s.', scanner_ref_file);
assert(isfile(parameter_file), ...
    'Cannot find %s.', parameter_file);

local_close_if_loaded(model_name);
local_close_if_loaded(bank_ref_name);
local_close_if_loaded(scanner_ref_name);

load_system(model_file);
load_system(bank_ref_file);
load_system(scanner_ref_file);

set_param(model_name, 'FastRestart', 'off');

mws = get_param(model_name, 'ModelWorkspace');

P = load(parameter_file);

%% ========================================================================
% STATIC ARCHITECTURE / INSTRUMENTATION AUDIT
% ==========================================================================

n_physical_scanners = 6;

required_top_blocks = { ...
    'HistoArrival'
    'HistoRackStore'
    'CourierPickupGate'
    'CourierGateControl'
    'CourierTransit'
    'LoadingQueue'
    'LoadingGate'
    'LoadingGateLogic'
    'ScannerBank'
    'PostScanProcessing'
    'ReviewReady'};

for i = 1:numel(required_top_blocks)
    p = [model_name '/' required_top_blocks{i}];
    assert(getSimulinkBlockHandle(p) ~= -1, ...
        'Required top-level block is missing: %s', p);
end

assert(strcmp(get_param(bank_block, 'ReferencedSubsystem'), bank_ref_name), ...
    'Top-level ScannerBank reference is not "%s".', bank_ref_name);

out_switch = [bank_ref_name '/ScannerSelectSwitch'];
assert(getSimulinkBlockHandle(out_switch) ~= -1, ...
    'ScannerSelectSwitch is missing.');
assert(str2double(get_param(out_switch, 'NumberOutputPorts')) == ...
    n_physical_scanners, ...
    'ScannerSelectSwitch must have six outputs.');

% Gates and scanner references.
gate_paths = cell(n_physical_scanners,1);

for i = 1:n_physical_scanners
    gate_paths{i} = sprintf('%s/ScannerGate%d', bank_ref_name, i);
    scanner_path  = sprintf('%s/Scanner_%d', bank_ref_name, i);

    assert(getSimulinkBlockHandle(gate_paths{i}) ~= -1, ...
        'Missing %s.', gate_paths{i});
    assert(strcmp(get_param(gate_paths{i}, 'BlockType'), 'EntityGate'), ...
        '%s is not an Entity Gate.', gate_paths{i});

    assert(getSimulinkBlockHandle(scanner_path) ~= -1, ...
        'Missing %s.', scanner_path);
    assert(strcmp(get_param(scanner_path, 'ReferencedSubsystem'), ...
                  scanner_ref_name), ...
        '%s does not reference %s.', scanner_path, scanner_ref_name);
end

% Keep the v1.1 routing policy explicit.
set_param(out_switch, ...
    'SwitchingCriterion', 'First port that is not blocked');

% Verify EXISTING top-level logger variables.
required_top_logs = { ...
    'loading_queue_n'
    'free_scan_slots'
    'review_ready_count'};

for i = 1:numel(required_top_logs)
    local_assert_existing_workspace_logger(model_name, required_top_logs{i});
end

% Verify EXISTING ScannerBank logger variables.
required_bank_logs = { ...
    'total_scanner_queue_n'
    'free_scan_slots_bank'};

for i = 1:numel(required_bank_logs)
    local_assert_existing_workspace_logger(bank_ref_name, required_bank_logs{i});
end

for i = 1:n_physical_scanners
    local_assert_existing_workspace_logger( ...
        bank_ref_name, sprintf('S%d_QueueN', i));
    local_assert_existing_workspace_logger( ...
        bank_ref_name, sprintf('S%d_SlideQueueN', i));
    local_assert_existing_workspace_logger( ...
        bank_ref_name, sprintf('S%d_Slides', i));
    local_assert_existing_workspace_logger( ...
        bank_ref_name, sprintf('S%d_Racks', i));
end

fprintf('Architecture audit:       PASS\n');
fprintf('Instrumentation audit:    PASS\n');

%% ========================================================================
% PARAMETERIZE STOCHASTIC SCAN TIME
% ==========================================================================

slide_scan_block = [scanner_ref_name '/SlideScanning'];

switch lower(ScanTime_Dist)

    case "lognormal_mean_median"
        assert(ScanTime_Mean_sec >= ScanTime_Median_sec, ...
            'Lognormal mean must be >= median.');

        ScanTime_Mu = log(ScanTime_Median_sec / 3600);
        ScanTime_Sigma = sqrt( ...
            2 * log(ScanTime_Mean_sec / ScanTime_Median_sec));

        scan_service_action = ...
            'dt = exp(ScanTime_Mu + ScanTime_Sigma * randn(1));';

        mws.assignin('ScanTime_Mu', ScanTime_Mu);
        mws.assignin('ScanTime_Sigma', ScanTime_Sigma);

        set_param(slide_scan_block, ...
            'ServiceTimeSource', 'MATLAB action', ...
            'ServiceTimeAction', scan_service_action);

        fprintf('Scan-time model:          lognormal\n');
        fprintf('  median:                 %.1f sec\n', ScanTime_Median_sec);
        fprintf('  mean:                   %.1f sec\n', ScanTime_Mean_sec);
        fprintf('  mu (hours):             %.6f\n', ScanTime_Mu);
        fprintf('  sigma:                  %.6f\n', ScanTime_Sigma);

    case "fixed"
        Scanner_SlideScanTime = ScanTime_Fixed_sec / 3600;
        mws.assignin('Scanner_SlideScanTime', Scanner_SlideScanTime);

        set_param(slide_scan_block, ...
            'ServiceTimeSource', 'Dialog', ...
            'ServiceTimeValue', 'Scanner_SlideScanTime');

        fprintf('Scan-time model:          fixed %.1f sec/slide\n', ...
            ScanTime_Fixed_sec);

    otherwise
        error('Unsupported ScanTime_Dist: %s', ScanTime_Dist);
end

%% ========================================================================
% PARAMETERIZE POST-SCAN LATENCY
% ==========================================================================

PostScan_Median_hr = PostScan_Median_min / 60;
PostScan_P95_hr    = PostScan_P95_min / 60;
PostScan_Fixed_hr  = PostScan_Fixed_min / 60;

switch lower(PostScan_Dist)

    case "lognormal"
        PostScan_Mu = log(PostScan_Median_hr);
        PostScan_Sigma = ...
            (log(PostScan_P95_hr) - PostScan_Mu) / 1.645;

        postscan_service_action = ...
            'dt = exp(PostScan_Mu + PostScan_Sigma * randn(1));';

        mws.assignin('PostScan_Mu', PostScan_Mu);
        mws.assignin('PostScan_Sigma', PostScan_Sigma);

    case "fixed"
        postscan_service_action = 'dt = PostScan_Fixed_hr;';
        mws.assignin('PostScan_Fixed_hr', PostScan_Fixed_hr);

    otherwise
        error('Unsupported PostScan_Dist: %s', PostScan_Dist);
end

set_param([model_name '/PostScanProcessing'], ...
    'Capacity', 'inf', ...
    'ServiceTimeSource', 'MATLAB action', ...
    'ServiceTimeAction', postscan_service_action);

fprintf('Post-scan model:          %s\n', PostScan_Dist);
fprintf('  median assumption:      %.1f min\n', PostScan_Median_min);
fprintf('  P95 assumption:         %.1f min\n', PostScan_P95_min);

%% ========================================================================
% CONSTANT MODEL PARAMETERS
% ==========================================================================

mws.assignin('courier_transit_hr', courier_transit_hr);

mws.assignin('Scanner_RackQueueSize', Scanner_RackQueueSize);
mws.assignin('Scanner_RerackTime', Scanner_RerackTime);
mws.assignin('Scanner_RackLoadTime', Scanner_RackLoadTime);
mws.assignin('Scanner_SlideQueueSize', Scanner_SlideQueueSize);

% Keep legacy scalar defined even though the scenario scan-time action is
% stochastic. This avoids stale/missing-variable surprises in diagnostic code.
mws.assignin('Scanner_SlideScanTime', ScanTime_Mean_sec / 3600);

mws.assignin('PostScan_Median_hr', PostScan_Median_hr);
mws.assignin('PostScan_P95_hr', PostScan_P95_hr);
mws.assignin('PostScan_Fixed_hr', PostScan_Fixed_hr);

set_param([model_name '/CourierTransit'], ...
    'Capacity', 'inf', ...
    'ServiceTimeValue', 'courier_transit_hr');

set_param([model_name '/LoadingQueue'], 'Capacity', 'inf');

%% ========================================================================
% COURIER SCHEDULE -- ONE MODELED DAY
% ==========================================================================

courier_event_times_hr = reshape( ...
    [courier_pickup_daily_hr; ...
     courier_pickup_daily_hr + courier_gate_open_hr], ...
    1, []);

courier_igt_hr = diff([0 courier_event_times_hr]);
courier_igt_hr(courier_igt_hr <= 0) = eps;

mws.assignin('courier_igt_hr', courier_igt_hr);

%% ========================================================================
% WORKLOAD CALIBRATION
% ==========================================================================

baseline_expected_slides = local_expected_daily_slides(P);

workload_multiplier = target_daily_slides ./ baseline_expected_slides;

fprintf('\nExpected baseline workload from fitted H&E model: %.1f slides/day\n', ...
    baseline_expected_slides);

for v = 1:numel(target_daily_slides)
    fprintf('  %-6s target %4d/day -> workload multiplier %.3fx\n', ...
        volume_labels(v), target_daily_slides(v), workload_multiplier(v));
end

% Expected hourly slide profile for the poster input figure.
ProfileRows = struct([]);

for v = 1:numel(target_daily_slides)
    expected_hourly = local_expected_hourly_slides(P) .* workload_multiplier(v);

    for h = 0:23
        ProfileRows(end+1).VolumeLabel = volume_labels(v); %#ok<SAGROW>
        ProfileRows(end).TargetSlidesPerDay = target_daily_slides(v);
        ProfileRows(end).Hour = h;
        ProfileRows(end).ExpectedSlidesPerHour = expected_hourly(h+1);
    end
end

ExpectedHourlyProfile = struct2table(ProfileRows);
writetable(ExpectedHourlyProfile, ...
    fullfile(output_dir, 'expected_hourly_workload_profiles.csv'));

%% ========================================================================
% PRE-GENERATE WORKLOAD REALIZATIONS
% ==========================================================================
%
% The same daily workload realization is reused across all scanner-count and
% technician scenarios for a given volume/replication. This gives an exact
% common workload when comparing resource configurations.

nV = numel(target_daily_slides);
workloads = cell(nV, n_replications);
WorkloadRows = struct([]);

for v = 1:nV
    for rep = 1:n_replications

        workload_seed = base_workload_seed + 1000*v + rep;

        W = local_generate_daily_workload( ...
            P, workload_multiplier(v), workload_seed, ...
            rack_capacity, rack_packing_policy);

        workloads{v,rep} = W;

        [mean_batch, max_batch, moved_by_last_pickup] = ...
            local_courier_batch_stats( ...
                W.rack_ready_time_hr, courier_pickup_daily_hr);

        WorkloadRows(end+1).VolumeLabel = volume_labels(v); %#ok<SAGROW>
        WorkloadRows(end).TargetSlidesPerDay = target_daily_slides(v);
        WorkloadRows(end).WorkloadMultiplier = workload_multiplier(v);
        WorkloadRows(end).Replication = rep;
        WorkloadRows(end).WorkloadSeed = workload_seed;
        WorkloadRows(end).Cases = numel(W.case_sizes);
        WorkloadRows(end).Slides = W.input_slides;
        WorkloadRows(end).Racks = W.input_racks;
        WorkloadRows(end).MeanRackFillPct = 100*mean(W.rack_fill_fraction);
        WorkloadRows(end).MedianRackFillPct = 100*median(W.rack_fill_fraction);
        WorkloadRows(end).MeanCourierBatchRacks = mean_batch;
        WorkloadRows(end).MaxCourierBatchRacks = max_batch;
        WorkloadRows(end).RacksMovedByLastPickup = moved_by_last_pickup;
    end
end

WorkloadRealizations = struct2table(WorkloadRows);
writetable(WorkloadRealizations, ...
    fullfile(output_dir, 'workload_realizations.csv'));

%% ========================================================================
% RUN SCENARIOS
% ==========================================================================

RunRows    = struct([]);
CutoffRows = struct([]);

primary_runs = 0;
if run_primary_experiment
    primary_runs = nV * n_replications * ...
        numel(tech_start_levels) * numel(scanner_levels);
end

sensitivity_runs = 0;
if run_check_sensitivity
    sensitivity_runs = nV * n_replications * ...
        numel(check_policy_name) * numel(scanner_levels);
end

total_runs = primary_runs + sensitivity_runs;
run_counter = 0;

fprintf('\nPlanned simulations:       %d\n', total_runs);
fprintf('Primary runs:              %d\n', primary_runs);
fprintf('Check-sensitivity runs:    %d\n\n', sensitivity_runs);

% -------------------------------------------------------------------------
% PRIMARY: volume x scanner count x technician start
% -------------------------------------------------------------------------

if run_primary_experiment

    for v = 1:nV
        for rep = 1:n_replications

            W = workloads{v,rep};

            for ts = 1:numel(tech_start_levels)

                tech_start_hr = tech_start_levels(ts);

                tech_seed = base_tech_seed + ...
                    100000*v + 1000*rep + round(100*tech_start_hr);

                [on_duty_ts, check_toggle_ts, n_checks] = ...
                    local_build_technician_schedule( ...
                        tech_start_hr, tech_end_hr, ...
                        reference_check_min_min, ...
                        reference_check_max_min, ...
                        tech_seed, simulation_stop_hr);

                for ns = 1:numel(scanner_levels)

                    n_active_scanners = scanner_levels(ns);
                    run_counter = run_counter + 1;

                    sim_seed = base_sim_seed + ...
                        1000000*v + 10000*rep + ...
                        100*n_active_scanners + round(tech_start_hr);

                    fprintf('[%4d/%4d] PRIMARY  %-6s target=%4d  rep=%2d  ', ...
                        run_counter, total_runs, volume_labels(v), ...
                        target_daily_slides(v), rep);
                    fprintf('scanners=%d  tech=%.1f  checks=%d\n', ...
                        n_active_scanners, tech_start_hr, n_checks);

                    try
                        [R, C] = local_run_one_scenario( ...
                            model_name, bank_ref_name, mws, gate_paths, ...
                            n_physical_scanners, n_active_scanners, ...
                            Scanner_RackQueueSize, ...
                            W, on_duty_ts, check_toggle_ts, ...
                            primary_cutoff_hr, cutoff_grid_hr, ...
                            simulation_stop_hr, sim_seed, ...
                            "Primary", volume_labels(v), ...
                            target_daily_slides(v), workload_multiplier(v), ...
                            rep, tech_start_hr, tech_end_hr, ...
                            "Reference", reference_check_min_min, ...
                            reference_check_max_min);

                        RunRows = local_append_structs(RunRows, R);
                        CutoffRows = local_append_structs(CutoffRows, C);

                    catch ME
                        local_write_checkpoint( ...
                            RunRows, CutoffRows, WorkloadRealizations, ...
                            output_dir);

                        fprintf(2, '\nSCENARIO FAILED\n%s\n\n', ME.message);

                        if fail_fast
                            rethrow(ME);
                        end
                    end
                end
            end
        end
    end
end

% -------------------------------------------------------------------------
% SENSITIVITY: volume x scanner count x technician check behavior
% -------------------------------------------------------------------------

if run_check_sensitivity

    for v = 1:nV
        for rep = 1:n_replications

            W = workloads{v,rep};

            for cp = 1:numel(check_policy_name)

                tech_start_hr = check_sensitivity_tech_start_hr;

                tech_seed = base_tech_seed + ...
                    500000 + 100000*v + 1000*rep + cp;

                [on_duty_ts, check_toggle_ts, n_checks] = ...
                    local_build_technician_schedule( ...
                        tech_start_hr, tech_end_hr, ...
                        check_policy_min(cp), ...
                        check_policy_max(cp), ...
                        tech_seed, simulation_stop_hr);

                for ns = 1:numel(scanner_levels)

                    n_active_scanners = scanner_levels(ns);
                    run_counter = run_counter + 1;

                    sim_seed = base_sim_seed + ...
                        5000000 + 1000000*v + 10000*rep + ...
                        100*n_active_scanners + cp;

                    fprintf('[%4d/%4d] CHECK    %-6s target=%4d  rep=%2d  ', ...
                        run_counter, total_runs, volume_labels(v), ...
                        target_daily_slides(v), rep);
                    fprintf('scanners=%d  policy=%s  checks=%d\n', ...
                        n_active_scanners, check_policy_name(cp), n_checks);

                    try
                        [R, C] = local_run_one_scenario( ...
                            model_name, bank_ref_name, mws, gate_paths, ...
                            n_physical_scanners, n_active_scanners, ...
                            Scanner_RackQueueSize, ...
                            W, on_duty_ts, check_toggle_ts, ...
                            primary_cutoff_hr, cutoff_grid_hr, ...
                            simulation_stop_hr, sim_seed, ...
                            "CheckSensitivity", volume_labels(v), ...
                            target_daily_slides(v), workload_multiplier(v), ...
                            rep, tech_start_hr, tech_end_hr, ...
                            check_policy_name(cp), check_policy_min(cp), ...
                            check_policy_max(cp));

                        RunRows = local_append_structs(RunRows, R);
                        CutoffRows = local_append_structs(CutoffRows, C);

                    catch ME
                        local_write_checkpoint( ...
                            RunRows, CutoffRows, WorkloadRealizations, ...
                            output_dir);

                        fprintf(2, '\nSCENARIO FAILED\n%s\n\n', ME.message);

                        if fail_fast
                            rethrow(ME);
                        end
                    end
                end
            end
        end
    end
end

%% ========================================================================
% SAVE RAW RESULTS
% ==========================================================================

if isempty(RunRows)
    error('No scenario runs completed.');
end

RunResults = struct2table(RunRows);

if isempty(CutoffRows)
    CutoffResults = table();
else
    CutoffResults = struct2table(CutoffRows);
end

writetable(RunResults, ...
    fullfile(output_dir, 'daily_scenario_run_results.csv'));

if ~isempty(CutoffResults)
    writetable(CutoffResults, ...
        fullfile(output_dir, 'daily_cutoff_curves.csv'));
end

save(fullfile(output_dir, 'daily_scenario_results.mat'), ...
    'RunResults', 'CutoffResults', 'WorkloadRealizations', ...
    'ExpectedHourlyProfile', ...
    'target_daily_slides', 'volume_labels', ...
    'scanner_levels', 'tech_start_levels', ...
    'primary_cutoff_hr', 'cutoff_grid_hr', ...
    'ScanTime_Dist', 'ScanTime_Median_sec', 'ScanTime_Mean_sec', ...
    'PostScan_Dist', 'PostScan_Median_min', 'PostScan_P95_min', ...
    'rack_packing_policy');

%% ========================================================================
% SUMMARY TABLES
% ==========================================================================

ScenarioSummary = local_make_scenario_summary(RunResults);

writetable(ScenarioSummary, ...
    fullfile(output_dir, 'daily_scenario_summary.csv'));

fprintf('\n============================================================\n');
fprintf(' DAILY SCENARIO SWEEP COMPLETE\n');
fprintf('============================================================\n');
fprintf('Completed runs:            %d\n', height(RunResults));
fprintf('Run results:               daily_scenario_run_results.csv\n');
fprintf('Cutoff curves:             daily_cutoff_curves.csv\n');
fprintf('Scenario summary:          daily_scenario_summary.csv\n');
fprintf('Workload realizations:     workload_realizations.csv\n');
fprintf('Expected workload profile: expected_hourly_workload_profiles.csv\n');
fprintf('MAT file:                  daily_scenario_results.mat\n');
fprintf('============================================================\n');

%% ========================================================================
% POSTER FIGURES
% ==========================================================================

local_make_workload_profile_figure( ...
    ExpectedHourlyProfile, target_daily_slides, volume_labels, output_dir);

if run_primary_experiment
    local_make_primary_heatmap( ...
        RunResults, target_daily_slides, volume_labels, ...
        scanner_levels, tech_start_levels, ...
        primary_cutoff_hr, output_dir);

    % Medium-volume cutoff curve at the reference 08:00 technician start.
    if any(target_daily_slides == 1000) && any(tech_start_levels == 8)
        local_make_cutoff_curve_figure( ...
            CutoffResults, 1000, 8, scanner_levels, output_dir);
    end
end

if run_check_sensitivity
    local_make_check_sensitivity_figure( ...
        RunResults, target_daily_slides, volume_labels, ...
        scanner_levels, check_policy_name, ...
        primary_cutoff_hr, output_dir);
end

fprintf('\nPoster figures exported to %s\n', output_dir);

%% ========================================================================
% LOCAL FUNCTIONS
% ==========================================================================

function local_close_if_loaded(modelName)
    if bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
end


function loggerPath = local_assert_existing_workspace_logger(modelName, variableName)
% Verify exactly one existing To Workspace block exports variableName.
% Recursive search is intentional: ScannerBank loggers may be placed inside
% organizational WorkspaceVars subsystems.

    hits = find_system(modelName, ...
        'LookUnderMasks', 'all', ...
        'FollowLinks', 'on', ...
        'BlockType', 'ToWorkspace', ...
        'VariableName', variableName);

    assert(numel(hits) == 1, ...
        ['Expected exactly one saved To Workspace logger for variable "' ...
         variableName '" in ' modelName '; found %d.'], ...
        numel(hits));

    loggerPath = hits{1};
end


function baseline = local_expected_daily_slides(P)
    baseline = sum(local_expected_hourly_slides(P));
end


function expected_hourly_slides = local_expected_hourly_slides(P)
% Expected slides/hour implied by fitted hourly case counts and the
% hour-specific empirical case-size distributions.

    if isfield(P, 'hourly_table')
        mean_cases = double(P.hourly_table.MeanCases(:));
    elseif isfield(P, 'hourly_counts')
        mean_cases = mean(double(P.hourly_counts), 1).';
    else
        error('Parameter file lacks hourly_table and hourly_counts.');
    end

    assert(numel(mean_cases) == 24, ...
        'Hourly case profile must contain 24 hours.');

    global_values = double(P.size_values(:));
    global_probs  = double(P.global_probs(:));
    global_mean   = sum(global_values .* global_probs);

    expected_hourly_slides = zeros(24,1);

    for h = 0:23
        mean_case_size = global_mean;

        if isfield(P, 'case_size_bands')
            for b = 1:numel(P.case_size_bands)
                B = P.case_size_bands(b);
                if h >= B.start_hour && h <= B.end_hour
                    if isfield(B, 'mean')
                        mean_case_size = double(B.mean);
                    else
                        values = double(B.values(:));
                        if isfield(B, 'prob')
                            probs = double(B.prob(:));
                        else
                            cdf = double(B.cdf(:));
                            probs = diff([0; cdf]);
                        end
                        mean_case_size = sum(values .* probs);
                    end
                    break;
                end
            end
        end

        expected_hourly_slides(h+1) = mean_cases(h+1) * mean_case_size;
    end
end


function W = local_generate_daily_workload( ...
    P, workload_multiplier, rng_seed, rack_capacity, packing_policy)
% Generate ONE stochastic day of routine-H&E case availability while
% preserving the fitted hourly profile and variance-to-mean ratio.

    rng(rng_seed, 'twister');

    if isfield(P, 'hourly_table')
        mean_cases = double(P.hourly_table.MeanCases(:));
        var_cases  = double(P.hourly_table.VarianceCases(:));
    elseif isfield(P, 'hourly_counts')
        X = double(P.hourly_counts);
        mean_cases = mean(X,1).';
        var_cases  = var(X,0,1).';
    else
        error('Parameter file lacks hourly case-count information.');
    end

    case_times_hr = [];
    case_sizes    = [];
    case_hours    = [];

    for h = 0:23

        base_mu  = mean_cases(h+1);
        base_var = var_cases(h+1);

        if base_mu <= 0
            continue;
        end

        mu = workload_multiplier * base_mu;

        dispersion_ratio = base_var / base_mu;
        target_var = mu * dispersion_ratio;

        if target_var > mu
            r = mu^2 / (target_var - mu);
            p = mu / target_var;
            n_cases = nbinrnd(r,p);
        else
            n_cases = poissrnd(mu);
        end

        if n_cases == 0
            continue;
        end

        t = h + rand(n_cases,1);
        t = sort(t);

        for j = 1:n_cases
            n_slides = local_sample_he_case_size(h, P);

            case_times_hr(end+1,1) = t(j); %#ok<AGROW>
            case_sizes(end+1,1)    = n_slides; %#ok<AGROW>
            case_hours(end+1,1)    = h; %#ok<AGROW>
        end
    end

    [case_times_hr, order] = sort(case_times_hr);
    case_sizes = case_sizes(order);
    case_hours = case_hours(order);

    if isempty(case_sizes)
        error('Generated workload contains zero cases.');
    end

    switch lower(packing_policy)
        case "sequential_fill"
            [rack_ready_time_hr, rack_slide_count, rack_fill_fraction, ...
                rack_num_cases] = local_pack_sequential( ...
                    case_times_hr, case_sizes, rack_capacity);

        case "keep_cases_together"
            [rack_ready_time_hr, rack_slide_count, rack_fill_fraction, ...
                rack_num_cases] = local_pack_keep_cases( ...
                    case_times_hr, case_sizes, rack_capacity);

        otherwise
            error('Unsupported rack_packing_policy: %s', packing_policy);
    end

    % SimEvents Entity Generator requires strictly positive intergeneration
    % times. Epsilon-space simultaneous rack closures.
    epsilon_igt_hr = 1e-6;

    arrival_times_hr = rack_ready_time_hr(:);

    for i = 2:numel(arrival_times_hr)
        if arrival_times_hr(i) <= arrival_times_hr(i-1)
            arrival_times_hr(i) = arrival_times_hr(i-1) + epsilon_igt_hr;
        end
    end

    igt_hr = diff([0; arrival_times_hr]);

    assert(all(igt_hr > 0), ...
        'Generated rack intergeneration times must be positive.');
    assert(numel(igt_hr) == numel(rack_slide_count), ...
        'Rack timing and SlideCount vectors are not synchronized.');
    assert(sum(rack_slide_count) == sum(case_sizes), ...
        'Rack packing failed slide conservation.');
    assert(all(rack_slide_count >= 1 & rack_slide_count <= rack_capacity), ...
        'Generated rack exceeds configured capacity.');

    W = struct;
    W.igt_hr = igt_hr(:);
    W.arrival_times_hr = arrival_times_hr(:);
    W.rack_ready_time_hr = rack_ready_time_hr(:);
    W.rack_slide_count = double(rack_slide_count(:));
    W.rack_num_cases = double(rack_num_cases(:));
    W.rack_fill_fraction = double(rack_fill_fraction(:));
    W.case_times_hr = double(case_times_hr(:));
    W.case_sizes = double(case_sizes(:));
    W.case_hours = double(case_hours(:));
    W.input_racks = numel(rack_slide_count);
    W.input_slides = sum(rack_slide_count);
end


function n = local_sample_he_case_size(hour_of_day, P)

    band_idx = [];

    for b = 1:numel(P.case_size_bands)
        if hour_of_day >= P.case_size_bands(b).start_hour && ...
           hour_of_day <= P.case_size_bands(b).end_hour
            band_idx = b;
            break;
        end
    end

    if isempty(band_idx)
        values = double(P.size_values(:));
        cdf    = double(P.global_cdf(:));
    else
        values = double(P.case_size_bands(band_idx).values(:));
        cdf    = double(P.case_size_bands(band_idx).cdf(:));
    end

    u = rand;
    idx = find(u <= cdf, 1, 'first');

    if isempty(idx)
        idx = numel(values);
    end

    n = values(idx);
end


function [ready_time, slide_count, fill_fraction, num_cases] = ...
    local_pack_sequential(case_times_hr, case_sizes, rack_capacity)
% Matches the CURRENT uploaded config_histo_arrival_rack_final behavior:
% sequential capacity fill; a case may cross rack boundaries; one EOD partial.

    ready_time = [];
    slide_count = [];
    fill_fraction = [];
    num_cases = [];

    current_slides = 0;
    current_case_ids = [];
    case_ids = (1:numel(case_sizes))';

    for i = 1:numel(case_sizes)

        t_case = case_times_hr(i);
        remaining = case_sizes(i);
        cid = case_ids(i);

        while remaining > 0

            space = rack_capacity - current_slides;
            n_put = min(space, remaining);

            current_slides = current_slides + n_put;
            current_case_ids = [current_case_ids; repmat(cid,n_put,1)]; %#ok<AGROW>
            remaining = remaining - n_put;

            if current_slides == rack_capacity
                ready_time(end+1,1) = t_case; %#ok<AGROW>
                slide_count(end+1,1) = current_slides; %#ok<AGROW>
                fill_fraction(end+1,1) = current_slides/rack_capacity; %#ok<AGROW>
                num_cases(end+1,1) = numel(unique(current_case_ids)); %#ok<AGROW>

                current_slides = 0;
                current_case_ids = [];
            end
        end
    end

    if current_slides > 0
        ready_time(end+1,1) = case_times_hr(end);
        slide_count(end+1,1) = current_slides;
        fill_fraction(end+1,1) = current_slides/rack_capacity;
        num_cases(end+1,1) = numel(unique(current_case_ids));
    end
end


function [ready_time, slide_count, fill_fraction, num_cases] = ...
    local_pack_keep_cases(case_times_hr, case_sizes, rack_capacity)
% Alternative policy:
% - a case <= rack capacity is not split across racks;
% - a case > rack capacity may span racks;
% - when a <=capacity case will not fit in the current partial rack, the
%   current rack closes and the case starts on a new rack.

    ready_time = [];
    slide_count = [];
    fill_fraction = [];
    num_cases = [];

    current_slides = 0;
    current_case_ids = [];
    case_ids = (1:numel(case_sizes))';

    for i = 1:numel(case_sizes)

        t_case = case_times_hr(i);
        n_case = case_sizes(i);
        cid = case_ids(i);

        if n_case <= rack_capacity

            if current_slides > 0 && ...
                    (current_slides + n_case > rack_capacity)

                ready_time(end+1,1) = t_case; %#ok<AGROW>
                slide_count(end+1,1) = current_slides; %#ok<AGROW>
                fill_fraction(end+1,1) = current_slides/rack_capacity; %#ok<AGROW>
                num_cases(end+1,1) = numel(unique(current_case_ids)); %#ok<AGROW>

                current_slides = 0;
                current_case_ids = [];
            end

            current_slides = current_slides + n_case;
            current_case_ids = [current_case_ids; repmat(cid,n_case,1)]; %#ok<AGROW>

            if current_slides == rack_capacity
                ready_time(end+1,1) = t_case; %#ok<AGROW>
                slide_count(end+1,1) = current_slides; %#ok<AGROW>
                fill_fraction(end+1,1) = 1;
                num_cases(end+1,1) = numel(unique(current_case_ids)); %#ok<AGROW>

                current_slides = 0;
                current_case_ids = [];
            end

        else
            % Large case: splitting is allowed. It can first fill any
            % remaining capacity in the current partial rack.
            remaining = n_case;

            while remaining > 0

                space = rack_capacity - current_slides;
                n_put = min(space, remaining);

                current_slides = current_slides + n_put;
                current_case_ids = [current_case_ids; ...
                    repmat(cid,n_put,1)]; %#ok<AGROW>
                remaining = remaining - n_put;

                if current_slides == rack_capacity
                    ready_time(end+1,1) = t_case; %#ok<AGROW>
                    slide_count(end+1,1) = current_slides; %#ok<AGROW>
                    fill_fraction(end+1,1) = 1;
                    num_cases(end+1,1) = ...
                        numel(unique(current_case_ids)); %#ok<AGROW>

                    current_slides = 0;
                    current_case_ids = [];
                end
            end
        end
    end

    if current_slides > 0
        ready_time(end+1,1) = case_times_hr(end);
        slide_count(end+1,1) = current_slides;
        fill_fraction(end+1,1) = current_slides/rack_capacity;
        num_cases(end+1,1) = numel(unique(current_case_ids));
    end
end


function [mean_batch, max_batch, moved_total] = ...
    local_courier_batch_stats(rack_ready_time_hr, pickup_hr)
% Number of racks that would be waiting for each scheduled same-day pickup.

    previous_pickup = -inf;
    batches = zeros(numel(pickup_hr),1);

    for i = 1:numel(pickup_hr)
        batches(i) = sum( ...
            rack_ready_time_hr > previous_pickup & ...
            rack_ready_time_hr <= pickup_hr(i));

        previous_pickup = pickup_hr(i);
    end

    nonzero = batches(batches > 0);

    if isempty(nonzero)
        mean_batch = 0;
        max_batch = 0;
    else
        mean_batch = mean(nonzero);
        max_batch = max(nonzero);
    end

    moved_total = sum(batches);
end


function [on_duty_ts, check_toggle_ts, n_checks] = ...
    local_build_technician_schedule( ...
        tech_start_hr, tech_end_hr, ...
        check_min_min, check_max_min, rng_seed, stop_time)

    assert(tech_start_hr < tech_end_hr, ...
        'Technician start must precede end time.');
    assert(check_min_min > 0 && check_max_min >= check_min_min, ...
        'Invalid technician check interval.');

    % On-duty signal.
    duty_t = [ ...
        0; ...
        max(0, tech_start_hr - eps(max(tech_start_hr,1))); ...
        tech_start_hr; ...
        tech_end_hr - eps(max(tech_end_hr,1)); ...
        tech_end_hr; ...
        stop_time];

    duty_y = [false; false; true; true; false; false];

    [duty_t, ia] = unique(duty_t, 'stable');
    duty_y = duty_y(ia);

    on_duty_ts = timeseries(logical(duty_y), duty_t);

    % Stochastic check schedule.
    rng(rng_seed, 'twister');

    check_times = tech_start_hr;

    t = tech_start_hr;

    while true
        dt_min = check_min_min + ...
            (check_max_min - check_min_min) * rand;

        t_next = t + dt_min/60;

        if t_next > tech_end_hr
            break;
        end

        check_times(end+1,1) = t_next; %#ok<AGROW>
        t = t_next;
    end

    n_checks = numel(check_times);

    check_t = 0;
    check_y = false;
    state = false;

    for i = 1:numel(check_times)

        t = check_times(i);
        t_pre = t - eps(max(t,1));

        check_t(end+1,1) = t_pre; %#ok<AGROW>
        check_y(end+1,1) = state; %#ok<AGROW>

        state = ~state;

        check_t(end+1,1) = t; %#ok<AGROW>
        check_y(end+1,1) = state; %#ok<AGROW>
    end

    if check_t(end) < stop_time
        check_t(end+1,1) = stop_time;
        check_y(end+1,1) = state;
    end

    check_toggle_ts = timeseries(logical(check_y), check_t);
end


function [R, C] = local_run_one_scenario( ...
    model_name, bank_ref_name, mws, gate_paths, ...
    n_physical_scanners, n_active_scanners, ...
    Scanner_RackQueueSize, ...
    W, on_duty_ts, check_toggle_ts, ...
    primary_cutoff_hr, cutoff_grid_hr, ...
    stop_time, sim_seed, ...
    experiment_name, volume_label, target_slides_per_day, ...
    workload_multiplier, rep, tech_start_hr, tech_end_hr, ...
    check_policy, check_min_min, check_max_min)

    assert(n_active_scanners >= 1 && ...
           n_active_scanners <= n_physical_scanners, ...
        'Invalid n_active_scanners.');

    % Configure static scanner availability.
    for i = 1:n_physical_scanners

        set_param(gate_paths{i}, 'OperatingMode', 'Enable gate');

        if i <= n_active_scanners
            set_param(gate_paths{i}, ...
                'OpenGateAtSimulationStart', 'on');
        else
            set_param(gate_paths{i}, ...
                'OpenGateAtSimulationStart', 'off');
        end
    end

    Total_Scanner_Rack_Slots_Available = ...
        n_active_scanners * Scanner_RackQueueSize;

    % Push scenario workload / schedules into Slide_Model workspace.
    mws.assignin('igt_hr', W.igt_hr);
    mws.assignin('rack_slide_count', W.rack_slide_count);

    mws.assignin('on_duty_ts', on_duty_ts);
    mws.assignin('check_toggle_ts', check_toggle_ts);

    mws.assignin('Total_Scanner_Rack_Slots_Available', ...
        Total_Scanner_Rack_Slots_Available);

    % Reset global RNG immediately before simulation so workload / technician
    % generation does not consume the service-time stream.
    %
    % NOTE: This provides a common simulation seed by replication/configuration
    % but is not a strict common-random-number mapping of individual scan times
    % to slide identity in v1 because event ordering can differ by scanner count.
    rng(sim_seed, 'twister');

    out = sim(model_name, ...
        'StopTime', num2str(stop_time), ...
        'ReturnWorkspaceOutputs', 'on');

    % Existing model logs.
    loading_q_log    = local_get_log(out, 'loading_queue_n');
    free_top_log     = local_get_log(out, 'free_scan_slots');
    total_scan_q_log = local_get_log(out, 'total_scanner_queue_n');
    free_bank_log    = local_get_log(out, 'free_scan_slots_bank');
    review_count_log = local_get_log(out, 'review_ready_count');

    q_logs       = cell(n_physical_scanners,1);
    slide_q_logs = cell(n_physical_scanners,1);
    slide_logs   = cell(n_physical_scanners,1);
    rack_logs    = cell(n_physical_scanners,1);

    for i = 1:n_physical_scanners
        q_logs{i} = local_get_log(out, sprintf('S%d_QueueN', i));
        slide_q_logs{i} = ...
            local_get_log(out, sprintf('S%d_SlideQueueN', i));
        slide_logs{i} = ...
            local_get_log(out, sprintf('S%d_Slides', i));
        rack_logs{i} = ...
            local_get_log(out, sprintf('S%d_Racks', i));
    end

    % Per-scanner counts.
    per_scanner_racks  = zeros(1,n_physical_scanners);
    per_scanner_slides = zeros(1,n_physical_scanners);

    for i = 1:n_physical_scanners
        per_scanner_racks(i)  = local_final_count(rack_logs{i});
        per_scanner_slides(i) = local_final_count(slide_logs{i});
    end

    racks_completed_at_stop  = sum(per_scanner_racks);
    slides_scanned_at_stop   = sum(per_scanner_slides);
    review_ready_at_stop     = local_final_count(review_count_log);
    scanners_used            = nnz(per_scanner_racks > 0 | ...
                                   per_scanner_slides > 0);

    % Cutoff service-level curve.
    ready_primary = local_zoh_value(review_count_log, primary_cutoff_hr);
    pct_ready_primary = 100 * ready_primary / W.input_slides;

    t90_hr = local_time_to_count( ...
        review_count_log, ceil(0.90 * W.input_slides));
    t95_hr = local_time_to_count( ...
        review_count_log, ceil(0.95 * W.input_slides));

    % Queue / capacity metrics.
    [tQ, q_aligned] = local_align_many_timeseries_zoh(q_logs);

    fleet_q_reconstructed = sum(q_aligned,2);

    [tFleet, fleet_logged_raw] = local_ts_time_data(total_scan_q_log);
    fleet_logged = local_interp_previous_initial( ...
        tFleet, fleet_logged_raw, tQ, 0);

    [tFreeBank, free_bank_raw] = local_ts_time_data(free_bank_log);
    free_bank = local_interp_previous_initial( ...
        tFreeBank, free_bank_raw, tQ, ...
        Total_Scanner_Rack_Slots_Available);

    [tFreeTop, free_top_raw] = local_ts_time_data(free_top_log);
    free_top = local_interp_previous_initial( ...
        tFreeTop, free_top_raw, tQ, ...
        Total_Scanner_Rack_Slots_Available);

    expected_free = ...
        Total_Scanner_Rack_Slots_Available - fleet_q_reconstructed;

    fleet_capacity_ok = ...
        all(fleet_q_reconstructed >= 0) && ...
        all(fleet_q_reconstructed <= ...
            Total_Scanner_Rack_Slots_Available);

    bank_sum_ok = all(abs(fleet_logged - fleet_q_reconstructed) < 1e-9);

    free_slots_ok = ...
        all(expected_free >= 0) && ...
        all(expected_free <= Total_Scanner_Rack_Slots_Available) && ...
        all(abs(free_bank - expected_free) < 1e-9) && ...
        all(abs(free_top - expected_free) < 1e-9);

    disabled_mask = (1:n_physical_scanners) > n_active_scanners;

    disabled_scanners_idle = ...
        all(per_scanner_racks(disabled_mask) == 0) && ...
        all(per_scanner_slides(disabled_mask) == 0);

    counts_causal_ok = ...
        racks_completed_at_stop <= W.input_racks && ...
        slides_scanned_at_stop <= W.input_slides && ...
        review_ready_at_stop <= slides_scanned_at_stop;

    run_ok = ...
        fleet_capacity_ok && ...
        bank_sum_ok && ...
        free_slots_ok && ...
        disabled_scanners_idle && ...
        counts_causal_ok;

    if ~run_ok
        error(['Scenario invariant failed: fleetCapacity=%d bankSum=%d ' ...
               'freeSlots=%d disabledIdle=%d countsCausal=%d'], ...
            fleet_capacity_ok, bank_sum_ok, free_slots_ok, ...
            disabled_scanners_idle, counts_causal_ok);
    end

    % Scenario-level row.
    R = struct;
    R.Experiment = string(experiment_name);
    R.VolumeLabel = string(volume_label);
    R.TargetSlidesPerDay = target_slides_per_day;
    R.WorkloadMultiplier = workload_multiplier;
    R.Replication = rep;
    R.ActiveScanners = n_active_scanners;
    R.TechStartHr = tech_start_hr;
    R.TechEndHr = tech_end_hr;
    R.CheckPolicy = string(check_policy);
    R.CheckMinMin = check_min_min;
    R.CheckMaxMin = check_max_min;
    R.InputCases = numel(W.case_sizes);
    R.InputSlides = W.input_slides;
    R.InputRacks = W.input_racks;
    R.MeanRackFillPct = 100*mean(W.rack_fill_fraction);
    R.MedianRackFillPct = 100*median(W.rack_fill_fraction);
    R.ReadyByPrimaryCutoff = ready_primary;
    R.PctReadyByPrimaryCutoff = pct_ready_primary;
    R.PrimaryCutoffHr = primary_cutoff_hr;
    R.T90Hr = t90_hr;
    R.T95Hr = t95_hr;
    R.RacksCompletedAtStop = racks_completed_at_stop;
    R.SlidesScannedAtStop = slides_scanned_at_stop;
    R.ReviewReadyAtStop = review_ready_at_stop;
    R.ScannersUsed = scanners_used;
    R.MaxLoadingQueue = local_safe_max(local_data_vector(loading_q_log));
    R.MaxFleetScannerQueue = local_safe_max(fleet_q_reconstructed);
    R.MinFreeSlots = local_safe_min(local_data_vector(free_top_log));
    R.MaxFreeSlots = local_safe_max(local_data_vector(free_top_log));
    R.DisabledScannersIdle = disabled_scanners_idle;
    R.FleetArithmeticOK = fleet_capacity_ok && bank_sum_ok && free_slots_ok;
    R.RunOK = run_ok;
    R.SimulationSeed = sim_seed;

    % Long-form cutoff rows.
    C = repmat(struct( ...
        'Experiment', string(experiment_name), ...
        'VolumeLabel', string(volume_label), ...
        'TargetSlidesPerDay', target_slides_per_day, ...
        'Replication', rep, ...
        'ActiveScanners', n_active_scanners, ...
        'TechStartHr', tech_start_hr, ...
        'CheckPolicy', string(check_policy), ...
        'CutoffHr', NaN, ...
        'ReadySlides', NaN, ...
        'PctReady', NaN), ...
        numel(cutoff_grid_hr), 1);

    for k = 1:numel(cutoff_grid_hr)
        ready_n = local_zoh_value(review_count_log, cutoff_grid_hr(k));

        C(k).CutoffHr = cutoff_grid_hr(k);
        C(k).ReadySlides = ready_n;
        C(k).PctReady = 100 * ready_n / W.input_slides;
    end
end


function outRows = local_append_structs(outRows, newRows)
% Append scalar or vector structs without assigning a populated struct into
% an untyped struct([]), which MATLAB treats as a dissimilar-structure
% assignment.

    newRows = newRows(:).';

    if isempty(outRows)
        outRows = newRows;
    else
        assert(isequal(fieldnames(outRows), fieldnames(newRows)), ...
            'Attempted to append structures with different field sets.');
        outRows = [outRows newRows]; %#ok<AGROW>
    end
end


function local_write_checkpoint( ...
    RunRows, CutoffRows, WorkloadRealizations, output_dir)

    save(fullfile(output_dir, 'daily_scenario_CHECKPOINT.mat'), ...
        'RunRows', 'CutoffRows', 'WorkloadRealizations');
end


function x = local_get_log(out, name)
    try
        x = out.get(name);
    catch
        try
            x = out.(name);
        catch
            error('Required simulation output "%s" was not found.', name);
        end
    end

    if isempty(x)
        error('Simulation output "%s" is missing.', name);
    end
end


function v = local_data_vector(x)
    if isempty(x)
        v = [];
    elseif isa(x, 'timeseries')
        v = double(x.Data(:));
    elseif isstruct(x) && isfield(x, 'signals')
        v = double(x.signals.values(:));
    else
        v = double(x(:));
    end
end


function n = local_final_count(x)
    v = local_data_vector(x);

    if isempty(v)
        n = 0;
    else
        n = round(v(end));
    end
end


function y = local_zoh_value(x, query_t)
% Previous-value interpolation with initial value 0.

    [t, v] = local_ts_time_data(x);

    if isempty(t)
        y = 0;
        return;
    end

    idx = find(t <= query_t, 1, 'last');

    if isempty(idx)
        y = 0;
    else
        y = double(v(idx));
    end
end


function t_hit = local_time_to_count(x, target_count)

    [t, v] = local_ts_time_data(x);

    idx = find(v >= target_count, 1, 'first');

    if isempty(idx)
        t_hit = NaN;
    else
        t_hit = t(idx);
    end
end


function [tUnion, aligned] = local_align_many_timeseries_zoh(logs)

    n = numel(logs);
    tCell = cell(n,1);
    vCell = cell(n,1);

    allTimes = 0;

    for i = 1:n
        [tCell{i}, vCell{i}] = local_ts_time_data(logs{i});

        if ~isempty(tCell{i})
            [tCell{i}, ia] = unique(tCell{i}, 'last');
            vCell{i} = vCell{i}(ia);
            allTimes = [allTimes; tCell{i}(:)]; %#ok<AGROW>
        end
    end

    tUnion = unique(allTimes);
    aligned = zeros(numel(tUnion),n);

    for i = 1:n
        if isempty(tCell{i})
            aligned(:,i) = 0;
        else
            aligned(:,i) = local_interp_previous_initial( ...
                tCell{i}, vCell{i}, tUnion, 0);
        end
    end
end


function [t, v] = local_ts_time_data(x)

    if isempty(x)
        t = [];
        v = [];
    elseif isa(x, 'timeseries')
        t = double(x.Time(:));
        v = double(x.Data(:));
    elseif isstruct(x) && isfield(x, 'time') && isfield(x, 'signals')
        t = double(x.time(:));
        v = double(x.signals.values(:));
    else
        error('Expected a timeseries or Structure With Time log.');
    end
end


function y = local_interp_previous_initial(t, v, tq, initial_value)

    y = initial_value * ones(size(tq));

    for i = 1:numel(tq)
        k = find(t <= tq(i), 1, 'last');

        if ~isempty(k)
            y(i) = v(k);
        end
    end
end


function m = local_safe_max(v)
    if isempty(v)
        m = 0;
    else
        m = max(v);
    end
end


function m = local_safe_min(v)
    if isempty(v)
        m = 0;
    else
        m = min(v);
    end
end


function Summary = local_make_scenario_summary(R)
% One row per experiment / volume / scanner / technician-policy configuration.

    key = strcat( ...
        string(R.Experiment), "|", ...
        string(R.TargetSlidesPerDay), "|", ...
        string(R.ActiveScanners), "|", ...
        string(R.TechStartHr), "|", ...
        string(R.CheckPolicy));

    [uKey, ia, g] = unique(key, 'stable');

    Rows = struct([]);

    for k = 1:numel(uKey)

        idx = (g == k);
        first = find(idx,1,'first');

        x = R.PctReadyByPrimaryCutoff(idx);

        Rows(end+1).Experiment = R.Experiment(first); %#ok<SAGROW>
        Rows(end).VolumeLabel = R.VolumeLabel(first);
        Rows(end).TargetSlidesPerDay = R.TargetSlidesPerDay(first);
        Rows(end).ActiveScanners = R.ActiveScanners(first);
        Rows(end).TechStartHr = R.TechStartHr(first);
        Rows(end).CheckPolicy = R.CheckPolicy(first);
        Rows(end).N = sum(idx);
        Rows(end).MeanPctReady = mean(x, 'omitnan');
        Rows(end).SDPctReady = std(x, 'omitnan');
        Rows(end).P05PctReady = prctile(x,5);
        Rows(end).P95PctReady = prctile(x,95);
        Rows(end).MeanT90Hr = mean(R.T90Hr(idx), 'omitnan');
        Rows(end).MeanT95Hr = mean(R.T95Hr(idx), 'omitnan');
        Rows(end).MeanInputSlides = mean(R.InputSlides(idx));
        Rows(end).MeanInputRacks = mean(R.InputRacks(idx));
        Rows(end).MeanRackFillPct = mean(R.MeanRackFillPct(idx));
        Rows(end).MeanMaxLoadingQueue = mean(R.MaxLoadingQueue(idx));
        Rows(end).MeanMaxFleetQueue = mean(R.MaxFleetScannerQueue(idx));
    end

    Summary = struct2table(Rows);
end


function local_make_workload_profile_figure( ...
    T, target_daily_slides, volume_labels, output_dir)

    f = figure('Name','Expected hourly H&E workload profiles', ...
        'Color','w', 'Position',[100 100 1500 450]);

    tl = tiledlayout(1,numel(target_daily_slides), ...
        'TileSpacing','compact','Padding','compact');

    ymax = 1.05 * max(T.ExpectedSlidesPerHour);

    for v = 1:numel(target_daily_slides)

        nexttile;

        idx = T.TargetSlidesPerDay == target_daily_slides(v);

        bar(T.Hour(idx), T.ExpectedSlidesPerHour(idx));

        xlabel('Hour');
        ylabel('Expected slides/hour');
        title(sprintf('%s: %d slides/day', ...
            volume_labels(v), target_daily_slides(v)));

        xlim([-0.5 23.5]);
        ylim([0 ymax]);
        grid on;
    end

    title(tl, 'Representative daily H&E slide-availability profiles');

    exportgraphics(f, ...
        fullfile(output_dir, 'figure_workload_profiles.png'), ...
        'Resolution', 300);
    exportgraphics(f, ...
        fullfile(output_dir, 'figure_workload_profiles.pdf'), ...
        'ContentType','vector');
end


function local_make_primary_heatmap( ...
    R, target_daily_slides, volume_labels, ...
    scanner_levels, tech_start_levels, primary_cutoff_hr, output_dir)

    P = R(R.Experiment == "Primary",:);

    f = figure('Name','Primary service-level heatmaps', ...
        'Color','w', 'Position',[100 100 1550 500]);

    tl = tiledlayout(1,numel(target_daily_slides), ...
        'TileSpacing','compact','Padding','compact');

    for v = 1:numel(target_daily_slides)

        M = nan(numel(tech_start_levels), numel(scanner_levels));

        for ti = 1:numel(tech_start_levels)
            for si = 1:numel(scanner_levels)

                idx = ...
                    P.TargetSlidesPerDay == target_daily_slides(v) & ...
                    P.TechStartHr == tech_start_levels(ti) & ...
                    P.ActiveScanners == scanner_levels(si);

                if any(idx)
                    M(ti,si) = mean( ...
                        P.PctReadyByPrimaryCutoff(idx), 'omitnan');
                end
            end
        end

        nexttile;

        imagesc(scanner_levels, tech_start_levels, M);
        axis xy;
        caxis([0 100]);
        colorbar;

        xlabel('Active scanners');
        ylabel('Technician start time');
        title(sprintf('%s: %d slides/day', ...
            volume_labels(v), target_daily_slides(v)));

        xticks(scanner_levels);
        yticks(tech_start_levels);
    end

    title(tl, sprintf('Mean %% ReviewReady by %.1f hr', primary_cutoff_hr));

    exportgraphics(f, ...
        fullfile(output_dir, 'figure_primary_heatmaps.png'), ...
        'Resolution', 300);
    exportgraphics(f, ...
        fullfile(output_dir, 'figure_primary_heatmaps.pdf'), ...
        'ContentType','vector');
end


function local_make_cutoff_curve_figure( ...
    C, target_slides, tech_start_hr, scanner_levels, output_dir)

    P = C( ...
        C.Experiment == "Primary" & ...
        C.TargetSlidesPerDay == target_slides & ...
        C.TechStartHr == tech_start_hr, :);

    if isempty(P)
        return;
    end

    f = figure('Name','ReviewReady cutoff curves', ...
        'Color','w', 'Position',[100 100 900 600]);

    hold on;

    cutoffs = unique(P.CutoffHr);

    for s = 1:numel(scanner_levels)

        y = nan(size(cutoffs));

        for k = 1:numel(cutoffs)
            idx = P.ActiveScanners == scanner_levels(s) & ...
                  P.CutoffHr == cutoffs(k);

            y(k) = mean(P.PctReady(idx), 'omitnan');
        end

        plot(cutoffs, y, '-o', ...
            'DisplayName', sprintf('%d scanner(s)', scanner_levels(s)));
    end

    xline(17.5, '--', '17:30');
    yline(90, ':', '90%');
    yline(95, ':', '95%');

    xlabel('Daily cutoff time (hour)');
    ylabel('% of daily slides ReviewReady');
    title(sprintf('%d slides/day, technician start %.0f:00', ...
        target_slides, tech_start_hr));

    ylim([0 100]);
    grid on;
    legend('Location','best');
    hold off;

    exportgraphics(f, ...
        fullfile(output_dir, 'figure_cutoff_curves_medium.png'), ...
        'Resolution', 300);
    exportgraphics(f, ...
        fullfile(output_dir, 'figure_cutoff_curves_medium.pdf'), ...
        'ContentType','vector');
end


function local_make_check_sensitivity_figure( ...
    R, target_daily_slides, volume_labels, ...
    scanner_levels, check_policy_name, primary_cutoff_hr, output_dir)

    P = R(R.Experiment == "CheckSensitivity",:);

    if isempty(P)
        return;
    end

    % Use medium volume if available; otherwise use the middle configured
    % target. This keeps the sensitivity figure compact for the poster.
    if any(target_daily_slides == 1000)
        target = 1000;
        volume_idx = find(target_daily_slides == 1000,1,'first');
    else
        volume_idx = ceil(numel(target_daily_slides)/2);
        target = target_daily_slides(volume_idx);
    end

    f = figure('Name','Technician check sensitivity', ...
        'Color','w', 'Position',[100 100 1100 600]);

    hold on;

    for cp = 1:numel(check_policy_name)

        y = nan(size(scanner_levels));

        for s = 1:numel(scanner_levels)

            idx = ...
                P.TargetSlidesPerDay == target & ...
                P.ActiveScanners == scanner_levels(s) & ...
                P.CheckPolicy == check_policy_name(cp);

            if any(idx)
                y(s) = mean( ...
                    P.PctReadyByPrimaryCutoff(idx), 'omitnan');
            end
        end

        plot(scanner_levels, y, '-o', ...
            'DisplayName', check_policy_name(cp));
    end

    xlabel('Active scanners');
    ylabel(sprintf('%% ReviewReady by %.1f hr', primary_cutoff_hr));
    title(sprintf('%s workload (%d slides/day): technician check sensitivity', ...
        volume_labels(volume_idx), target));

    ylim([0 100]);
    xticks(scanner_levels);
    grid on;
    legend('Location','best');
    hold off;

    exportgraphics(f, ...
        fullfile(output_dir, 'figure_check_sensitivity.png'), ...
        'Resolution', 300);
    exportgraphics(f, ...
        fullfile(output_dir, 'figure_check_sensitivity.pdf'), ...
        'ContentType','vector');
end
