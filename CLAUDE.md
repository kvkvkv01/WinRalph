# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Repository Overview

WinRalph is the native Windows PowerShell port of Ralph for Claude Code - an autonomous AI development loop system that enables continuous development cycles with intelligent exit detection and rate limiting.

**Version**: 1.0.0 | **Platform**: Windows PowerShell 5.1+

## Core Architecture

The system consists of PowerShell scripts and modules:

### Main Scripts

1. **ralph_loop.ps1** - The main autonomous loop that executes Claude Code repeatedly
2. **ralph_monitor.ps1** - Live monitoring dashboard for tracking loop status
3. **setup.ps1** - Project initialization script for new Ralph projects
4. **ralph_import.ps1** - PRD/specification import tool that converts documents to Ralph format
5. **Install-Ralph.ps1** - Global installation script
6. **Uninstall-Ralph.ps1** - Clean removal script

### Library Modules (lib/)

1. **lib/DateUtils.psm1** - Cross-platform date utilities
   - `Get-IsoTimestamp` - ISO 8601 formatted timestamps
   - `Get-NextHourTime` - Time for rate limit reset
   - `Get-EpochSeconds` - Unix epoch time
   - `ConvertFrom-IsoTimestamp` - Parse ISO timestamps

2. **lib/CircuitBreaker.psm1** - Circuit breaker pattern implementation
   - Three states: CLOSED (normal), HALF_OPEN (monitoring), OPEN (halted)
   - Configurable thresholds for no-progress and error detection
   - Automatic state transitions and recovery

3. **lib/ResponseAnalyzer.psm1** - Intelligent response analysis
   - JSON output format detection and parsing
   - Session management with 24-hour expiration
   - Completion signal detection
   - Two-stage error filtering

## Key Commands

### Installation
```powershell
# Install Ralph globally
.\Install-Ralph.ps1

# Uninstall Ralph
.\Uninstall-Ralph.ps1
```

### Setting Up a New Project
```powershell
# Create a new Ralph-managed project
ralph-setup my-project-name
cd my-project-name
```

### Running the Ralph Loop
```powershell
# Start with Windows Terminal monitoring (recommended)
ralph -Monitor

# Start without monitoring
ralph

# With custom parameters
ralph -Monitor -Calls 50 -Prompt my_custom_prompt.md

# Check current status
ralph -Status

# Circuit breaker management
ralph -ResetCircuit
ralph -CircuitStatus

# Session management
ralph -ResetSession
```

### Monitoring
```powershell
# Integrated Windows Terminal monitoring
ralph -Monitor

# Manual monitoring in separate terminal
ralph-monitor
```

## Configuration

### Rate Limiting
- Default: 100 API calls per hour (configurable via `-Calls` parameter)
- Automatic hourly reset with countdown display

### Exit Detection
The loop uses dual-condition check:
1. `completion_indicators >= 2` (heuristic detection)
2. Claude's explicit `EXIT_SIGNAL: true` in RALPH_STATUS block

### Circuit Breaker Thresholds
- `CB_NO_PROGRESS_THRESHOLD=3` - Open after 3 loops with no file changes
- `CB_SAME_ERROR_THRESHOLD=5` - Open after 5 loops with repeated errors

## Project Structure

```
WinRalph/
├── lib/
│   ├── DateUtils.psm1
│   ├── CircuitBreaker.psm1
│   └── ResponseAnalyzer.psm1
├── templates/
│   ├── PROMPT.md
│   ├── fix_plan.md
│   └── AGENT.md
├── ralph_loop.ps1
├── ralph_monitor.ps1
├── ralph_import.ps1
├── setup.ps1
├── Install-Ralph.ps1
├── Uninstall-Ralph.ps1
└── Ralph.psd1
```

## Global Installation Paths

WinRalph installs to:
- **Commands**: `$env:LOCALAPPDATA\Ralph\bin\` (ralph.cmd, ralph.ps1, etc.)
- **Templates**: `$env:USERPROFILE\.ralph\templates\`
- **Scripts**: `$env:USERPROFILE\.ralph\` (ralph_loop.ps1, etc.)
- **Modules**: `$env:USERPROFILE\.ralph\lib\`

## PowerShell-Specific Patterns

### JSON Operations (replaces jq)
```powershell
# Read and parse
$state = Get-Content $StateFile -Raw | ConvertFrom-Json

# Access nested fields
$exitSignal = $state.analysis.exit_signal ?? $false

# Update and write
$state | ConvertTo-Json -Depth 10 | Set-Content $StateFile
```

### Background Job Execution
```powershell
$job = Start-Job -ScriptBlock { & $claudeCmd @args }
$completed = Wait-Job -Job $job -Timeout $timeoutSeconds
if (-not $completed) {
    Stop-Job -Job $job
}
$result = Receive-Job -Job $job -Wait
```

### Signal Handling
```powershell
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    # Cleanup code
}
```

## Development Guidelines

When modifying WinRalph:

1. **Module Changes** - Update both the .psm1 file and Ralph.psd1 manifest
2. **New Functions** - Add to Export-ModuleMember in the module
3. **Testing** - Run syntax validation before committing
4. **Syntax Check** - PowerShell will catch errors on import

## Credits

- **Original Ralph**: [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code)
- **Ralph Technique**: [Geoffrey Huntley](https://ghuntley.com/ralph/)
