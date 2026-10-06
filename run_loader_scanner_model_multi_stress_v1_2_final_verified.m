%% run_loader_scanner_model_multi_stress_v1_2_final_verified.m
% FINAL v1.2 stress validation for the six-position ScannerBank architecture.
%
% Model time unit: hours.
%
% Architecture under test:
%
% TestRackGenerator
%      -> LoadingQueue
%      -> LoadingGate / LoadingGateLogic
%      -> ScannerBank
%           -> ChooseScanner MATLAB Function
%                * enabled-first routing eligibility
%                * first enabled non-busy scanner
%                * otherwise enabled scanner with smallest ScannerQueue.n
%                * fleetQueueN = sum(all six ScannerQueue.n signals)
%           -> SelectionEventToggle -> MessageTrigger (either-edge Triggered Subsystem)
%                * toggle flips once per selectedPort change
%                * Message Send executes once per toggle edge
%           -> Entity Replicator
%                * original/control branch -> ScannerSelectSwitch
%                * diagnostic branch -> Message Receive
%                     - data   -> selected_scanner_message
%                     - status -> selected_scanner_message_status
%           -> ScannerSelectSwitch (From control port; 6 ways)
%           -> ScannerGate1..6
%           -> GenericScanner x 6
%           -> Entity Input Switch
%           -> ComputeFreeScannerSlots
%      -> SlideSink
%
% IMPORTANT V1.2 SEMANTICS
% ------------------------
% ScannerEnabled is the authoritative fleet configuration.
%
%   * Scanner 1 MUST always be enabled.
%   * Router eligibility is derived from ScannerEnabled.
%   * ScannerGate1..6 are configured from ScannerEnabled for each scenario.
%   * Total_Scanner_Rack_Slots_Available includes ENABLED scanners only.
%   * fleetQueueN still sums all six physical ScannerQueue.n signals so any
%     accidental occupancy on a disabled scanner is visible to validation.
%
% ScannerQueue entry remains the scanner-capacity reservation boundary.
% Rerack/load delays occur downstream inside each GenericScanner.
%
% This driver:
%   1. Audits the v1.2 ScannerBank / Scanners / GenericScanner hierarchy.
%   2. Runs stress scenarios with six-, three-, and noncontiguous three-scanner
%      enabled configurations.
%   3. Uses ScannerBank's persistent workspace outputs:
%         selected_scanner
%         scanner_select_change
%         selected_scanner_message
%         selected_scanner_message_status
%         S#_QueueN
%         S#_ScannerBusy
%         S#_SlideQueueN
%         S#_Racks
%         S#_Slides
%         total_scanner_queue_n
%         free_scan_slots_bank
%      and adds only two temporary top-level loggers for LoadingQueue.n and
%      the public ScannerBank free_scan_slots output.
%   4. Verifies:
%         - every individual ScannerQueue stays within local capacity
%         - logged fleetQueueN stays within ENABLED fleet capacity
%         - free_scan_slots stays within 0..capacity
%         - fleetQueueN/free_scan_slots extrema satisfy capacity complement arithmetic
%         - scanner_busy remains Boolean and asserts on scanners doing work
%         - selected_scanner is always an enabled scanner in the range 1..6
%         - SelectionEventToggle has one edge for each selected_scanner transition
%         - Message Receive status identifies actual receive events
%         - received payload sequence exactly matches selected_scanner transitions
%         - every enabled scanner is exercised by the stress scenario
%         - deterministic heavy-backlog scenarios distribute racks across enabled
%           scanners within a configured balance tolerance
%         - disabled scanners never queue, become busy, scan slides, or retire racks
%         - cumulative rack/slide counters remain nonnegative and monotonic
%
% IMPORTANT VALIDATION NOTE
% -------------------------
% SimEvents can execute multiple ordered microsteps at the same simulation time.
% Independently logged statistics do not preserve enough information to
% reconstruct that internal ordering reliably. This final harness therefore
% does NOT use timestamp-reconstructed queue/busy state as a pass/fail oracle.
% It uses static wiring audits plus direct signal-range checks, exact message-
% event checks, and physical per-scanner outcomes instead.
%
% Keep these files in the same folder:
%   Loader_Scanner_Model_Multi.slx
%   ScannerBank.slx
%   GenericScanner.slx
%
% The script changes ScannerGate1..6 IN MEMORY for each scenario and adds
% temporary To Workspace logging blocks only to the loaded top-level test
% model. It does NOT save those model changes.

clear;
clc;

%% ========================================================================
% NAMES / COMMON CONFIGURATION
% ==========================================================================

modelName   = 'Loader_Scanner_Model_Multi';
bankName    = 'ScannerBank';
scannerName = 'GenericScanner';

modelFile   = [modelName '.slx'];
bankFile    = [bankName '.slx'];
scannerFile = [scannerName '.slx'];

nScanners = 6;
rngSeed   = 42;

assert(isfile(modelFile), ...
    'Cannot find %s. Put this script beside the model files.', modelFile);
assert(isfile(bankFile), ...
    'Cannot find %s. Put this script beside the model files.', bankFile);
assert(isfile(scannerFile), ...
    'Cannot find %s. Put this script beside the model files.', scannerFile);

% Common scanner parameters
Scanner_SlideQueueSize = 1;
Scanner_SlideScanTime  = 110/3600;   % hr/slide
ScanTime_Mu            = log(Scanner_SlideScanTime);
ScanTime_Sigma         = 0;

%% ========================================================================
% TEST SCENARIOS
% ==========================================================================

S = struct([]);

% 1) Six-scanner baseline.
S(1).name = 'Baseline - 6 enabled scanners';
S(1).enabled = logical([1 1 1 1 1 1]);
S(1).sim_days = 1;  S(1).drain_hrs = 8;
S(1).tech_start = 8; S(1).tech_end = 19.5;
S(1).check_min = 10/60; S(1).check_max = 30/60;
S(1).rack_slides = 20; S(1).rack_dt = 1/60;
S(1).rack_slots = 23; S(1).rerack = 3/60; S(1).load = 5/60;
S(1).balance_tol = 1;   % deterministic heavy backlog: nearly equal rack counts

% 2) Three-scanner fleet-level capacity torture test.
% One waiting slot per enabled scanner -> three fleet waiting positions.
S(2).name = '3 scanners / tiny capacity / heavy backlog';
S(2).enabled = logical([1 1 1 0 0 0]);
S(2).sim_days = 1;  S(2).drain_hrs = 4;
S(2).tech_start = 8; S(2).tech_end = 19.5;
S(2).check_min = 10/60; S(2).check_max = 30/60;
S(2).rack_slides = 20; S(2).rack_dt = 1/60;
S(2).rack_slots = 1; S(2).rerack = 3/60; S(2).load = 5/60;
S(2).balance_tol = 1;

% 3) Sparse rack supply with three enabled scanners.
S(3).name = 'Sparse rack supply - 3 scanners';
S(3).enabled = logical([1 1 1 0 0 0]);
S(3).sim_days = 1;  S(3).drain_hrs = 4;
S(3).tech_start = 8; S(3).tech_end = 19.5;
S(3).check_min = 10/60; S(3).check_max = 30/60;
S(3).rack_slides = 20; S(3).rack_dt = 45/60;
S(3).rack_slots = 23; S(3).rerack = 3/60; S(3).load = 5/60;
S(3).balance_tol = inf; % sparse supply: equal rack counts are not expected

% 4) Noncontiguous enabled fleet verifies router/gate eligibility.
S(4).name = 'Noncontiguous 1/3/5 - slow handling';
S(4).enabled = logical([1 0 1 0 1 0]);
S(4).sim_days = 1;  S(4).drain_hrs = 6;
S(4).tech_start = 8; S(4).tech_end = 19.5;
S(4).check_min = 5/60; S(4).check_max = 10/60;
S(4).rack_slides = 20; S(4).rack_dt = 1/60;
S(4).rack_slots = 2; S(4).rerack = 6/60; S(4).load = 10/60;
S(4).balance_tol = 1;

