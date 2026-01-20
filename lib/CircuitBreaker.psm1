#Requires -Version 5.1
<#
.SYNOPSIS
    Circuit Breaker Component for Ralph.

.DESCRIPTION
    Prevents runaway token consumption by detecting stagnation.
    Based on Michael Nygard's "Release It!" pattern.
    Equivalent to lib/circuit_breaker.sh in the bash implementation.
#>

# Import DateUtils module
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptPath "DateUtils.psm1") -Force

# Circuit Breaker States
$script:CB_STATE_CLOSED = "CLOSED"        # Normal operation, progress detected
$script:CB_STATE_HALF_OPEN = "HALF_OPEN"  # Monitoring mode, checking for recovery
$script:CB_STATE_OPEN = "OPEN"            # Failure detected, execution halted

# Circuit Breaker Configuration
$script:CB_STATE_FILE = ".circuit_breaker_state"
$script:CB_HISTORY_FILE = ".circuit_breaker_history"
$script:CB_NO_PROGRESS_THRESHOLD = 3      # Open circuit after N loops with no progress
$script:CB_SAME_ERROR_THRESHOLD = 5       # Open circuit after N loops with same error
$script:CB_OUTPUT_DECLINE_THRESHOLD = 70  # Open circuit if output declines by >70%

# ANSI Colors
$script:Colors = @{
    Red = "`e[31m"
    Green = "`e[32m"
    Yellow = "`e[33m"
    Blue = "`e[34m"
    Reset = "`e[0m"
}

# Initialize circuit breaker
function Initialize-CircuitBreaker {
    [CmdletBinding()]
    param()

    # Check if state file exists and is valid JSON
    if (Test-Path $script:CB_STATE_FILE) {
        try {
            $null = Get-Content $script:CB_STATE_FILE -Raw | ConvertFrom-Json
        }
        catch {
            # Corrupted, recreate
            Remove-Item $script:CB_STATE_FILE -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path $script:CB_STATE_FILE)) {
        $initialState = @{
            state = $script:CB_STATE_CLOSED
            last_change = (Get-IsoTimestamp)
            consecutive_no_progress = 0
            consecutive_same_error = 0
            last_progress_loop = 0
            total_opens = 0
            reason = ""
        }
        $initialState | ConvertTo-Json -Depth 10 | Set-Content $script:CB_STATE_FILE
    }

    # Check if history file exists and is valid JSON
    if (Test-Path $script:CB_HISTORY_FILE) {
        try {
            $null = Get-Content $script:CB_HISTORY_FILE -Raw | ConvertFrom-Json
        }
        catch {
            # Corrupted, recreate
            Remove-Item $script:CB_HISTORY_FILE -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path $script:CB_HISTORY_FILE)) {
        "[]" | Set-Content $script:CB_HISTORY_FILE
    }
}

# Get current circuit breaker state
function Get-CircuitState {
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:CB_STATE_FILE)) {
        return $script:CB_STATE_CLOSED
    }

    try {
        $state = Get-Content $script:CB_STATE_FILE -Raw | ConvertFrom-Json
        return $state.state
    }
    catch {
        return $script:CB_STATE_CLOSED
    }
}

# Check if circuit breaker allows execution
function Test-CanExecute {
    [CmdletBinding()]
    param()

    $state = Get-CircuitState

    if ($state -eq $script:CB_STATE_OPEN) {
        return $false  # Circuit is open, cannot execute
    }
    else {
        return $true   # Circuit is closed or half-open, can execute
    }
}

