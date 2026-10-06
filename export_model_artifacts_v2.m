% export_model_artifacts_v2.m
% Export static PNG/PDF diagrams and an interactive Simulink Web View.
%
% Run this script from the folder containing:
%   Slide_Model.slx
%   ScannerBank.slx
%   GenericScanner.slx
%
% Output:
%   model_artifacts/
%       png/
%           Slide_Model.png
%           ScannerBank.png
%           GenericScanner.png
%       pdf/
%           Slide_Model.pdf
%           ScannerBank.pdf
%           GenericScanner.pdf
%       web/
%           Slide_Model_WebView/
%               webview.html
%               ...
%
% Notes:
%   - PNG is useful for quick viewing / poster placement.
%   - PDF is preferred when you want scalable/vector-quality output.
%   - Web View generation requires slwebview (Simulink Report Generator).
%   - This script does not intentionally save or modify the SLX files.

clearvars -except ans
clc

% =========================================================================
% USER SETTINGS
% =========================================================================

models = {'Slide_Model','ScannerBank','GenericScanner'};

topModel        = 'Slide_Model';
artifactRoot    = fullfile(pwd,'model_artifacts');

EXPORT_PNG      = true;
EXPORT_PDF      = true;
EXPORT_WEBVIEW  = true;

% Web View settings
WEB_PACKAGE_NAME       = 'Slide_Model_WebView';
WEB_LOOK_UNDER_MASKS   = 'none';  % 'none' keeps the web view readable.
                                   % Change to 'all' if you want masked
                                   % block internals included.
WEB_FOLLOW_LINKS       = false;   % Avoid pulling library internals into view.
WEB_FOLLOW_MODEL_REF   = true;
WEB_FOLLOW_SUBSYS_REF  = true;    % Important for ScannerBank/GenericScanner.
WEB_OPEN_AFTER_EXPORT  = false;

% =========================================================================
% OUTPUT DIRECTORIES
% =========================================================================

pngDir = fullfile(artifactRoot,'png');
pdfDir = fullfile(artifactRoot,'pdf');
webDir = fullfile(artifactRoot,'web');

ensureDir(artifactRoot);

if EXPORT_PNG
    ensureDir(pngDir);
end

if EXPORT_PDF
    ensureDir(pdfDir);
end

if EXPORT_WEBVIEW
    ensureDir(webDir);
end

fprintf('\n============================================================\n');
fprintf(' Export Simulink model artifacts\n');
fprintf(' Source directory : %s\n', pwd);
fprintf(' Output directory : %s\n', artifactRoot);
fprintf('============================================================\n\n');

% =========================================================================
% VERIFY MODEL FILES
% =========================================================================

for i = 1:numel(models)
    modelFile = fullfile(pwd,[models{i} '.slx']);

    if ~isfile(modelFile)
        error(['Could not find %s in the current MATLAB directory.\n' ...
               'Current directory:\n  %s'], ...
               [models{i} '.slx'], pwd);
    end
end

% =========================================================================
% STATIC EXPORTS: PNG + PDF
% =========================================================================

for i = 1:numel(models)
    mdl = models{i};
    modelFile = fullfile(pwd,[mdl '.slx']);

    fprintf('------------------------------------------------------------\n');
    fprintf('Model: %s\n', mdl);

    % Load the exact copy from the current directory if it is not loaded.
    if bdIsLoaded(mdl)
        loadedFile = get_param(mdl,'FileName');

        if ~isempty(loadedFile) && ...
                ~strcmpi(normalizePath(loadedFile),normalizePath(modelFile))
            error(['%s is already loaded from a different location:\n' ...
                   '  %s\n\nExpected:\n  %s\n\n' ...
                   'Close the other copy and rerun this script.'], ...
                   mdl, loadedFile, modelFile);
        end
    else
        load_system(modelFile);
    end

    % ---------------------------------------------------------------------
    % PNG
    % ---------------------------------------------------------------------
    if EXPORT_PNG
        pngFile = fullfile(pngDir,[mdl '.png']);

        try
            % Simulink print does not support the MATLAB -r### resolution
            % option. For publication-quality scaling, use the PDF export.
            print(['-s' mdl],'-dpng',pngFile);
            fprintf('  PNG : %s\n', pngFile);
        catch ME
            warning('PNG export failed for %s: %s', mdl, ME.message);
        end
    end

    % ---------------------------------------------------------------------
    % PDF
    % ---------------------------------------------------------------------
    if EXPORT_PDF
        pdfFile = fullfile(pdfDir,[mdl '.pdf']);

        try
            % -bestfit preserves the diagram aspect ratio while fitting it
            % to the PDF page.
            print(['-s' mdl],'-dpdf','-bestfit',pdfFile);
            fprintf('  PDF : %s\n', pdfFile);
        catch ME
            warning('PDF export failed for %s: %s', mdl, ME.message);
        end
    end