% 5) Multi-day shift-boundary regression with the full fleet enabled.
S(5).name = 'Three-day shift-boundary - 6 scanners';
S(5).enabled = logical([1 1 1 1 1 1]);
S(5).sim_days = 3;  S(5).drain_hrs = 8;
S(5).tech_start = 8; S(5).tech_end = 19.5;
S(5).check_min = 10/60; S(5).check_max = 30/60;
S(5).rack_slides = 20; S(5).rack_dt = 2/60;
S(5).rack_slots = 23; S(5).rerack = 3/60; S(5).load = 5/60;
S(5).balance_tol = 1;

%% ========================================================================
% INITIAL CLEANUP
% ==========================================================================

local_close_if_loaded(modelName);
local_close_if_loaded(bankName);
local_close_if_loaded(scannerName);

%% ========================================================================
% STATIC ARCHITECTURE AUDIT
% ==========================================================================

load_system(modelFile);
load_system(bankFile);
load_system(scannerFile);

fprintf('\n============================================================\n');
fprintf(' MULTI-SCANNER LOADER + SCANNERBANK STRESS TEST\n');
fprintf('============================================================\n');
fprintf('Scanners:                %d\n', nScanners);
fprintf('Tests:                   %d\n', numel(S));
fprintf('Slide scan time:         %.1f sec\n', Scanner_SlideScanTime*3600);
fprintf('Random seed/test:        %d\n', rngSeed);
fprintf('============================================================\n');

% Top-level ScannerBank reference.
topBank = [modelName '/ScannerBank'];
assert(getSimulinkBlockHandle(topBank) ~= -1, ...
    'Top-level ScannerBank block is missing.');

assert(strcmp(get_param(topBank, 'ReferencedSubsystem'), bankName), ...
    'Top-level ScannerBank does not reference %s.', bankName);

% Bank routing/control path.
outSwitch = [bankName '/ScannerSelectSwitch'];
inSwitch  = local_find_one(bankName, 'BlockType', 'EntityInputSwitch');

assert(str2double(get_param(outSwitch, 'NumberOutputPorts')) == nScanners, ...
    'ScannerSelectSwitch does not have %d outputs.', nScanners);
assert(strcmpi(strtrim(get_param(outSwitch, 'SwitchingCriterion')), ...
               'From control port'), ...
    'ScannerSelectSwitch is not configured for From control port.');

assert(str2double(get_param(inSwitch, 'NumberInputPorts')) == nScanners, ...
    'Entity Input Switch does not have %d inputs.', nScanners);

chooseBlock = [bankName '/ChooseScanner'];
assert(getSimulinkBlockHandle(chooseBlock) ~= -1, ...
    'ScannerBank ChooseScanner MATLAB Function block is missing.');

choosePH = get_param(chooseBlock, 'PortHandles');
assert(numel(choosePH.Inport) == 13, ...
    ['ChooseScanner must have 13 scalar/vector inputs: enabled, q1-q6, ' ...
     'and b1-b6. Found %d inputs.'], numel(choosePH.Inport));
assert(numel(choosePH.Outport) == 2, ...
    'ChooseScanner must have two outputs: selectedPort and fleetQueueN.');

enabledBlock = [bankName '/ScannerEnabled'];
assert(getSimulinkBlockHandle(enabledBlock) ~= -1, ...
    'ScannerBank ScannerEnabled Constant block is missing.');
assert(strcmp(strtrim(get_param(enabledBlock, 'Value')), 'ScannerEnabled'), ...
    'ScannerEnabled Constant does not reference workspace variable ScannerEnabled.');

% The v1.2 scalar-input design intentionally has no top-level Mux/Bus Creator
% for SimEvents statistics; those signals cannot feed a Mux/Bus Creator.
muxBlocks = find_system(bankName, ...
    'SearchDepth', 1, ...
    'LookUnderMasks', 'all', ...
    'FollowLinks', 'on', ...
    'BlockType', 'Mux');
assert(isempty(muxBlocks), ...
    ['Top-level ScannerBank still contains a Mux block. v1.2 requires ' ...
     'q1-q6 and b1-b6 to connect directly to ChooseScanner.']);

% selectedPort changes are converted to one-shot messages by flipping a
% persistent Boolean-like toggle. MessageTrigger fires on EITHER toggle edge,
% so consecutive selectedPort changes cannot collapse into one trigger.
toggleBlock = [bankName '/SelectionEventToggle'];
assert(getSimulinkBlockHandle(toggleBlock) ~= -1, ...
    'ScannerBank SelectionEventToggle MATLAB Function block is missing.');
togglePH = get_param(toggleBlock, 'PortHandles');
assert(numel(togglePH.Inport) == 1 && numel(togglePH.Outport) == 1, ...
    'SelectionEventToggle must have exactly one input and one output.');

messageTriggerBlock = [bankName '/MessageTrigger'];
assert(getSimulinkBlockHandle(messageTriggerBlock) ~= -1, ...
    'ScannerBank MessageTrigger triggered subsystem is missing.');

triggerBlocks = find_system(messageTriggerBlock, ...
    'SearchDepth', 1, ...
    'LookUnderMasks', 'all', ...
    'FollowLinks', 'on', ...
    'BlockType', 'TriggerPort');
assert(numel(triggerBlocks) == 1, ...
    'Expected exactly one Trigger block inside MessageTrigger; found %d.', ...
    numel(triggerBlocks));
triggerBlock = triggerBlocks{1};
assert(strcmpi(strtrim(get_param(triggerBlock, 'TriggerType')), 'either'), ...
    'MessageTrigger Trigger block must be configured for either edge.');

sendBlock = [messageTriggerBlock '/SwitchSelectMess'];
assert(getSimulinkBlockHandle(sendBlock) ~= -1, ...
    'MessageTrigger/SwitchSelectMess Message Send block is missing.');
sendPH = get_param(sendBlock, 'PortHandles');
assert(numel(sendPH.Inport) == 1, ...
    ['SwitchSelectMess should have only its data input. The enable port must ' ...
     'remain hidden because MessageTrigger supplies one-shot execution.']);

triggerDataIn = [messageTriggerBlock '/selectedPort'];
assert(getSimulinkBlockHandle(triggerDataIn) ~= -1, ...
    'MessageTrigger selectedPort Inport is missing.');

triggerOut = [messageTriggerBlock '/Out1'];
assert(getSimulinkBlockHandle(triggerOut) ~= -1, ...
    'MessageTrigger message Outport is missing.');

replicatorBlock = [bankName '/Entity Replicator'];
assert(getSimulinkBlockHandle(replicatorBlock) ~= -1, ...
    'ScannerBank Entity Replicator block is missing.');

receiveBlock = [bankName '/MessageReceive'];
assert(getSimulinkBlockHandle(receiveBlock) ~= -1, ...
    'ScannerBank MessageReceive block is missing.');
receivePH = get_param(receiveBlock, 'PortHandles');
assert(numel(receivePH.Outport) == 2, ...
    'MessageReceive must expose both receive-status and data outputs.');
assert(strcmpi(get_param(receiveBlock, 'ShowQueueStatus'), 'on'), ...
    'MessageReceive must have Show receive status enabled.');
assert(strcmp(strtrim(get_param(receiveBlock, 'InitialValue')), '0'), ...
    'MessageReceive Initial value must be 0.');
assert(strcmpi(strtrim(get_param(receiveBlock, 'ValueSourceWhenQueueIsEmpty')), ...
               'Use initial value'), ...
    'MessageReceive must use the initial value when its queue is empty.');

assert(strcmpi(get_param(replicatorBlock, 'ReplicasDepartFrom'), ...
               'Separate output ports'), ...
    'Entity Replicator must use Separate output ports.');
assert(str2double(get_param(replicatorBlock, 'NumberReplicas')) == 1, ...
    'Entity Replicator must create exactly one diagnostic replica.');
assert(strcmpi(get_param(replicatorBlock, ...
                         'HoldOriginalEntityUntilAllReplicasDepart'), 'on'), ...
    ['For message-path diagnostics, Entity Replicator must hold the original ' ...
     'until the diagnostic replica departs.']);

% Locate the two persistent observers by workspace variable rather than by
% block name. MessageReceive output 1 is receive status and output 2 is data.
messageLoggerBlocks = find_system(bankName, ...
    'LookUnderMasks', 'all', 'FollowLinks', 'on', ...
    'BlockType', 'ToWorkspace', 'VariableName', 'selected_scanner_message');