# Record loop execution result
function Save-LoopResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$LoopNumber,

        [Parameter(Mandatory = $true)]
        [int]$FilesChanged,

        [Parameter(Mandatory = $true)]
        [bool]$HasErrors,

        [Parameter(Mandatory = $false)]
        [int]$OutputLength = 0
    )

    Initialize-CircuitBreaker

    $stateData = Get-Content $script:CB_STATE_FILE -Raw | ConvertFrom-Json
    $currentState = $stateData.state
    $consecutiveNoProgress = [int]$stateData.consecutive_no_progress
    $consecutiveSameError = [int]$stateData.consecutive_same_error
    $lastProgressLoop = [int]$stateData.last_progress_loop

    # Detect progress
    $hasProgress = $false
    if ($FilesChanged -gt 0) {
        $hasProgress = $true
        $consecutiveNoProgress = 0
        $lastProgressLoop = $LoopNumber
    }
    else {
        $consecutiveNoProgress++
    }

    # Detect same error repetition
    if ($HasErrors) {
        $consecutiveSameError++
    }
    else {
        $consecutiveSameError = 0
    }

    # Determine new state and reason
    $newState = $currentState
    $reason = ""

    # State transitions
    switch ($currentState) {
        $script:CB_STATE_CLOSED {
            # Normal operation - check for failure conditions
            if ($consecutiveNoProgress -ge $script:CB_NO_PROGRESS_THRESHOLD) {
                $newState = $script:CB_STATE_OPEN
                $reason = "No progress detected in $consecutiveNoProgress consecutive loops"
            }
            elseif ($consecutiveSameError -ge $script:CB_SAME_ERROR_THRESHOLD) {
                $newState = $script:CB_STATE_OPEN
                $reason = "Same error repeated in $consecutiveSameError consecutive loops"
            }
            elseif ($consecutiveNoProgress -ge 2) {
                $newState = $script:CB_STATE_HALF_OPEN
                $reason = "Monitoring: $consecutiveNoProgress loops without progress"
            }
        }

        $script:CB_STATE_HALF_OPEN {
            # Monitoring mode - either recover or fail
            if ($hasProgress) {
                $newState = $script:CB_STATE_CLOSED
                $reason = "Progress detected, circuit recovered"
            }
            elseif ($consecutiveNoProgress -ge $script:CB_NO_PROGRESS_THRESHOLD) {
                $newState = $script:CB_STATE_OPEN
                $reason = "No recovery, opening circuit after $consecutiveNoProgress loops"
            }
        }

        $script:CB_STATE_OPEN {
            # Circuit is open - stays open (manual intervention required)
            $reason = "Circuit breaker is open, execution halted"
        }
    }

    # Update state file
    $totalOpens = [int]$stateData.total_opens
    if ($newState -eq $script:CB_STATE_OPEN -and $currentState -ne $script:CB_STATE_OPEN) {
        $totalOpens++
    }

    $updatedState = @{
        state = $newState
        last_change = (Get-IsoTimestamp)
        consecutive_no_progress = $consecutiveNoProgress
        consecutive_same_error = $consecutiveSameError
        last_progress_loop = $lastProgressLoop
        total_opens = $totalOpens
        reason = $reason
        current_loop = $LoopNumber
    }
    $updatedState | ConvertTo-Json -Depth 10 | Set-Content $script:CB_STATE_FILE

    # Log state transition
    if ($newState -ne $currentState) {
        Write-CircuitTransition -FromState $currentState -ToState $newState -Reason $reason -LoopNumber $LoopNumber
    }

    # Return exit code based on new state
    if ($newState -eq $script:CB_STATE_OPEN) {
        return $false  # Circuit opened, signal to stop
    }
    else {
        return $true   # Can continue
    }
}

# Log circuit breaker state transitions
function Write-CircuitTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FromState,

        [Parameter(Mandatory = $true)]
        [string]$ToState,

        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [Parameter(Mandatory = $true)]
        [int]$LoopNumber
    )

    $history = Get-Content $script:CB_HISTORY_FILE -Raw | ConvertFrom-Json
    if ($null -eq $history) {
        $history = @()
    }

    $transition = @{
        timestamp = (Get-IsoTimestamp)
        loop = $LoopNumber
        from_state = $FromState
        to_state = $ToState
        reason = $Reason
    }

    $history = @($history) + $transition
    $history | ConvertTo-Json -Depth 10 | Set-Content $script:CB_HISTORY_FILE

    # Console log with colors
    switch ($ToState) {
        $script:CB_STATE_OPEN {
            Write-Host "$($script:Colors.Red)CIRCUIT BREAKER OPENED$($script:Colors.Reset)"
            Write-Host "$($script:Colors.Red)Reason: $Reason$($script:Colors.Reset)"
        }
        $script:CB_STATE_HALF_OPEN {
            Write-Host "$($script:Colors.Yellow)CIRCUIT BREAKER: Monitoring Mode$($script:Colors.Reset)"
            Write-Host "$($script:Colors.Yellow)Reason: $Reason$($script:Colors.Reset)"
        }
        $script:CB_STATE_CLOSED {
            Write-Host "$($script:Colors.Green)CIRCUIT BREAKER: Normal Operation$($script:Colors.Reset)"
            Write-Host "$($script:Colors.Green)Reason: $Reason$($script:Colors.Reset)"
        }
    }
}

