@{
    # Script module or binary module file associated with this manifest.
    RootModule = ''

    # Version number of this module.
    ModuleVersion = '0.9.9'

    # ID used to uniquely identify this module
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'

    # Author of this module
    Author = 'Ralph for Claude Code'

    # Company or vendor of this module
    CompanyName = 'Anthropic'

    # Copyright statement for this module
    Copyright = '(c) 2026 Anthropic. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'Ralph for Claude Code - An autonomous AI development loop system that enables continuous development cycles with intelligent exit detection and rate limiting.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules = @()

    # Assemblies that must be loaded prior to importing this module
    RequiredAssemblies = @()

    # Script files (.ps1) that are run in the caller's environment prior to importing this module.
    ScriptsToProcess = @()

    # Type files (.ps1xml) to be loaded when importing this module
    TypesToProcess = @()

    # Format files (.ps1xml) to be loaded when importing this module
    FormatsToProcess = @()

    # Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
    NestedModules = @(
        'lib\DateUtils.psm1',
        'lib\CircuitBreaker.psm1',
        'lib\ResponseAnalyzer.psm1'
    )

    # Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export.
    FunctionsToExport = @(
        # DateUtils
        'Get-IsoTimestamp',
        'Get-NextHourTime',
        'Get-BasicTimestamp',
        'Get-EpochSeconds',
        'ConvertFrom-IsoTimestamp',
        # CircuitBreaker
        'Initialize-CircuitBreaker',
        'Get-CircuitState',
        'Test-CanExecute',
        'Save-LoopResult',
        'Show-CircuitStatus',
        'Reset-CircuitBreaker',
        'Test-ShouldHaltExecution',
        # ResponseAnalyzer
        'Get-OutputFormat',
        'Read-JsonResponse',
        'Invoke-ResponseAnalysis',
        'Update-ExitSignals',
        'Write-AnalysisSummary',
        'Test-StuckLoop',
        'Save-SessionId',
        'Get-LastSessionId',
        'Test-ShouldResumeSession',
        'Get-SessionId',
        'Reset-Session',
        'Write-SessionTransition',
        'Initialize-SessionTracking'
    )

    # Cmdlets to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no cmdlets to export.
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @(
        'CB_STATE_CLOSED',
        'CB_STATE_HALF_OPEN',
        'CB_STATE_OPEN',
        'CB_NO_PROGRESS_THRESHOLD',
        'CB_SAME_ERROR_THRESHOLD',
        'CB_OUTPUT_DECLINE_THRESHOLD'
    )

    # Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no aliases to export.
    AliasesToExport = @()

    # DSC resources to export from this module
    DscResourcesToExport = @()

    # List of all modules packaged with this module
    ModuleList = @()

    # List of all files packaged with this module
    FileList = @(
        'Ralph.psd1',
        'ralph_loop.ps1',
        'ralph_monitor.ps1',
        'ralph_import.ps1',
        'setup.ps1',
        'Install-Ralph.ps1',
        'Uninstall-Ralph.ps1',
        'lib\DateUtils.psm1',
        'lib\CircuitBreaker.psm1',
        'lib\ResponseAnalyzer.psm1'
    )

    # Private data to pass to the module specified in RootModule/ModuleToProcess. This may also contain a PSData hashtable with additional module metadata used by PowerShell.
    PrivateData = @{
        PSData = @{
            # Tags applied to this module. These help with module discovery in online galleries.
            Tags = @('Claude', 'AI', 'Automation', 'Development', 'Loop', 'Ralph')

            # A URL to the license for this module.
            LicenseUri = 'https://github.com/anthropics/ralph-claude-code/blob/main/LICENSE'

            # A URL to the main website for this project.
            ProjectUri = 'https://github.com/anthropics/ralph-claude-code'

            # A URL to an icon representing this module.
            IconUri = ''

            # ReleaseNotes of this module
            ReleaseNotes = @'
## v0.9.9 - PowerShell Port
- Native PowerShell support for Windows users without WSL
- Complete port of all bash scripts to PowerShell
- Library modules: DateUtils, CircuitBreaker, ResponseAnalyzer
- Main scripts: ralph_loop, ralph_monitor, ralph_import, setup
- Installation scripts: Install-Ralph, Uninstall-Ralph
- Windows Terminal integration for monitoring
- Full feature parity with bash implementation
'@

            # Prerelease string of this module
            Prerelease = ''

            # Flag to indicate whether the module requires explicit user acceptance for install/update/save
            RequireLicenseAcceptance = $false

            # External dependent modules of this module
            ExternalModuleDependencies = @()
        }
    }

    # HelpInfo URI of this module
    HelpInfoURI = 'https://github.com/anthropics/ralph-claude-code#readme'

    # Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix.
    DefaultCommandPrefix = ''
}