statusLoggerBlocks = find_system(bankName, ...
    'LookUnderMasks', 'all', 'FollowLinks', 'on', ...
    'BlockType', 'ToWorkspace', 'VariableName', 'selected_scanner_message_status');
assert(numel(messageLoggerBlocks) == 1 && numel(statusLoggerBlocks) == 1, ...
    'Expected one message-data logger and one message-status logger.');
messageLoggerBlock = messageLoggerBlocks{1};
statusLoggerBlock  = statusLoggerBlocks{1};

% Audit the control-message observation chain. ChooseScanner selectedPort
% feeds SelectionEventToggle and the MessageTrigger data input. The toggle
% drives the Triggered Subsystem trigger. Inside MessageTrigger, selectedPort
% feeds SwitchSelectMess; the resulting message exits the subsystem and is
% replicated: output 1 is observed and output 2 drives the real switch.
assert(local_port_drives_block(chooseBlock, 1, toggleBlock), ...
    'ChooseScanner selectedPort does not drive SelectionEventToggle.');
assert(local_port_drives_block(chooseBlock, 1, messageTriggerBlock), ...
    'ChooseScanner selectedPort does not drive MessageTrigger data input.');
assert(local_port_drives_block(toggleBlock, 1, messageTriggerBlock), ...
    'SelectionEventToggle output does not drive MessageTrigger trigger input.');
assert(local_port_drives_block(triggerDataIn, 1, sendBlock), ...
    'MessageTrigger selectedPort Inport does not drive SwitchSelectMess.');
assert(local_port_drives_block(sendBlock, 1, triggerOut), ...
    'SwitchSelectMess output does not drive MessageTrigger message Outport.');
assert(local_port_drives_block(messageTriggerBlock, 1, replicatorBlock), ...
    'MessageTrigger output does not drive Entity Replicator.');
assert(local_port_drives_block(replicatorBlock, 1, receiveBlock), ...
    'Entity Replicator output 1 does not drive MessageReceive.');
assert(local_port_drives_block(replicatorBlock, 2, outSwitch), ...
    'Entity Replicator output 2 does not drive ScannerSelectSwitch control.');
assert(local_port_drives_block(receiveBlock, 1, statusLoggerBlock), ...
    'MessageReceive output 1 does not drive selected_scanner_message_status.');
assert(local_port_drives_block(receiveBlock, 2, messageLoggerBlock), ...
    'MessageReceive output 2 does not drive selected_scanner_message.');

% Six GenericScanner references now live inside ScannerBank/Scanners.
scannersSubsystem = [bankName '/Scanners'];
assert(getSimulinkBlockHandle(scannersSubsystem) ~= -1, ...
    'ScannerBank/Scanners subsystem is missing.');

for i = 1:nScanners
    p = sprintf('%s/Scanner_%d', scannersSubsystem, i);
    assert(getSimulinkBlockHandle(p) ~= -1, ...
        'Missing ScannerBank/Scanners block Scanner_%d.', i);

    assert(strcmp(get_param(p, 'ReferencedSubsystem'), scannerName), ...
        'Scanner_%d does not reference %s.', i, scannerName);

    gatePath = sprintf('%s/ScannerGate%d', bankName, i);
    assert(getSimulinkBlockHandle(gatePath) ~= -1, ...
        'Missing ScannerBank gate ScannerGate%d.', i);
end

% Bank-level fleet occupancy / free-slot calculation remains explicit.
freeBlock = [bankName '/ComputeFreeScannerSlots'];
assert(getSimulinkBlockHandle(freeBlock) ~= -1, ...
    'ScannerBank ComputeFreeScannerSlots block is missing.');
assert(strcmp(get_param(freeBlock, 'Inputs'), '-+'), ...
    ['ComputeFreeScannerSlots is expected to implement ' ...
     'capacity - occupancy using Inputs="-+".']);

capacityBlock = [bankName '/EnabledScannerFleetCapacity'];
assert(getSimulinkBlockHandle(capacityBlock) ~= -1, ...
    'ScannerBank EnabledScannerFleetCapacity block is missing.');
assert(strcmp(strtrim(get_param(capacityBlock, 'Value')), ...
              'Total_Scanner_Rack_Slots_Available'), ...
    ['EnabledScannerFleetCapacity must reference ' ...
     'Total_Scanner_Rack_Slots_Available.']);

freeOutBlock = [bankName '/free_scan_slots'];
assert(getSimulinkBlockHandle(freeOutBlock) ~= -1, ...
    'ScannerBank free_scan_slots Outport is missing.');
freeOutPortText = get_param(freeOutBlock, 'Port');
if isempty(freeOutPortText)
    freeOutPort = 1;
else
    freeOutPort = str2double(freeOutPortText);
end
assert(freeOutPort == 1, ...
    'ScannerBank free_scan_slots must remain public output port 1.');

fleetLoggerBlocks = find_system(bankName, ...
    'LookUnderMasks', 'all', 'FollowLinks', 'on', ...
    'BlockType', 'ToWorkspace', 'VariableName', 'total_scanner_queue_n');
freeLoggerBlocks = find_system(bankName, ...
    'LookUnderMasks', 'all', 'FollowLinks', 'on', ...
    'BlockType', 'ToWorkspace', 'VariableName', 'free_scan_slots_bank');

assert(numel(fleetLoggerBlocks) == 1 && numel(freeLoggerBlocks) == 1, ...
    'Expected one fleet-queue logger and one bank free-slot logger.');
fleetLoggerBlock = fleetLoggerBlocks{1};
freeLoggerBlock  = freeLoggerBlocks{1};

% Structural proof of the arithmetic path. This avoids using timestamp-aligned
% SimEvents statistics to infer same-time microstep ordering.
assert(local_port_drives_port(chooseBlock, 2, freeBlock, 1), ...
    ['ChooseScanner fleetQueueN must drive ComputeFreeScannerSlots input 1 ' ...
     '(the negative/occupancy input).']);
assert(local_port_drives_port(capacityBlock, 1, freeBlock, 2), ...
    ['EnabledScannerFleetCapacity must drive ComputeFreeScannerSlots input 2 ' ...
     '(the positive/capacity input).']);
assert(local_port_drives_block(chooseBlock, 2, fleetLoggerBlock), ...
    'ChooseScanner fleetQueueN does not drive total_scanner_queue_n logger.');
assert(local_port_drives_block(freeBlock, 1, freeOutBlock), ...
    'ComputeFreeScannerSlots does not drive the public free_scan_slots Outport.');
assert(local_port_drives_block(freeBlock, 1, freeLoggerBlock), ...
    'ComputeFreeScannerSlots does not drive free_scan_slots_bank logger.');

% GenericScanner internals.
requiredScannerBlocks = { ...
    'ScannerQueue'
    'RerackTime'
    'RackLoadUnloadTime'
    'CurrentRackGate'
    'UnpackSlides'
    'SlideQueue'
    'SlideScanning'
    'RackSink'};

for i = 1:numel(requiredScannerBlocks)
    p = [scannerName '/' requiredScannerBlocks{i}];
    assert(getSimulinkBlockHandle(p) ~= -1, ...
        'GenericScanner block is missing: %s', p);
end

assert(strcmpi(strtrim(get_param([scannerName '/ScannerQueue'], 'Capacity')), ...
               'Scanner_RackQueueSize'), ...
    'ScannerQueue capacity is not Scanner_RackQueueSize.');

sqEntry = get_param([scannerName '/ScannerQueue'], 'EntryAction');
assert(contains(sqEntry, 'RackLoaded'), ...
    'ScannerQueue EntryAction no longer calls RackLoaded().');

assert(str2double(get_param([scannerName '/SlideScanning'], 'Capacity')) == 1, ...
    'SlideScanning capacity must be 1.');

% Current GenericScanner public output contract.
expectedOutports = { ...
    'ScannerQueue_n',  1
    'scanner_busy',    2
    'SlideQueue_n',    3
    'RackSink_a',      4
    'SlideScanning_d', 5
    'Scanned_Slides',  6};