end

% =========================================================================
% INTERACTIVE WEB VIEW
% =========================================================================

if EXPORT_WEBVIEW
    fprintf('------------------------------------------------------------\n');
    fprintf('Web View: %s\n', topModel);

    % MathWorks functions may be distributed as .m, .p, MEX, etc.
    % Therefore do NOT require exist(...,'file') to equal exactly 2.
    % Any nonzero file result, or a path returned by WHICH, means MATLAB
    % can see slwebview.
    slwebviewExistCode = exist('slwebview','file');
    slwebviewPath = which('slwebview');

    fprintf('  slwebview exist code: %d\n', slwebviewExistCode);
    if ~isempty(slwebviewPath)
        fprintf('  slwebview path      : %s\n', slwebviewPath);
    end

    if slwebviewExistCode == 0 && isempty(slwebviewPath)
        warning(['slwebview was not found on the MATLAB path. Static PNG/PDF ' ...
                 'exports are done. If Simulink Report Generator was just ' ...
                 'installed, restart MATLAB or refresh the toolbox cache/path.']);
    else
        topModelFile = fullfile(pwd,[topModel '.slx']);

        if ~bdIsLoaded(topModel)
            load_system(topModelFile);
        end

        % Remove a prior package with the same name so the directory is a
        % clean deployable copy each time this script runs.
        webPackageDir = fullfile(webDir,WEB_PACKAGE_NAME);

        if isfolder(webPackageDir)
            fprintf('  Removing prior Web View package:\n');
            fprintf('    %s\n', webPackageDir);
            rmdir(webPackageDir,'s');
        end

        try
            webEntryFile = slwebview(topModel, ...
                'SearchScope','All', ...
                'LookUnderMasks',WEB_LOOK_UNDER_MASKS, ...
                'FollowLinks',WEB_FOLLOW_LINKS, ...
                'FollowModelReference',WEB_FOLLOW_MODEL_REF, ...
                'FollowSubsystemReference',WEB_FOLLOW_SUBSYS_REF, ...
                'PackageFolder',webDir, ...
                'PackageName',WEB_PACKAGE_NAME, ...
                'PackageType','unzipped', ...
                'ViewFile',WEB_OPEN_AFTER_EXPORT);

            fprintf('  Web View created successfully.\n');
            fprintf('  Entry file: %s\n', webEntryFile);

            % Put simple deployment instructions next to the web package.
            readmeFile = fullfile(webDir,'README_WEBVIEW.txt');
            fid = fopen(readmeFile,'w');

            if fid ~= -1
                fprintf(fid,'Slide_Model interactive Web View\n');
                fprintf(fid,'================================\n\n');
                fprintf(fid,'Open the generated webview.html file in the Web View package.\n\n');
                fprintf(fid,'Package directory:\n%s\n\n',webPackageDir);
                fprintf(fid,'Generated from:\n%s\n',topModelFile);
                fclose(fid);
            end

        catch ME
            warning(['Web View export failed.\n\n' ...
                     'Static PNG/PDF exports are still available.\n' ...
                     'Web View error:\n%s'], ME.message);
        end
    end
end

% =========================================================================
% SUMMARY
% =========================================================================

fprintf('\n============================================================\n');
fprintf('Export complete.\n\n');

if EXPORT_PNG
    fprintf('PNG directory:\n  %s\n\n', pngDir);
end

if EXPORT_PDF
    fprintf('PDF directory:\n  %s\n\n', pdfDir);
end

if EXPORT_WEBVIEW
    fprintf('Web directory:\n  %s\n\n', webDir);
    fprintf(['For a static web deployment, publish/copy the CONTENTS of the\n' ...
             'generated Web View package directory together, preserving its\n' ...
             'subdirectory structure.\n\n']);
end

fprintf('============================================================\n');


% =========================================================================
% LOCAL FUNCTIONS
% =========================================================================

function ensureDir(folderPath)
%ENSUREDIR Create a directory if it does not already exist.
    if ~exist(folderPath,'dir')
        mkdir(folderPath);
    end
end


function p = normalizePath(p)
%NORMALIZEPATH Normalize a path for comparison.
    p = char(string(p));

    if isempty(p)
        return
    end

    try
        p = char(java.io.File(p).getCanonicalPath());
    catch
        p = strrep(p,'/','\');
    end
end