# Display circuit breaker status
function Show-CircuitStatus {
    [CmdletBinding()]
    param()

    Initialize-CircuitBreaker

    $stateData = Get-Content $script:CB_STATE_FILE -Raw | ConvertFrom-Json
    $state = $stateData.state
    $reason = $stateData.reason
    $noProgress = $stateData.consecutive_no_progress
    $lastProgress = $stateData.last_progress_loop
    $currentLoop = $stateData.current_loop
    $totalOpens = $stateData.total_opens

    $color = $script:Colors.Green
    $statusIcon = "[OK]"

    switch ($state) {
        $script:CB_STATE_CLOSED {
            $color = $script:Colors.Green
            $statusIcon = "[OK]"
        }
        $script:CB_STATE_HALF_OPEN {
            $color = $script:Colors.Yellow
            $statusIcon = "[!]"
        }
        $script:CB_STATE_OPEN {
            $color = $script:Colors.Red
            $statusIcon = "[X]"
        }
    }

    Write-Host "$color============================================================$($script:Colors.Reset)"
    Write-Host "$color           Circuit Breaker Status                          $($script:Colors.Reset)"
    Write-Host "$color============================================================$($script:Colors.Reset)"
    Write-Host "${color}State:$($script:Colors.Reset)                 $statusIcon $state"
    Write-Host "${color}Reason:$($script:Colors.Reset)                $reason"
    Write-Host "${color}Loops since progress:$($script:Colors.Reset) $noProgress"
    Write-Host "${color}Last progress:$($script:Colors.Reset)        Loop #$lastProgress"
    Write-Host "${color}Current loop:$($script:Colors.Reset)         #$currentLoop"
    Write-Host "${color}Total opens:$($script:Colors.Reset)          $totalOpens"
    Write-Host ""
}

# Reset circuit breaker (for manual intervention)
function Reset-CircuitBreaker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Reason = "Manual reset"
    )

    $resetState = @{
        state = $script:CB_STATE_CLOSED
        last_change = (Get-IsoTimestamp)
        consecutive_no_progress = 0
        consecutive_same_error = 0
        last_progress_loop = 0
        total_opens = 0
        reason = $Reason
    }
    $resetState | ConvertTo-Json -Depth 10 | Set-Content $script:CB_STATE_FILE

    Write-Host "$($script:Colors.Green)Circuit breaker reset to CLOSED state$($script:Colors.Reset)"
}

# Check if loop should halt (used in main loop)
function Test-ShouldHaltExecution {
    [CmdletBinding()]
    param()

    $state = Get-CircuitState

    if ($state -eq $script:CB_STATE_OPEN) {
        Show-CircuitStatus
        Write-Host ""
        Write-Host "$($script:Colors.Red)============================================================$($script:Colors.Reset)"
        Write-Host "$($script:Colors.Red)  EXECUTION HALTED: Circuit Breaker Opened                 $($script:Colors.Reset)"
        Write-Host "$($script:Colors.Red)============================================================$($script:Colors.Reset)"
        Write-Host ""
        Write-Host "$($script:Colors.Yellow)Ralph has detected that no progress is being made.$($script:Colors.Reset)"
        Write-Host ""
        Write-Host "$($script:Colors.Yellow)Possible reasons:$($script:Colors.Reset)"
        Write-Host "  * Project may be complete (check @fix_plan.md)"
        Write-Host "  * Claude may be stuck on an error"
        Write-Host "  * PROMPT.md may need clarification"
        Write-Host "  * Manual intervention may be required"
        Write-Host ""
        Write-Host "$($script:Colors.Yellow)To continue:$($script:Colors.Reset)"
        Write-Host "  1. Review recent logs: Get-Content logs\ralph.log -Tail 20"
        Write-Host "  2. Check Claude output: Get-ChildItem logs\claude_output_*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1"
        Write-Host "  3. Update @fix_plan.md if needed"
        Write-Host "  4. Reset circuit breaker: ralph -ResetCircuit"
        Write-Host ""
        return $true  # Signal to halt
    }
    else {
        return $false  # Can continue
    }
}

# Export module members
Export-ModuleMember -Function @(
    'Initialize-CircuitBreaker',
    'Get-CircuitState',
    'Test-CanExecute',
    'Save-LoopResult',
    'Show-CircuitStatus',
    'Reset-CircuitBreaker',
    'Test-ShouldHaltExecution'
)

# Export variables for configuration
Export-ModuleMember -Variable @(
    'CB_STATE_CLOSED',
    'CB_STATE_HALF_OPEN',
    'CB_STATE_OPEN',
    'CB_NO_PROGRESS_THRESHOLD',
    'CB_SAME_ERROR_THRESHOLD',
    'CB_OUTPUT_DECLINE_THRESHOLD'
)