for i = 1:size(expectedOutports,1)
    blockName = expectedOutports{i,1};
    expectedPort = expectedOutports{i,2};
    p = [scannerName '/' blockName];

    assert(getSimulinkBlockHandle(p) ~= -1, ...
        'GenericScanner output block is missing: %s', p);

    portText = get_param(p, 'Port');
    if isempty(portText)
        actualPort = 1;
    else
        actualPort = str2double(portText);
    end

    assert(actualPort == expectedPort, ...
        'GenericScanner output %s is port %d; expected port %d.', ...
        blockName, actualPort, expectedPort);
end

% ScannerBank now owns persistent workspace logging for fleet and per-scanner
% diagnostics. Verify the names expected by this harness before simulation.
requiredBankLogVars = { ...
    'selected_scanner', ...
    'scanner_select_change', ...
    'selected_scanner_message', ...
    'selected_scanner_message_status', ...
    'total_scanner_queue_n', ...
    'free_scan_slots_bank'};
for i = 1:nScanners
    requiredBankLogVars = [requiredBankLogVars, { ... %#ok<AGROW>
        sprintf('S%d_QueueN', i), ...
        sprintf('S%d_ScannerBusy', i), ...
        sprintf('S%d_SlideQueueN', i), ...
        sprintf('S%d_Racks', i), ...
        sprintf('S%d_Slides', i)}];
end

for i = 1:numel(requiredBankLogVars)
    local_assert_workspace_var(bankName, requiredBankLogVars{i});
end

fprintf('Static architecture audit: PASS\n');

% Close before tests so every case starts with fresh persistent state.
local_close_if_loaded(modelName);
local_close_if_loaded(bankName);
local_close_if_loaded(scannerName);

%% ========================================================================
% RESULT STORAGE
% ==========================================================================

nTests = numel(S);

results = repmat(struct( ...
    'Name','', ...
    'Checks',0, ...
    'EnabledCount',0, ...
    'FleetCapacity',0, ...
    'MaxLoadQ',NaN, ...
    'MaxFleetScanQ',NaN, ...
    'MinFreeSlots',NaN, ...
    'MaxFreeSlots',NaN, ...
    'RacksCompleted',0, ...
    'SlidesCompleted',0, ...
    'ScannersUsed',0, ...
    'IndividualCapacityOK',false, ...
    'FleetSignalOK',false, ...
    'FreeSignalOK',false, ...
    'CapacityComplementOK',false, ...
    'CountersOK',false, ...
    'BusySignalsOK',false, ...
    'SelectionOK',false, ...
    'ToggleSignalOK',false, ...
    'MessagePathOK',false, ...
    'ExpectedMessages',0, ...
    'ObservedMessages',0, ...
    'EnabledUseOK',false, ...
    'BalanceOK',false, ...
    'BalanceSpread',NaN, ...
    'DisabledIdleOK',false, ...
    'Pass',false, ...
    'ScannerEnabled',false(1,nScanners), ...
    'PerScannerMaxQ',[], ...
    'PerScannerBusySeen',[], ...
    'PerScannerRacks',[], ...
    'PerScannerSlides',[]), nTests, 1);

%% ========================================================================
% RUN STRESS SUITE
% ==========================================================================

for testIdx = 1:nTests

    %% --------------------------------------------------------------------
    % Scenario parameters
    % ---------------------------------------------------------------------

    rng(rngSeed, 'twister');

    TestRack_SlideCount          = S(testIdx).rack_slides;
    TestRack_IntergenerationTime = S(testIdx).rack_dt;

    Scanner_RerackTime    = S(testIdx).rerack;
    Scanner_RackLoadTime  = S(testIdx).load;
    Scanner_RackQueueSize = S(testIdx).rack_slots;

    % v1.2 fleet configuration: one authoritative enabled vector.
    ScannerEnabled = logical(S(testIdx).enabled(:).');

    assert(numel(ScannerEnabled) == nScanners, ...
        'ScannerEnabled must contain exactly %d elements.', nScanners);
    assert(ScannerEnabled(1), ...
        'v1.2 design rule: Scanner 1 must always be enabled.');

    nActiveScanners = nnz(ScannerEnabled);

    % IMPORTANT: rack_slots is PER ENABLED SCANNER. Disabled scanners do not
    % contribute to available fleet capacity.
    Total_Scanner_Rack_Slots_Available = ...
        nActiveScanners * Scanner_RackQueueSize;

    assert(Total_Scanner_Rack_Slots_Available == ...
           nnz(ScannerEnabled) * Scanner_RackQueueSize, ...
        'Enabled-fleet capacity calculation is inconsistent.');

    sim_days     = S(testIdx).sim_days;
    drain_hrs    = S(testIdx).drain_hrs;
    stop_time    = sim_days*24 + drain_hrs;
    tech_start   = S(testIdx).tech_start;
    tech_end     = S(testIdx).tech_end;
    check_min_hr = S(testIdx).check_min;
    check_max_hr = S(testIdx).check_max;

    %% --------------------------------------------------------------------
    % Technician on-duty schedule
    % ---------------------------------------------------------------------

    on_times  = 0;
    on_values = false;

    for d = 0:(sim_days-1)
        on_times  = [on_times; d*24 + tech_start; d*24 + tech_end]; %#ok<AGROW>
        on_values = [on_values; true; false]; %#ok<AGROW>
    end

    on_times  = [on_times; stop_time];
    on_values = [on_values; false];

    on_duty_ts = timeseries(on_values, on_times);
    on_duty_ts = setinterpmethod(on_duty_ts, 'zoh');

    %% --------------------------------------------------------------------
    % Stochastic technician check-toggle schedule
    % ---------------------------------------------------------------------

    check_times = [];

    for d = 0:(sim_days-1)
        t     = d*24 + tech_start;
        t_end = d*24 + tech_end;

        while true
            dt = check_min_hr + (check_max_hr-check_min_hr)*rand;
            t  = t + dt;

            if t >= t_end
                break;
            end

            check_times(end+1,1) = t; %#ok<AGROW>
        end
    end

    check_ts_times  = [0; check_times; stop_time];
    check_ts_values = false(size(check_ts_times));
    toggle_state    = false;

    for k = 1:numel(check_times)
        toggle_state = ~toggle_state;
        check_ts_values(k+1) = toggle_state;
    end

    check_ts_values(end) = toggle_state;

    check_toggle_ts = timeseries(check_ts_values, check_ts_times);
    check_toggle_ts = setinterpmethod(check_toggle_ts, 'zoh');

    %% --------------------------------------------------------------------
    % Fresh model instances
    % ---------------------------------------------------------------------

    local_close_if_loaded(modelName);
    local_close_if_loaded(bankName);
    local_close_if_loaded(scannerName);

    load_system(modelFile);
    load_system(bankFile);
    load_system(scannerFile);

    % ScannerEnabled is the single source of truth for both routing and gate
    % configuration. Apply the vector to ScannerGate1..6 in memory.
    local_apply_scanner_enable(bankName, ScannerEnabled);

    set_param(modelName, 'FastRestart', 'off');

    %% --------------------------------------------------------------------
    % Temporary top-level instrumentation
    % ---------------------------------------------------------------------
    % ScannerBank already contains persistent To Workspace blocks for all
    % fleet and per-scanner diagnostics. Only the top-level LoadingQueue.n
    % and public free_scan_slots signals need temporary loggers here.

    % Top-level LoadingQueue.n
    local_add_logger( ...
        modelName, ...
        'VAL_LoadingQueue_n', ...
        'LoadingQueue_n_multi', ...
        [modelName '/LoadingQueue'], 1, ...
        [1150 850 1280 880]);

    % ScannerBank public free_scan_slots output.
    local_add_logger( ...
        modelName, ...
        'VAL_FreeSlotsTop', ...
        'free_scan_slots_top', ...
        [modelName '/ScannerBank'], 1, ...
        [1850 850 1980 880]);

    %% --------------------------------------------------------------------
    % Run
    % ---------------------------------------------------------------------

    fprintf('\n------------------------------------------------------------\n');
    fprintf('TEST %d/%d: %s\n', testIdx, nTests, S(testIdx).name);
    fprintf('------------------------------------------------------------\n');
    fprintf('Stop time:                    %.1f hr\n', stop_time);
    fprintf('Test rack size:               %d slides\n', TestRack_SlideCount);
    fprintf('Rack arrival interval:        %.1f min\n', ...
        TestRack_IntergenerationTime*60);
    fprintf('Technician coverage:          %04.1f-%04.1f\n', ...
        tech_start, tech_end);
    fprintf('Scheduled checks:             %d\n', numel(check_times));
    fprintf('Enabled scanners:             %d / %d\n', nActiveScanners, nScanners);
    fprintf('ScannerEnabled:               %s\n', mat2str(double(ScannerEnabled)));
    fprintf('Waiting slots/scanner:        %d\n', Scanner_RackQueueSize);
    fprintf('Fleet waiting-slot capacity:  %d\n', ...
        Total_Scanner_Rack_Slots_Available);
    fprintf('Rerack time/scanner:          %.1f min/rack\n', ...
        Scanner_RerackTime*60);
    fprintf('Load/unload time/scanner:     %.1f min/rack\n', ...
        Scanner_RackLoadTime*60);

    simOut = sim(modelName, 'StopTime', num2str(stop_time));

    %% --------------------------------------------------------------------
    % Retrieve logs
    % ---------------------------------------------------------------------

    loadQLog       = getSimVar(simOut, 'LoadingQueue_n_multi');
    freeTopLog     = getSimVar(simOut, 'free_scan_slots_top');
    selectedLog    = getSimVar(simOut, 'selected_scanner');
    toggleLog      = getSimVar(simOut, 'scanner_select_change');
    messageLog     = getSimVarAllowEmpty(simOut, 'selected_scanner_message');
    messageStatusLog = getSimVarAllowEmpty(simOut, 'selected_scanner_message_status');
    totalScanQLog  = getSimVar(simOut, 'total_scanner_queue_n');
    freeBankLog    = getSimVar(simOut, 'free_scan_slots_bank');

    qLogs      = cell(nScanners,1);
    busyLogs   = cell(nScanners,1);
    slideQLogs = cell(nScanners,1);
    slideLogs  = cell(nScanners,1);
    rackLogs   = cell(nScanners,1);

    for i = 1:nScanners
        qLogs{i}      = getSimVar(simOut, sprintf('S%d_QueueN', i));
        busyLogs{i}   = getSimVar(simOut, sprintf('S%d_ScannerBusy', i));
        slideQLogs{i} = getSimVar(simOut, sprintf('S%d_SlideQueueN', i));
        slideLogs{i}  = getSimVar(simOut, sprintf('S%d_Slides', i));
        rackLogs{i}   = getSimVar(simOut, sprintf('S%d_Racks', i));
    end

    %% --------------------------------------------------------------------
    % Queue / fleet-capacity / free-slot invariants
    % ---------------------------------------------------------------------
    % IMPORTANT:
    % Do not compare independently logged SimEvents statistics point-by-point
    % at identical timestamps. Multiple ordered microsteps can occur at the same
    % simulation time, and To Workspace logs do not preserve that ordering.
    %
    % Instead, validate:
    %   1) each physical ScannerQueue stays within its configured local capacity;
    %   2) fleetQueueN itself stays within the enabled-fleet capacity;
    %   3) both free_scan_slots signals stay within 0..capacity;
    %   4) extrema obey the algebra implied by the statically audited wiring:
    %          max(fleetQueueN) + min(free_scan_slots) == capacity
    %          min(fleetQueueN) + max(free_scan_slots) == capacity
    %
    % The static architecture audit above separately proves that ChooseScanner's
    % fleetQueueN drives the negative input of ComputeFreeScannerSlots and the
    % enabled-fleet capacity constant drives its positive input.

    perScannerMaxQ = zeros(1,nScanners);
    individualCapacityOK = true;

    for i = 1:nScanners
        q = double(dataVector(qLogs{i}));

        if isempty(q)
            perScannerMaxQ(i) = 0;
        else
            perScannerMaxQ(i) = max(q);
        end

        individualCapacityOK = individualCapacityOK && ...
            (isempty(q) || ...
             (all(isfinite(q)) && ...
              all(abs(q - round(q)) < 1e-9) && ...
              all(q >= 0) && ...
              all(q <= Scanner_RackQueueSize)));
    end

    fleetData    = double(dataVector(totalScanQLog));
    freeBankData = double(dataVector(freeBankLog));
    freeTopData  = double(dataVector(freeTopLog));

    fleetSignalOK = ~isempty(fleetData) && ...
        all(isfinite(fleetData)) && ...
        all(abs(fleetData - round(fleetData)) < 1e-9) && ...
        all(fleetData >= 0) && ...
        all(fleetData <= Total_Scanner_Rack_Slots_Available);

    freeSignalOK = ~isempty(freeBankData) && ~isempty(freeTopData) && ...
        all(isfinite(freeBankData)) && all(isfinite(freeTopData)) && ...
        all(abs(freeBankData - round(freeBankData)) < 1e-9) && ...
        all(abs(freeTopData  - round(freeTopData))  < 1e-9) && ...
        all(freeBankData >= 0) && ...
        all(freeBankData <= Total_Scanner_Rack_Slots_Available) && ...
        all(freeTopData >= 0) && ...
        all(freeTopData <= Total_Scanner_Rack_Slots_Available);

    fleetMin = safeMin(fleetData);
    fleetMax = safeMax(fleetData);
    freeBankMin = safeMin(freeBankData);
    freeBankMax = safeMax(freeBankData);
    freeTopMin  = safeMin(freeTopData);
    freeTopMax  = safeMax(freeTopData);

    capacityComplementOK = fleetSignalOK && freeSignalOK && ...
        abs((fleetMax + freeBankMin) - Total_Scanner_Rack_Slots_Available) < 1e-9 && ...
        abs((fleetMin + freeBankMax) - Total_Scanner_Rack_Slots_Available) < 1e-9 && ...
        abs(freeTopMin - freeBankMin) < 1e-9 && ...
        abs(freeTopMax - freeBankMax) < 1e-9;

    %% --------------------------------------------------------------------
    % Monotonic cumulative counters / per-scanner throughput
    % ---------------------------------------------------------------------

    perScannerRacks  = zeros(1,nScanners);
    perScannerSlides = zeros(1,nScanners);
    countersOK = true;

    for i = 1:nScanners

        rackData  = double(dataVector(rackLogs{i}));
        slideData = double(dataVector(slideLogs{i}));

        perScannerRacks(i)  = finalCount(rackLogs{i});
        perScannerSlides(i) = finalCount(slideLogs{i});

        % Empty cumulative logs are valid for an idle scanner: zero racks
        % and zero slides completed for the entire simulation.
        countersOK = countersOK && ...
            isNonnegativeMonotonicOrEmpty(rackData) && ...
            isNonnegativeMonotonicOrEmpty(slideData);
    end

    racksCompleted  = sum(perScannerRacks);
    slidesCompleted = sum(perScannerSlides);
    scannersUsed    = nnz(perScannerRacks > 0 | perScannerSlides > 0);

    % Local SlideQueue is configured for one waiting slide in this bench.
    perScannerMaxSlideQ = zeros(1,nScanners);
    slideQueueOK = true;

    for i = 1:nScanners
        sq = double(dataVector(slideQLogs{i}));

        if isempty(sq)
            % Unused scanner: SlideQueue occupancy stayed at zero.
            perScannerMaxSlideQ(i) = 0;
        else
            perScannerMaxSlideQ(i) = max(sq);
        end

        slideQueueOK = slideQueueOK && ...
            (isempty(sq) || ...
             (all(sq >= 0) && all(sq <= Scanner_SlideQueueSize)));
    end

    countersOK = countersOK && slideQueueOK;

    % scanner_busy is both a diagnostic and a v1.2 routing input. It must
    % remain binary and should assert at least once on any scanner that
    % completes work during the test.
    perScannerBusySeen = false(1,nScanners);
    busySignalsOK = true;

    for i = 1:nScanners
        b = double(dataVector(busyLogs{i}));

        if isempty(b)
            perScannerBusySeen(i) = false;
        else
            busySignalsOK = busySignalsOK && ...
                all((abs(b) < 1e-9) | (abs(b - 1) < 1e-9));
            perScannerBusySeen(i) = any(b > 0.5);
        end
    end

    usedMask = (perScannerRacks > 0 | perScannerSlides > 0);
    busySignalsOK = busySignalsOK && ...
        all(~usedMask | perScannerBusySeen);

    % Every current stress scenario deliberately contains enough work to
    % exercise every enabled scanner. This is a robust physical-routing check.
    enabledUseOK = all(usedMask(ScannerEnabled));

    % In deterministic heavy-backlog scenarios, identical enabled scanners
    % should receive nearly equal numbers of completed racks. The sparse-supply
    % scenario deliberately disables this criterion with balance_tol = Inf.
    enabledRacks = perScannerRacks(ScannerEnabled);
    if isempty(enabledRacks)
        balanceSpread = NaN;
        balanceOK = false;
    else
        balanceSpread = max(enabledRacks) - min(enabledRacks);
        balanceOK = balanceSpread <= S(testIdx).balance_tol;
    end

    %% --------------------------------------------------------------------
    % v1.2 routing / enabled-fleet invariants
    % ---------------------------------------------------------------------

    selectedData = double(dataVector(selectedLog));

    selectionValuesOK = ~isempty(selectedData) && ...
        all(isfinite(selectedData)) && ...
        all(abs(selectedData - round(selectedData)) < 1e-9) && ...
        all(selectedData >= 1) && ...
        all(selectedData <= nScanners);

    if selectionValuesOK
        selectedIdx = round(selectedData);
        selectionEnabledOK = all(ScannerEnabled(selectedIdx));
    else
        selectionEnabledOK = false;
    end

    selectionOK = selectionValuesOK && selectionEnabledOK;

    % Validate the selectedPort -> SelectionEventToggle -> MessageTrigger ->
    % Message Send -> Entity Replicator -> MessageReceive path independently
    % of physical rack routing. The toggle flips on every selectedPort change,
    % MessageTrigger fires on either edge, and receive status identifies the
    % exact samples on which a diagnostic message was actually consumed.
    [toggleSignalOK, messagePathOK, expectedMessages, observedMessages, ...
        toggleEdges, firstMessageMismatch, expectedMessageSeq, observedMessageSeq] = ...
        validateSelectionMessagePath(selectedLog, toggleLog, messageLog, ...
                                     messageStatusLog, nScanners);

    disabledMask = ~ScannerEnabled;

    if any(disabledMask)
        disabledIdleOK = ...
            all(perScannerMaxQ(disabledMask) == 0) && ...
            all(perScannerMaxSlideQ(disabledMask) == 0) && ...
            all(~perScannerBusySeen(disabledMask)) && ...
            all(perScannerRacks(disabledMask) == 0) && ...
            all(perScannerSlides(disabledMask) == 0);
    else
        disabledIdleOK = true;
    end

    %% --------------------------------------------------------------------
    % Summary metrics
    % ---------------------------------------------------------------------

    loadQ = double(dataVector(loadQLog));

    maxLoadQ      = safeMax(loadQ);
    maxFleetScanQ = safeMax(fleetData);
    minFreeSlots  = safeMin(freeTopData);
    maxFreeSlots  = safeMax(freeTopData);

    testPass = individualCapacityOK && ...
               fleetSignalOK && ...
               freeSignalOK && ...
               capacityComplementOK && ...
               countersOK && ...
               busySignalsOK && ...
               selectionOK && ...
               toggleSignalOK && ...
               messagePathOK && ...
               enabledUseOK && ...
               balanceOK && ...
               disabledIdleOK;

    %% --------------------------------------------------------------------
    % Report
    % ---------------------------------------------------------------------

    fprintf('\nFleet admission / capacity:\n');
    fprintf('  LoadingQueue max:                 %.0f\n', maxLoadQ);
    fprintf('  Fleet waiting-slot capacity:      %d\n', ...
        Total_Scanner_Rack_Slots_Available);
    fprintf('  Fleet ScannerQueue max:           %.0f\n', maxFleetScanQ);
    fprintf('  free_scan_slots min/max:          %.0f / %.0f\n', ...
        minFreeSlots, maxFreeSlots);

    fprintf('  %s\n', passfail(individualCapacityOK, ...
        'PASS: every ScannerQueue stayed within its local capacity.', ...
        'FAIL: one or more ScannerQueues exceeded local capacity.'));

    fprintf('  %s\n', passfail(fleetSignalOK, ...
        'PASS: logged fleetQueueN stayed within enabled-fleet capacity.', ...
        'FAIL: logged fleetQueueN was invalid or exceeded enabled-fleet capacity.'));

    fprintf('  %s\n', passfail(freeSignalOK, ...
        'PASS: bank and top-level free_scan_slots stayed within 0..fleet capacity.', ...
        'FAIL: a free_scan_slots signal was invalid or outside 0..fleet capacity.'));

    fprintf('  %s\n', passfail(capacityComplementOK, ...
        'PASS: fleetQueueN/free_scan_slots extrema satisfy capacity complement arithmetic.', ...
        'FAIL: fleetQueueN/free_scan_slots extrema do not satisfy capacity complement arithmetic.'));

    fprintf('\nPer-scanner behavior:\n');
    fprintf('  Scanner   MaxRackQ   MaxSlideQ   BusySeen   RacksDone   SlidesDone\n');
    fprintf('  -------   --------   ---------   --------   ---------   ----------\n');

    for i = 1:nScanners
        fprintf('     %d       %5.0f       %5.0f       %3s       %5.0f       %6.0f\n', ...
            i, perScannerMaxQ(i), perScannerMaxSlideQ(i), ...
            yesno(perScannerBusySeen(i)), ...
            perScannerRacks(i), perScannerSlides(i));
    end

    fprintf('\nFleet throughput diagnostics:\n');
    fprintf('  Scanners used:                    %d / %d\n', ...
        scannersUsed, nScanners);
    fprintf('  Original racks at RackSink:       %.0f\n', racksCompleted);
    fprintf('  Slides completed:                 %.0f\n', slidesCompleted);

    fprintf('  %s\n', passfail(countersOK, ...
        'PASS: cumulative rack/slide counters are nonnegative and monotonic.', ...
        'FAIL: a cumulative rack/slide counter decreased or went negative.'));

    fprintf('  %s\n', passfail(busySignalsOK, ...
        ['PASS: scanner_busy signals are Boolean and asserted on every ' ...
         'scanner that completed work.'], ...
        ['FAIL: scanner_busy was non-Boolean or never asserted on a ' ...
         'scanner that completed work.']));

    fprintf('\nRouter / enabled-fleet diagnostics:\n');
    fprintf('  %s\n', passfail(selectionOK, ...
        'PASS: selected_scanner remained in 1..6 and always selected an enabled scanner.', ...
        'FAIL: selected_scanner was invalid or selected a disabled scanner.'));

    if isfinite(S(testIdx).balance_tol)
        fprintf('  Rack-count spread across enabled scanners: %d (allowed <= %.0f)\n', ...
            balanceSpread, S(testIdx).balance_tol);
        fprintf('  %s\n', passfail(balanceOK, ...
            'PASS: deterministic stress workload was distributed across enabled scanners as expected.', ...
            'FAIL: deterministic stress workload was not distributed across enabled scanners as expected.'));
    else
        fprintf('  Rack-count spread across enabled scanners: %d (informational; sparse-supply case)\n', ...
            balanceSpread);
        fprintf('  PASS: strict rack-count balance intentionally not required for sparse supply.\n');
    end

    fprintf('\nRouter control-message diagnostics:\n');
    fprintf('  selected_scanner transitions expected: %d\n', expectedMessages);
    fprintf('  SelectionEventToggle edges:             %d\n', toggleEdges);
    fprintf('  Message Receive status events:          %d\n', observedMessages);

    fprintf('  %s\n', passfail(toggleSignalOK, ...
        'PASS: SelectionEventToggle produced one edge per selected_scanner transition.', ...
        'FAIL: SelectionEventToggle edge count does not match selected_scanner transitions.'));

    if messagePathOK
        fprintf('  PASS: Message Receive payload sequence exactly matches selected_scanner transitions.\n');
    else
        fprintf('  FAIL: Message Receive payload sequence does not match selected_scanner transitions.\n');
        if firstMessageMismatch > 0
            fprintf('        First payload mismatch at message %d.\n', firstMessageMismatch);
        end
        fprintf('        Expected first values: %s\n', ...
            local_sequence_preview(expectedMessageSeq, 20));
        fprintf('        Observed first values: %s\n', ...
            local_sequence_preview(observedMessageSeq, 20));
    end

    fprintf('  %s\n', passfail(enabledUseOK, ...
        'PASS: every enabled scanner processed work in this stress scenario.', ...
        'FAIL: one or more enabled scanners were never exercised.'));

    fprintf('  %s\n', passfail(disabledIdleOK, ...
        'PASS: disabled scanners remained completely idle.', ...
        'FAIL: one or more disabled scanners queued or processed work.'));

    fprintf('\nOverall test: %s\n', ...
        passfail(testPass, 'PASS', 'FAIL'));

    %% --------------------------------------------------------------------
    % Store
    % ---------------------------------------------------------------------

    results(testIdx).Name                 = S(testIdx).name;
    results(testIdx).Checks               = numel(check_times);
    results(testIdx).EnabledCount         = nActiveScanners;
    results(testIdx).FleetCapacity        = Total_Scanner_Rack_Slots_Available;
    results(testIdx).MaxLoadQ             = maxLoadQ;
    results(testIdx).MaxFleetScanQ        = maxFleetScanQ;
    results(testIdx).MinFreeSlots         = minFreeSlots;
    results(testIdx).MaxFreeSlots         = maxFreeSlots;
    results(testIdx).RacksCompleted       = racksCompleted;
    results(testIdx).SlidesCompleted      = slidesCompleted;
    results(testIdx).ScannersUsed         = scannersUsed;
    results(testIdx).IndividualCapacityOK  = individualCapacityOK;
    results(testIdx).FleetSignalOK          = fleetSignalOK;
    results(testIdx).FreeSignalOK           = freeSignalOK;
    results(testIdx).CapacityComplementOK   = capacityComplementOK;
    results(testIdx).CountersOK             = countersOK;
    results(testIdx).BusySignalsOK          = busySignalsOK;
    results(testIdx).SelectionOK            = selectionOK;
    results(testIdx).ToggleSignalOK         = toggleSignalOK;
    results(testIdx).MessagePathOK         = messagePathOK;
    results(testIdx).ExpectedMessages      = expectedMessages;
    results(testIdx).ObservedMessages      = observedMessages;
    results(testIdx).EnabledUseOK          = enabledUseOK;
    results(testIdx).BalanceOK             = balanceOK;
    results(testIdx).BalanceSpread         = balanceSpread;
    results(testIdx).DisabledIdleOK        = disabledIdleOK;
    results(testIdx).Pass                  = testPass;
    results(testIdx).ScannerEnabled        = ScannerEnabled;
    results(testIdx).PerScannerMaxQ        = perScannerMaxQ;
    results(testIdx).PerScannerBusySeen    = perScannerBusySeen;
    results(testIdx).PerScannerRacks       = perScannerRacks;
    results(testIdx).PerScannerSlides      = perScannerSlides;

    % Preserve final-test logs/arrays for interactive inspection.
    if testIdx == nTests
        Final_LoadingQueue_n       = loadQLog;
        Final_SelectedScanner      = selectedLog;
        Final_SelectionEventToggle    = toggleLog;
        Final_ScannerSelectChange      = toggleLog; % compatibility alias
        Final_SelectedScannerMessage   = messageLog;
        Final_SelectedScannerMessageStatus = messageStatusLog;
        Final_TotalScannerQueue_n  = totalScanQLog;
        Final_FreeSlots            = freeTopLog;
        Final_PerScannerQueue      = qLogs;
        Final_PerScannerBusy       = busyLogs;
        Final_PerScannerSlideQueue = slideQLogs;
        Final_PerScannerSlides     = slideLogs;
        Final_PerScannerRacks      = rackLogs;
    end

    % Do not save temporary validation logging blocks.
    local_close_if_loaded(modelName);
    local_close_if_loaded(bankName);
    local_close_if_loaded(scannerName);
end

%% ========================================================================
% FINAL SUMMARY
% ==========================================================================

fprintf('\n============================================================\n');
fprintf(' MULTI-SCANNER STRESS TEST SUMMARY\n');
fprintf('============================================================\n');

fprintf('%-42s %6s %5s %7s %7s %7s %7s %7s %6s\n', ...
    'Scenario','Checks','Act','Cap','MaxQ','Racks','Slides','Used','Pass');
fprintf('%s\n', repmat('-',1,110));

for k = 1:nTests
    fprintf('%-42s %6d %5d %7d %7.0f %7.0f %7.0f %7d %6s\n', ...
        results(k).Name, ...
        results(k).Checks, ...
        results(k).EnabledCount, ...
        results(k).FleetCapacity, ...
        results(k).MaxFleetScanQ, ...
        results(k).RacksCompleted, ...
        results(k).SlidesCompleted, ...
        results(k).ScannersUsed, ...
        yesno(results(k).Pass));
end

fprintf('============================================================\n');

if all([results.Pass])
    fprintf('ALL TESTS PASS.\n');
    fprintf(['v1.2 routing, enabled-fleet capacity, gate enforcement, direct signal ' ...
             'range/complement checks, per-scanner counters, scanner_busy, ' ...
             'selected_scanner eligibility, enabled/disabled fleet behavior, physical ' ...
             'load distribution, and exact toggle/message propagation passed.\n']);
else
    fprintf('ONE OR MORE TESTS FAILED -- inspect the scenario output above.\n');
end

fprintf('============================================================\n');

%% ========================================================================
% LOCAL HELPERS
% ==========================================================================

function local_close_if_loaded(modelName)
    if bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
end


function local_apply_scanner_enable(bankName, enabled)
% Apply the v1.2 ScannerEnabled vector to ScannerGate1..6 in memory.

    enabled = logical(enabled(:).');

    assert(numel(enabled) == 6, ...
        'ScannerEnabled must contain exactly six elements.');
    assert(enabled(1), ...
        'v1.2 design rule: Scanner 1 must always be enabled.');

    for i = 1:6
        gatePath = sprintf('%s/ScannerGate%d', bankName, i);

        if enabled(i)
            desired = 'on';
        else
            desired = 'off';
        end

        set_param(gatePath, 'OpenGateAtSimulationStart', desired);

        assert(strcmpi(get_param(gatePath, 'OpenGateAtSimulationStart'), desired), ...
            'ScannerGate%d did not accept the requested enabled state.', i);
    end
end


function path = local_find_one(modelName, varargin)
    hits = find_system(modelName, ...
        'SearchDepth', 1, ...
        'LookUnderMasks', 'all', ...
        'FollowLinks', 'on', ...
        varargin{:});

    assert(numel(hits) == 1, ...
        'Expected exactly one matching block in %s; found %d.', ...
        modelName, numel(hits));

    path = hits{1};
end


function tf = local_port_drives_block(sourceBlock, sourcePortIndex, destBlock)
% Return true if the requested source output has a branch to destBlock.

    tf = false;
    srcPH = get_param(sourceBlock, 'PortHandles');

    if numel(srcPH.Outport) < sourcePortIndex
        return;
    end

    lh = get_param(srcPH.Outport(sourcePortIndex), 'Line');
    if lh == -1
        return;
    end

    dstHandles = get_param(lh, 'DstPortHandle');
    if isempty(dstHandles)
        return;
    end

    dstHandles = dstHandles(dstHandles ~= -1);
    for k = 1:numel(dstHandles)
        if strcmp(get_param(dstHandles(k), 'Parent'), destBlock)
            tf = true;
            return;
        end
    end
end


function tf = local_port_drives_port( ...
    sourceBlock, sourcePortIndex, destBlock, destPortIndex)
% Return true only if a specific source output drives a specific destination
% input port. Useful when Sum block sign/order is part of the architecture.

    tf = false;

    srcPH = get_param(sourceBlock, 'PortHandles');
    dstPH = get_param(destBlock, 'PortHandles');

    if numel(srcPH.Outport) < sourcePortIndex || ...
       numel(dstPH.Inport) < destPortIndex
        return;
    end

    lh = get_param(srcPH.Outport(sourcePortIndex), 'Line');
    if lh == -1
        return;
    end

    dstHandles = get_param(lh, 'DstPortHandle');
    if isempty(dstHandles)
        return;
    end

    dstHandles = dstHandles(dstHandles ~= -1);
    tf = any(dstHandles == dstPH.Inport(destPortIndex));
end


function local_assert_workspace_var(parentModel, variableName)
% Verify exactly one persistent To Workspace block publishes variableName.

    hits = find_system(parentModel, ...
        'LookUnderMasks', 'all', ...
        'FollowLinks', 'on', ...
        'BlockType', 'ToWorkspace', ...
        'VariableName', variableName);

    assert(numel(hits) == 1, ...
        'Expected exactly one To Workspace block for %s; found %d.', ...
        variableName, numel(hits));

    assert(strcmpi(get_param(hits{1}, 'SaveFormat'), 'Timeseries'), ...
        'Workspace variable %s is not logged as Timeseries.', variableName);
end


function local_add_logger(parentModel, blockName, variableName, ...
                          sourceBlock, sourcePortIndex, position)
% Add a temporary To Workspace logger and branch it from an existing signal.

    loggerPath = [parentModel '/' blockName];

    if getSimulinkBlockHandle(loggerPath) ~= -1
        ph = get_param(loggerPath, 'PortHandles');

        if ~isempty(ph.Inport)
            lh = get_param(ph.Inport(1), 'Line');
            if lh ~= -1
                delete_line(lh);
            end
        end

        delete_block(loggerPath);
    end

    add_block('simulink/Sinks/To Workspace', loggerPath, ...
        'VariableName', variableName, ...
        'SaveFormat', 'Timeseries', ...
        'Position', position);

    srcPH = get_param(sourceBlock, 'PortHandles');
    dstPH = get_param(loggerPath, 'PortHandles');

    assert(numel(srcPH.Outport) >= sourcePortIndex, ...
        'Source %s does not have output port %d.', ...
        sourceBlock, sourcePortIndex);

    add_line(parentModel, ...
        srcPH.Outport(sourcePortIndex), ...
        dstPH.Inport(1), ...
        'autorouting', 'on');
end


function [toggleOK, messageOK, nExpected, nObserved, nToggleEdges, ...
          firstMismatch, expectedSeq, observedSeq] = ...
          validateSelectionMessagePath(selectedLog, toggleLog, messageLog, ...
                                       messageStatusLog, nScanners)
% Validate the router's signal-to-message conversion path.
%
% SelectionEventToggle starts at 0 and flips state whenever selectedPort
% changes. MessageTrigger is configured for EITHER edge, so every toggle edge
% should execute SwitchSelectMess exactly once. MessageReceive is configured
% to output 0 when its queue is empty; its receive-status output is therefore
% the authoritative marker for actual message-consumption events.

    selected = double(dataVector(selectedLog));
    toggle   = double(dataVector(toggleLog));

    % Reconstruct expected payloads directly from selected_scanner.
    expectedSeq = zeros(0,1);
    previous = 1;

    for k = 1:numel(selected)
        v = selected(k);
        if ~isfinite(v)
            continue;
        end
        v = round(v);
        if v ~= previous
            expectedSeq(end+1,1) = v; %#ok<AGROW>
            previous = v;
        end
    end

    nExpected = numel(expectedSeq);

    % Toggle must remain binary and change state once per selection change.
    % Its modeled initial state is 0.
    toggleFinite = toggle(isfinite(toggle));
    toggleBoolean = all((abs(toggleFinite) < 1e-9) | ...
                        (abs(toggleFinite - 1) < 1e-9));
    toggleHigh = toggleFinite > 0.5;

    if isempty(toggleHigh)
        nToggleEdges = 0;
    else
        previousHigh = [false; toggleHigh(1:end-1)];
        nToggleEdges = nnz(toggleHigh ~= previousHigh);
    end

    toggleOK = toggleBoolean && (nToggleEdges == nExpected);

    % Data and receive status come from the same MessageReceive block and
    % should have identical logging time bases. Never infer message events from
    % nonzero data alone; status is the authoritative event marker.
    [tMsg, vMsg] = tsTimeData(messageLog);
    [tStatus, vStatus] = tsTimeData(messageStatusLog);

    tMsg    = double(tMsg(:));
    vMsg    = double(vMsg(:));
    tStatus = double(tStatus(:));
    vStatus = double(vStatus(:));

    logsAligned = numel(tMsg) == numel(tStatus) && ...
                  numel(vMsg) == numel(vStatus) && ...
                  (isempty(tMsg) || all(abs(tMsg - tStatus) < 1e-12));

    statusFinite = vStatus(isfinite(vStatus));
    statusBoolean = all((abs(statusFinite) < 1e-9) | ...
                        (abs(statusFinite - 1) < 1e-9));

    observedSeq = zeros(0,1);
    receiveDataOK = false;

    if logsAligned && statusBoolean
        received = vStatus > 0.5;
        idle     = ~received;

        receivedValuesOK = all(isfinite(vMsg(received))) && ...
            all(abs(vMsg(received) - round(vMsg(received))) < 1e-9) && ...
            all(vMsg(received) >= 1 & vMsg(received) <= nScanners);

        % MessageReceive is configured with Initial value=0 and
        % Use initial value when queue is empty.
        idleValuesOK = all(~isfinite(vMsg(idle)) | abs(vMsg(idle)) < 1e-9);

        observedSeq = round(vMsg(received));
        receiveDataOK = receivedValuesOK && idleValuesOK;
    end

    nObserved = numel(observedSeq);

    firstMismatch = 0;
    nCommon = min(nExpected, nObserved);
    for k = 1:nCommon
        if expectedSeq(k) ~= observedSeq(k)
            firstMismatch = k;
            break;
        end
    end

    if firstMismatch == 0 && nExpected ~= nObserved
        firstMismatch = nCommon + 1;
    end

    messageOK = logsAligned && statusBoolean && receiveDataOK && ...
                (nExpected == nObserved) && ...
                isequal(expectedSeq, observedSeq);
end


function s = local_sequence_preview(v, nMax)
% Compact printable preview for message-payload diagnostics.

    v = double(v(:).');
    if isempty(v)
        s = '[]';
        return;
    end

    nShow = min(numel(v), nMax);
    s = mat2str(v(1:nShow));
    if numel(v) > nShow
        s = sprintf('%s ... (%d total)', s, numel(v));
    end
end


function v = dataVector(x)
    if isempty(x)
        v = [];
    elseif isa(x, 'timeseries')
        v = x.Data(:);
    elseif isstruct(x) && isfield(x, 'signals')
        v = x.signals.values(:);
    else
        v = x(:);
    end
end


function x = getSimVar(simOut, name)
    try
        x = simOut.get(name);
    catch
        x = simOut.(name);
    end

    if isempty(x)
        error('Required simulation log "%s" is missing or empty.', name);
    end
end


function x = getSimVarAllowEmpty(simOut, name)
% Retrieve a simulation variable but allow an empty value. This is useful
% for message-path diagnostics where zero observed messages is itself a
% meaningful failure mode rather than a reason to abort the test harness.

    try
        x = simOut.get(name);
    catch
        try
            x = simOut.(name);
        catch
            error('Required simulation output "%s" was not found.', name);
        end
    end
end


function n = finalCount(x)
    v = double(dataVector(x));

    if isempty(v)
        n = 0;
    else
        n = round(v(end));
    end
end


function tf = isNonnegativeMonotonic(v)
    if isempty(v)
        tf = false;
        return;
    end

    v = double(v(:));
    tf = all(v >= 0) && all(diff(v) >= -1e-9);
end


function tf = isNonnegativeMonotonicOrEmpty(v)
% Empty cumulative counter is valid for an unused scanner and means zero.
    if isempty(v)
        tf = true;
        return;
    end

    v = double(v(:));
    tf = all(v >= 0) && all(diff(v) >= -1e-9);
end


function m = safeMax(v)
    if isempty(v)
        m = NaN;
    else
        m = max(v);
    end
end


function m = safeMin(v)
    if isempty(v)
        m = NaN;
    else
        m = min(v);
    end
end


function [t, v] = tsTimeData(x)
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
        error('Expected a timeseries or Structure With Time logging format.');
    end
end


function out = yesno(tf)
    if tf
        out = 'YES';
    else
        out = 'NO';
    end
end


function out = passfail(tf, passText, failText)
    if tf
        out = passText;
    else
        out = failText;
    end
end
