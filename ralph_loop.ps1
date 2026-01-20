#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code Ralph Loop with Rate Limiting and Documentation.

.DESCRIPTION
    Adaptation of the Ralph technique for Claude Code with usage management.
    PowerShell port of ralph_loop.sh for native Windows support.

.PARAMETER Calls
    Maximum API calls per hour (default: 100)

.PARAMETER Prompt
    Path to prompt file (default: PROMPT.md)

.PARAMETER Status
    Show current status and exit

.PARAMETER Monitor
    Start with Windows Terminal tabs for monitoring

.PARAMETER Verbose
    Show detailed progress updates during execution

.PARAMETER Timeout
    Claude Code execution timeout in minutes (default: 15, max: 120)

.PARAMETER ResetCircuit
    Reset circuit breaker to CLOSED state

.PARAMETER CircuitStatus
    Show circuit breaker status and exit

.PARAMETER ResetSession
    Reset session state and exit

.PARAMETER OutputFormat
    Set Claude output format: json or text (default: json)

.PARAMETER AllowedTools
    Comma-separated list of allowed tools

.PARAMETER NoContinue
    Disable session continuity across loops

.PARAMETER SessionExpiry
    Session expiration time in hours (default: 24)
#>

[CmdletBinding()]
param(
    [Alias("c")]
    [int]$Calls = 100,

    [Alias("p")]
    [string]$Prompt = "PROMPT.md",

    [Alias("s")]
    [switch]$Status,

    [Alias("m")]
    [switch]$Monitor,

    [Alias("t")]
    [ValidateRange(1, 120)]
    [int]$Timeout = 15,

    [switch]$ResetCircuit,

    [switch]$CircuitStatus,

    [switch]$ResetSession,

    [ValidateSet("json", "text")]
    [string]$OutputFormat = "json",

    [string]$AllowedTools = "Write,Bash(git *),Read",

    [switch]$NoContinue,

    [int]$SessionExpiry = 24
)

$ErrorActionPreference = 'Stop'

# Get script directory and import modules
$script:ScriptDir = $PSScriptRoot
if (-not $script:ScriptDir) {
    $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Import library modules
Import-Module (Join-Path $script:ScriptDir "lib\DateUtils.psm1") -Force
Import-Module (Join-Path $script:ScriptDir "lib\CircuitBreaker.psm1") -Force
Import-Module (Join-Path $script:ScriptDir "lib\ResponseAnalyzer.psm1") -Force

# Configuration
$script:PROMPT_FILE = $Prompt
$script:LOG_DIR = "logs"
$script:DOCS_DIR = "docs\generated"
$script:STATUS_FILE = "status.json"
$script:PROGRESS_FILE = "progress.json"
$script:CLAUDE_CODE_CMD = "claude"
$script:MAX_CALLS_PER_HOUR = $Calls
$script:VERBOSE_PROGRESS = $VerbosePreference -eq 'Continue'
$script:CLAUDE_TIMEOUT_MINUTES = $Timeout
$script:SLEEP_DURATION = 3600  # 1 hour in seconds
$script:CALL_COUNT_FILE = ".call_count"
$script:TIMESTAMP_FILE = ".last_reset"

# Modern Claude CLI configuration
$script:CLAUDE_OUTPUT_FORMAT = $OutputFormat
$script:CLAUDE_ALLOWED_TOOLS = $AllowedTools
$script:CLAUDE_USE_CONTINUE = -not $NoContinue
$script:CLAUDE_SESSION_FILE = ".claude_session_id"
$script:CLAUDE_MIN_VERSION = "2.0.76"
$script:CLAUDE_SESSION_EXPIRY_HOURS = $SessionExpiry

# Session management configuration
$script:RALPH_SESSION_FILE = ".ralph_session"
$script:RALPH_SESSION_HISTORY_FILE = ".ralph_session_history"

# Exit detection configuration
$script:EXIT_SIGNALS_FILE = ".exit_signals"
$script:MAX_CONSECUTIVE_TEST_LOOPS = 3
$script:MAX_CONSECUTIVE_DONE_SIGNALS = 2
$script:TEST_PERCENTAGE_THRESHOLD = 30

# Valid tool patterns for --allowed-tools validation
$script:VALID_TOOL_PATTERNS = @(
    "Write", "Read", "Edit", "MultiEdit", "Glob", "Grep", "Task",
    "TodoWrite", "WebFetch", "WebSearch", "Bash", "Bash(git *)",
    "Bash(npm *)", "Bash(bats *)", "Bash(python *)", "Bash(node *)",
    "NotebookEdit"
)

# ANSI Colors
$script:Colors = @{
    Red = "`e[31m"
    Green = "`e[32m"
    Yellow = "`e[33m"
    Blue = "`e[34m"
    Purple = "`e[35m"
    Reset = "`e[0m"
}

# Global loop counter
$script:LoopCount = 0

# Initialize directories
function Initialize-Directories {
    New-Item -ItemType Directory -Path $script:LOG_DIR -Force | Out-Null
    New-Item -ItemType Directory -Path $script:DOCS_DIR -Force | Out-Null
}

# Log function with timestamps and colors
function Write-RalphStatus {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "LOOP")]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO" { $script:Colors.Blue }
        "WARN" { $script:Colors.Yellow }
        "ERROR" { $script:Colors.Red }
        "SUCCESS" { $script:Colors.Green }
        "LOOP" { $script:Colors.Purple }
    }

    Write-Host "$color[$timestamp] [$Level] $Message$($script:Colors.Reset)"

    # Append to log file
    $logFile = Join-Path $script:LOG_DIR "ralph.log"
    "[$timestamp] [$Level] $Message" | Add-Content -Path $logFile
}

# Initialize call tracking
function Initialize-CallTracking {
    Write-RalphStatus "INFO" "DEBUG: Entered Initialize-CallTracking..."

    $currentHour = Get-Date -Format "yyyyMMddHH"
    $lastResetHour = ""

    if (Test-Path $script:TIMESTAMP_FILE) {
        $lastResetHour = Get-Content $script:TIMESTAMP_FILE -Raw
        $lastResetHour = $lastResetHour.Trim()
    }

    # Reset counter if it's a new hour
    if ($currentHour -ne $lastResetHour) {
        "0" | Set-Content $script:CALL_COUNT_FILE
        $currentHour | Set-Content $script:TIMESTAMP_FILE
        Write-RalphStatus "INFO" "Call counter reset for new hour: $currentHour"
    }

    # Initialize exit signals tracking if it doesn't exist
    if (-not (Test-Path $script:EXIT_SIGNALS_FILE)) {
        @{
            test_only_loops = @()
            done_signals = @()
            completion_indicators = @()
        } | ConvertTo-Json | Set-Content $script:EXIT_SIGNALS_FILE
    }

    # Initialize circuit breaker
    Initialize-CircuitBreaker

    Write-RalphStatus "INFO" "DEBUG: Completed Initialize-CallTracking successfully"
}

# Update status JSON for external monitoring
function Update-RalphStatus {
    param(
        [int]$LoopCount,
        [int]$CallsMade,
        [string]$LastAction,
        [string]$Status,
        [string]$ExitReason = ""
    )

    $statusObj = @{
        timestamp = (Get-IsoTimestamp)
        loop_count = $LoopCount
        calls_made_this_hour = $CallsMade
        max_calls_per_hour = $script:MAX_CALLS_PER_HOUR
        last_action = $LastAction
        status = $Status
        exit_reason = $ExitReason
        next_reset = (Get-NextHourTime)
    }

    $statusObj | ConvertTo-Json -Depth 10 | Set-Content $script:STATUS_FILE
}

# Check if we can make another call
function Test-CanMakeCall {
    $callsMade = 0
    if (Test-Path $script:CALL_COUNT_FILE) {
        $callsMade = [int](Get-Content $script:CALL_COUNT_FILE -Raw)
    }

    return $callsMade -lt $script:MAX_CALLS_PER_HOUR
}

# Increment call counter
function Add-CallCount {
    $callsMade = 0
    if (Test-Path $script:CALL_COUNT_FILE) {
        $callsMade = [int](Get-Content $script:CALL_COUNT_FILE -Raw)
    }

    $callsMade++
    $callsMade | Set-Content $script:CALL_COUNT_FILE
    return $callsMade
}

# Get current call count
function Get-CallCount {
    if (Test-Path $script:CALL_COUNT_FILE) {
        return [int](Get-Content $script:CALL_COUNT_FILE -Raw)
    }
    return 0
}

# Wait for rate limit reset with countdown
function Wait-ForReset {
    $callsMade = Get-CallCount
    Write-RalphStatus "WARN" "Rate limit reached ($callsMade/$script:MAX_CALLS_PER_HOUR). Waiting for reset..."

    # Calculate time until next hour
    $now = Get-Date
    $nextHour = $now.AddHours(1)
    $nextHour = Get-Date -Year $nextHour.Year -Month $nextHour.Month -Day $nextHour.Day -Hour $nextHour.Hour -Minute 0 -Second 0
    $waitTime = ($nextHour - $now).TotalSeconds

    Write-RalphStatus "INFO" "Sleeping for $([int]$waitTime) seconds until next hour..."

    # Countdown display
    while ($waitTime -gt 0) {
        $hours = [int]($waitTime / 3600)
        $minutes = [int](($waitTime % 3600) / 60)
        $seconds = [int]($waitTime % 60)

        Write-Host -NoNewline "`r$($script:Colors.Yellow)Time until reset: $($hours.ToString('00')):$($minutes.ToString('00')):$($seconds.ToString('00'))$($script:Colors.Reset)"
        Start-Sleep -Seconds 1
        $waitTime--
    }
    Write-Host ""

    # Reset counter
    "0" | Set-Content $script:CALL_COUNT_FILE
    (Get-Date -Format "yyyyMMddHH") | Set-Content $script:TIMESTAMP_FILE
    Write-RalphStatus "SUCCESS" "Rate limit reset! Ready for new calls."
}

# Check if we should gracefully exit
function Test-ShouldExitGracefully {
    Write-RalphStatus "INFO" "DEBUG: Checking exit conditions..."

    if (-not (Test-Path $script:EXIT_SIGNALS_FILE)) {
        Write-RalphStatus "INFO" "DEBUG: No exit signals file found, continuing..."
        return $null
    }

    try {
        $signals = Get-Content $script:EXIT_SIGNALS_FILE -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }

    # Count recent signals (last 5 loops)
    $recentTestLoops = @($signals.test_only_loops).Count
    $recentDoneSignals = @($signals.done_signals).Count
    $recentCompletionIndicators = @($signals.completion_indicators).Count

    Write-RalphStatus "INFO" "DEBUG: Exit counts - test_loops:$recentTestLoops, done_signals:$recentDoneSignals, completion:$recentCompletionIndicators"

    # Check for exit conditions

    # 1. Too many consecutive test-only loops
    if ($recentTestLoops -ge $script:MAX_CONSECUTIVE_TEST_LOOPS) {
        Write-RalphStatus "WARN" "Exit condition: Too many test-focused loops ($recentTestLoops >= $script:MAX_CONSECUTIVE_TEST_LOOPS)"
        return "test_saturation"
    }

    # 2. Multiple "done" signals
    if ($recentDoneSignals -ge $script:MAX_CONSECUTIVE_DONE_SIGNALS) {
        Write-RalphStatus "WARN" "Exit condition: Multiple completion signals ($recentDoneSignals >= $script:MAX_CONSECUTIVE_DONE_SIGNALS)"
        return "completion_signals"
    }

    # 3. Strong completion indicators (only if Claude's EXIT_SIGNAL is true)
    $claudeExitSignal = $false
    if (Test-Path ".response_analysis") {
        try {
            $analysis = Get-Content ".response_analysis" -Raw | ConvertFrom-Json
            $claudeExitSignal = $analysis.analysis.exit_signal -eq $true
        }
        catch { }
    }

    if ($recentCompletionIndicators -ge 2 -and $claudeExitSignal) {
        Write-RalphStatus "WARN" "Exit condition: Strong completion indicators ($recentCompletionIndicators) with EXIT_SIGNAL=true"
        return "project_complete"
    }
    elseif ($recentCompletionIndicators -ge 2) {
        Write-RalphStatus "INFO" "DEBUG: Completion indicators ($recentCompletionIndicators) present but EXIT_SIGNAL=false, continuing..."
    }

    # 4. Check fix_plan.md for completion
    if (Test-Path "@fix_plan.md") {
        $content = Get-Content "@fix_plan.md" -Raw
        $totalItems = ([regex]::Matches($content, "^- \[", [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count
        $completedItems = ([regex]::Matches($content, "^- \[x\]", [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count

        Write-RalphStatus "INFO" "DEBUG: @fix_plan.md check - total_items:$totalItems, completed_items:$completedItems"

        if ($totalItems -gt 0 -and $completedItems -eq $totalItems) {
            Write-RalphStatus "WARN" "Exit condition: All fix_plan.md items completed ($completedItems/$totalItems)"
            return "plan_complete"
        }
    }
    else {
        Write-RalphStatus "INFO" "DEBUG: @fix_plan.md file not found"
    }

    Write-RalphStatus "INFO" "DEBUG: No exit conditions met, continuing loop"
    return $null
}

# =============================================================================
# MODERN CLI HELPER FUNCTIONS
# =============================================================================

# Check Claude CLI version for compatibility with modern flags
function Test-ClaudeVersion {
    try {
        $versionOutput = & $script:CLAUDE_CODE_CMD --version 2>$null
        $version = [regex]::Match($versionOutput, '\d+\.\d+\.\d+').Value

        if ([string]::IsNullOrEmpty($version)) {
            Write-RalphStatus "WARN" "Cannot detect Claude CLI version, assuming compatible"
            return $true
        }

        $verParts = $version.Split('.')
        $reqParts = $script:CLAUDE_MIN_VERSION.Split('.')

        $verNum = [int]$verParts[0] * 10000 + [int]$verParts[1] * 100 + [int]$verParts[2]
        $reqNum = [int]$reqParts[0] * 10000 + [int]$reqParts[1] * 100 + [int]$reqParts[2]

        if ($verNum -lt $reqNum) {
            Write-RalphStatus "WARN" "Claude CLI version $version < $($script:CLAUDE_MIN_VERSION). Some modern features may not work."
            Write-RalphStatus "WARN" "Consider upgrading: npm update -g @anthropic-ai/claude-code"
            return $false
        }

        Write-RalphStatus "INFO" "Claude CLI version $version (>= $($script:CLAUDE_MIN_VERSION)) - modern features enabled"
        return $true
    }
    catch {
        Write-RalphStatus "WARN" "Cannot detect Claude CLI version: $_"
        return $true
    }
}

# Validate allowed tools against whitelist
function Test-AllowedTools {
    param([string]$ToolsInput)

    if ([string]::IsNullOrWhiteSpace($ToolsInput)) {
        return $true
    }

    $tools = $ToolsInput -split ','

    foreach ($tool in $tools) {
        $tool = $tool.Trim()
        if ([string]::IsNullOrWhiteSpace($tool)) {
            continue
        }

        $valid = $false

        foreach ($pattern in $script:VALID_TOOL_PATTERNS) {
            if ($tool -eq $pattern) {
                $valid = $true
                break
            }
            # Check for Bash(*) pattern
            if ($tool -match '^Bash\(.+\)$') {
                $valid = $true
                break
            }
        }

        if (-not $valid) {
            Write-Error "Invalid tool in --allowed-tools: '$tool'"
            Write-Host "Valid tools: $($script:VALID_TOOL_PATTERNS -join ', ')"
            Write-Host "Note: Bash(...) patterns with any content are allowed (e.g., 'Bash(git *)')"
            return $false
        }
    }

    return $true
}

# Build loop context for Claude Code session
function Get-LoopContext {
    param([int]$LoopCount)

    $context = "Loop #$LoopCount. "

    # Extract incomplete tasks from @fix_plan.md
    if (Test-Path "@fix_plan.md") {
        $content = Get-Content "@fix_plan.md" -Raw
        $incompleteTasks = ([regex]::Matches($content, "^- \[ \]", [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count
        $context += "Remaining tasks: $incompleteTasks. "
    }

    # Add circuit breaker state
    if (Test-Path ".circuit_breaker_state") {
        try {
            $cbState = (Get-Content ".circuit_breaker_state" -Raw | ConvertFrom-Json).state
            if ($cbState -ne "CLOSED" -and $cbState -ne "null" -and -not [string]::IsNullOrEmpty($cbState)) {
                $context += "Circuit breaker: $cbState. "
            }
        }
        catch { }
    }

    # Add previous loop summary (truncated)
    if (Test-Path ".response_analysis") {
        try {
            $prevSummary = (Get-Content ".response_analysis" -Raw | ConvertFrom-Json).analysis.work_summary
            if (-not [string]::IsNullOrEmpty($prevSummary) -and $prevSummary -ne "null") {
                $context += "Previous: $($prevSummary.Substring(0, [Math]::Min(200, $prevSummary.Length)))"
            }
        }
        catch { }
    }

    # Limit total length to ~500 chars
    return $context.Substring(0, [Math]::Min(500, $context.Length))
}

# Get session file age in hours
function Get-SessionFileAgeHours {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) {
        return 0
    }

    try {
        $fileItem = Get-Item $FilePath
        $age = (Get-Date) - $fileItem.LastWriteTime
        return [int]($age.TotalHours)
    }
    catch {
        return -1
    }
}

# Initialize or resume Claude session (with expiration check)
function Initialize-ClaudeSession {
    if (Test-Path $script:CLAUDE_SESSION_FILE) {
        # Check session age
        $ageHours = Get-SessionFileAgeHours $script:CLAUDE_SESSION_FILE

        if ($ageHours -eq -1) {
            Write-RalphStatus "WARN" "Could not determine session age, starting new session"
            Remove-Item $script:CLAUDE_SESSION_FILE -Force -ErrorAction SilentlyContinue
            return ""
        }

        if ($ageHours -ge $script:CLAUDE_SESSION_EXPIRY_HOURS) {
            Write-RalphStatus "INFO" "Session expired (${ageHours}h old, max $($script:CLAUDE_SESSION_EXPIRY_HOURS)h), starting new session"
            Remove-Item $script:CLAUDE_SESSION_FILE -Force -ErrorAction SilentlyContinue
            return ""
        }

        # Session is valid, try to read it
        try {
            $sessionId = Get-Content $script:CLAUDE_SESSION_FILE -Raw
            $sessionId = $sessionId.Trim()
            if (-not [string]::IsNullOrEmpty($sessionId)) {
                Write-RalphStatus "INFO" "Resuming Claude session: $($sessionId.Substring(0, [Math]::Min(20, $sessionId.Length)))... (${ageHours}h old)"
                return $sessionId
            }
        }
        catch { }
    }

    Write-RalphStatus "INFO" "Starting new Claude session"
    return ""
}

# Save session ID after successful execution
function Save-ClaudeSession {
    param([string]$OutputFile)

    if (Test-Path $OutputFile) {
        try {
            $output = Get-Content $OutputFile -Raw | ConvertFrom-Json
            $sessionId = $output.metadata.session_id
            if ([string]::IsNullOrEmpty($sessionId)) {
                $sessionId = $output.session_id
            }

            if (-not [string]::IsNullOrEmpty($sessionId) -and $sessionId -ne "null") {
                $sessionId | Set-Content $script:CLAUDE_SESSION_FILE
                Write-RalphStatus "INFO" "Saved Claude session: $($sessionId.Substring(0, [Math]::Min(20, $sessionId.Length)))..."
            }
        }
        catch { }
    }
}

# =============================================================================
# SESSION LIFECYCLE MANAGEMENT FUNCTIONS
# =============================================================================

# Get current session ID from Ralph session file
function Get-RalphSessionId {
    if (-not (Test-Path $script:RALPH_SESSION_FILE)) {
        return ""
    }

    try {
        $session = Get-Content $script:RALPH_SESSION_FILE -Raw | ConvertFrom-Json
        return $session.session_id
    }
    catch {
        return ""
    }
}

# Reset session with reason logging
function Reset-RalphSession {
    param([string]$Reason = "manual_reset")

    $resetTimestamp = Get-IsoTimestamp

    $sessionData = @{
        session_id = ""
        created_at = ""
        last_used = ""
        reset_at = $resetTimestamp
        reset_reason = $Reason
    }

    $sessionData | ConvertTo-Json -Depth 10 | Set-Content $script:RALPH_SESSION_FILE

    # Also clear the Claude session file for consistency
    Remove-Item $script:CLAUDE_SESSION_FILE -Force -ErrorAction SilentlyContinue

    # Log the session transition
    Write-SessionTransition -FromState "active" -ToState "reset" -Reason $Reason -LoopNumber $script:LoopCount

    Write-RalphStatus "INFO" "Session reset: $Reason"
}

# Log session state transitions to history file
function Write-SessionTransition {
    param(
        [string]$FromState,
        [string]$ToState,
        [string]$Reason,
        [int]$LoopNumber = 0
    )

    $timestamp = Get-IsoTimestamp

    $transition = @{
        timestamp = $timestamp
        from_state = $FromState
        to_state = $ToState
        reason = $Reason
        loop_number = $LoopNumber
    }

    # Read history file
    $history = @()
    if (Test-Path $script:RALPH_SESSION_HISTORY_FILE) {
        try {
            $history = @(Get-Content $script:RALPH_SESSION_HISTORY_FILE -Raw | ConvertFrom-Json)
        }
        catch {
            $history = @()
        }
    }

    # Append transition and keep only last 50 entries
    $history = @($history) + $transition
    if ($history.Count -gt 50) {
        $history = $history[-50..-1]
    }

    $history | ConvertTo-Json -Depth 10 | Set-Content $script:RALPH_SESSION_HISTORY_FILE
}

# Generate a unique session ID
function New-SessionId {
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $random = Get-Random -Maximum 65535
    return "ralph-$timestamp-$random"
}

# Initialize session tracking (called at loop start)
function Initialize-SessionTracking {
    $timestamp = Get-IsoTimestamp

    # Create session file if it doesn't exist
    if (-not (Test-Path $script:RALPH_SESSION_FILE)) {
        $newSessionId = New-SessionId

        $sessionData = @{
            session_id = $newSessionId
            created_at = $timestamp
            last_used = $timestamp
            reset_at = ""
            reset_reason = ""
        }

        $sessionData | ConvertTo-Json -Depth 10 | Set-Content $script:RALPH_SESSION_FILE
        Write-RalphStatus "INFO" "Initialized session tracking (session: $newSessionId)"
        return
    }

    # Validate existing session file
    try {
        $null = Get-Content $script:RALPH_SESSION_FILE -Raw | ConvertFrom-Json
    }
    catch {
        Write-RalphStatus "WARN" "Corrupted session file detected, recreating..."
        $newSessionId = New-SessionId

        $sessionData = @{
            session_id = $newSessionId
            created_at = $timestamp
            last_used = $timestamp
            reset_at = $timestamp
            reset_reason = "corrupted_file_recovery"
        }

        $sessionData | ConvertTo-Json -Depth 10 | Set-Content $script:RALPH_SESSION_FILE
    }
}

# Update last_used timestamp in session file
function Update-SessionLastUsed {
    if (-not (Test-Path $script:RALPH_SESSION_FILE)) {
        return
    }

    try {
        $session = Get-Content $script:RALPH_SESSION_FILE -Raw | ConvertFrom-Json
        $session.last_used = Get-IsoTimestamp
        $session | ConvertTo-Json -Depth 10 | Set-Content $script:RALPH_SESSION_FILE
    }
    catch { }
}

# =============================================================================
# MAIN EXECUTION FUNCTION
# =============================================================================

function Invoke-ClaudeCode {
    param([int]$LoopCount)

    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $outputFile = Join-Path $script:LOG_DIR "claude_output_$timestamp.log"
    $callsMade = (Get-CallCount) + 1

    Write-RalphStatus "LOOP" "Executing Claude Code (Call $callsMade/$script:MAX_CALLS_PER_HOUR)"
    $timeoutSeconds = $script:CLAUDE_TIMEOUT_MINUTES * 60
    Write-RalphStatus "INFO" "Starting Claude Code execution... (timeout: $($script:CLAUDE_TIMEOUT_MINUTES)m)"

    # Build loop context for session continuity
    $loopContext = ""
    if ($script:CLAUDE_USE_CONTINUE) {
        $loopContext = Get-LoopContext -LoopCount $LoopCount
        if (-not [string]::IsNullOrEmpty($loopContext) -and $script:VERBOSE_PROGRESS) {
            Write-RalphStatus "INFO" "Loop context: $loopContext"
        }
    }

    # Initialize or resume session
    $sessionId = ""
    if ($script:CLAUDE_USE_CONTINUE) {
        $sessionId = Initialize-ClaudeSession
    }

    # Build the Claude CLI command arguments
    $useModernCli = $false
    $claudeArgs = @()

    if ($script:CLAUDE_OUTPUT_FORMAT -eq "json") {
        $useModernCli = $true
        $claudeArgs += "--output-format", "json"

        # Add allowed tools
        if (-not [string]::IsNullOrEmpty($script:CLAUDE_ALLOWED_TOOLS)) {
            $claudeArgs += "--allowedTools"
            $tools = $script:CLAUDE_ALLOWED_TOOLS -split ','
            foreach ($tool in $tools) {
                $tool = $tool.Trim()
                if (-not [string]::IsNullOrEmpty($tool)) {
                    $claudeArgs += $tool
                }
            }
        }

        # Add session continuity flag
        if ($script:CLAUDE_USE_CONTINUE) {
            $claudeArgs += "--continue"
        }

        # Add loop context as system prompt
        if (-not [string]::IsNullOrEmpty($loopContext)) {
            $claudeArgs += "--append-system-prompt", $loopContext
        }

        # Read prompt file content
        if (-not (Test-Path $script:PROMPT_FILE)) {
            Write-RalphStatus "ERROR" "Prompt file not found: $($script:PROMPT_FILE)"
            return 1
        }
        $promptContent = Get-Content $script:PROMPT_FILE -Raw
        $claudeArgs += "-p", $promptContent

        Write-RalphStatus "INFO" "Using modern CLI mode (JSON output)"
    }
    else {
        Write-RalphStatus "INFO" "Using legacy CLI mode (text output)"
    }

    # Execute Claude Code
    $startTime = Get-Date
    $progressCounter = 0
    $progressIndicators = @(".", "..", "...", "....")

    try {
        if ($useModernCli) {
            # Start Claude as a background job
            $job = Start-Job -ScriptBlock {
                param($cmd, $args, $outFile)
                & $cmd @args 2>&1 | Out-File -FilePath $outFile -Encoding UTF8
                return $LASTEXITCODE
            } -ArgumentList $script:CLAUDE_CODE_CMD, $claudeArgs, $outputFile
        }
        else {
            # Legacy mode: pipe prompt file to stdin
            $job = Start-Job -ScriptBlock {
                param($cmd, $promptFile, $outFile)
                Get-Content $promptFile -Raw | & $cmd 2>&1 | Out-File -FilePath $outFile -Encoding UTF8
                return $LASTEXITCODE
            } -ArgumentList $script:CLAUDE_CODE_CMD, $script:PROMPT_FILE, $outputFile
        }

        # Monitor progress
        while ($job.State -eq 'Running') {
            $elapsed = ((Get-Date) - $startTime).TotalSeconds

            if ($elapsed -gt $timeoutSeconds) {
                Write-RalphStatus "WARN" "Timeout reached ($($script:CLAUDE_TIMEOUT_MINUTES) minutes), stopping Claude Code..."
                Stop-Job -Job $job
                Remove-Job -Job $job -Force
                throw "Execution timeout"
            }

            $progressCounter++
            $indicator = $progressIndicators[$progressCounter % 4]

            # Get last line from output if available
            $lastLine = ""
            if (Test-Path $outputFile) {
                $lines = Get-Content $outputFile -Tail 1 -ErrorAction SilentlyContinue
                if ($lines) {
                    $lastLine = $lines.ToString().Substring(0, [Math]::Min(80, $lines.ToString().Length))
                }
            }

            # Update progress file for monitor
            @{
                status = "executing"
                indicator = $indicator
                elapsed_seconds = [int]$elapsed
                last_output = $lastLine
                timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            } | ConvertTo-Json | Set-Content $script:PROGRESS_FILE

            if ($script:VERBOSE_PROGRESS) {
                if (-not [string]::IsNullOrEmpty($lastLine)) {
                    Write-RalphStatus "INFO" "$indicator Claude Code: $lastLine... ($([int]$elapsed)s)"
                }
                else {
                    Write-RalphStatus "INFO" "$indicator Claude Code working... ($([int]$elapsed)s elapsed)"
                }
            }

            Start-Sleep -Seconds 10
        }

        # Get job result
        $jobResult = Receive-Job -Job $job -Wait
        $exitCode = $job.ChildJobs[0].JobStateInfo.Reason
        Remove-Job -Job $job -Force

        # Check if output file was created and has content
        if (-not (Test-Path $outputFile) -or (Get-Item $outputFile).Length -eq 0) {
            Write-RalphStatus "ERROR" "Claude Code produced no output"
            return 1
        }

        # Success case
        Add-CallCount | Out-Null

        # Clear progress file
        @{
            status = "completed"
            timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        } | ConvertTo-Json | Set-Content $script:PROGRESS_FILE

        Write-RalphStatus "SUCCESS" "Claude Code execution completed successfully"

        # Save session ID from JSON output
        if ($script:CLAUDE_USE_CONTINUE) {
            Save-ClaudeSession $outputFile
        }

        # Analyze the response
        Write-RalphStatus "INFO" "Analyzing Claude Code response..."
        Invoke-ResponseAnalysis -OutputFile $outputFile -LoopNumber $LoopCount

        # Update exit signals based on analysis
        Update-ExitSignals

        # Log analysis summary
        Write-AnalysisSummary

        # Get file change count for circuit breaker
        $filesChanged = 0
        $hasErrors = $false

        if (Get-Command git -ErrorAction SilentlyContinue) {
            try {
                $filesChanged = @(git diff --name-only 2>$null).Count
            }
            catch { }
        }

        # Two-stage error detection
        $outputContent = Get-Content $outputFile -Raw
        $lines = $outputContent -split "`n"
        $filteredLines = $lines | Where-Object { $_ -notmatch '"[^"]*error[^"]*":' }
        $filteredContent = $filteredLines -join "`n"

        $errorMatches = [regex]::Matches($filteredContent, '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if ($errorMatches.Count -gt 0) {
            $hasErrors = $true
            Write-RalphStatus "WARN" "Errors detected in output, check: $outputFile"
        }

        $outputLength = (Get-Item $outputFile).Length

        # Record result in circuit breaker
        $circuitResult = Save-LoopResult -LoopNumber $LoopCount -FilesChanged $filesChanged -HasErrors $hasErrors -OutputLength $outputLength

        if (-not $circuitResult) {
            Write-RalphStatus "WARN" "Circuit breaker opened - halting execution"
            return 3  # Special code for circuit breaker trip
        }

        return 0
    }
    catch {
        # Clear progress file on failure
        @{
            status = "failed"
            timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        } | ConvertTo-Json | Set-Content $script:PROGRESS_FILE

        # Check if the failure is due to API 5-hour limit
        if (Test-Path $outputFile) {
            $content = Get-Content $outputFile -Raw -ErrorAction SilentlyContinue
            if ($content -match "5.*hour.*limit|limit.*reached.*try.*back|usage.*limit.*reached") {
                Write-RalphStatus "ERROR" "Claude API 5-hour usage limit reached"
                return 2  # Special return code for API limit
            }
        }

        Write-RalphStatus "ERROR" "Claude Code execution failed: $_"
        return 1
    }
}

# Cleanup function
function Invoke-Cleanup {
    Write-RalphStatus "INFO" "Ralph loop interrupted. Cleaning up..."
    Reset-RalphSession -Reason "manual_interrupt"
    Update-RalphStatus -LoopCount $script:LoopCount -CallsMade (Get-CallCount) -LastAction "interrupted" -Status "stopped"
}

# =============================================================================
# MONITORING (Windows Alternative to tmux)
# =============================================================================

function Start-WithMonitor {
    Write-RalphStatus "INFO" "Starting Ralph with monitor..."

    # Check if Windows Terminal is available
    $wtAvailable = Get-Command wt -ErrorAction SilentlyContinue

    if ($wtAvailable) {
        # Use Windows Terminal tabs
        $scriptPath = $MyInvocation.MyCommand.Path
        $monitorPath = Join-Path $script:ScriptDir "ralph_monitor.ps1"
        $currentDir = Get-Location

        # Build command for Ralph loop (without monitor flag to avoid recursion)
        $ralphArgs = @("-NoExit", "-File", $scriptPath)
        if ($script:MAX_CALLS_PER_HOUR -ne 100) {
            $ralphArgs += "-Calls", $script:MAX_CALLS_PER_HOUR
        }
        if ($script:PROMPT_FILE -ne "PROMPT.md") {
            $ralphArgs += "-Prompt", $script:PROMPT_FILE
        }

        # Start Windows Terminal with split pane
        Write-RalphStatus "INFO" "Launching Windows Terminal with Ralph and Monitor..."
        Start-Process wt -ArgumentList @(
            "-d", $currentDir,
            "powershell", ($ralphArgs -join " "),
            ";", "split-pane", "-V",
            "-d", $currentDir,
            "powershell", "-NoExit", "-File", $monitorPath
        )

        Write-RalphStatus "SUCCESS" "Windows Terminal session launched."
        exit 0
    }
    else {
        # Fallback: Open separate console windows
        Write-RalphStatus "WARN" "Windows Terminal not found, using separate console windows..."

        $scriptPath = $MyInvocation.MyCommand.Path
        $monitorPath = Join-Path $script:ScriptDir "ralph_monitor.ps1"

        # Start monitor in new window
        Start-Process powershell -ArgumentList "-NoExit", "-File", $monitorPath

        # Continue with main loop in current window
        Write-RalphStatus "INFO" "Monitor started in separate window. Continuing with main loop..."
    }
}

# =============================================================================
# MAIN LOOP
# =============================================================================

function Start-RalphLoop {
    Write-RalphStatus "SUCCESS" "Ralph loop starting with Claude Code"
    Write-RalphStatus "INFO" "Max calls per hour: $script:MAX_CALLS_PER_HOUR"
    Write-RalphStatus "INFO" "Logs: $script:LOG_DIR\ | Docs: $script:DOCS_DIR\ | Status: $script:STATUS_FILE"

    # Check if this is a Ralph project directory
    if (-not (Test-Path $script:PROMPT_FILE)) {
        Write-RalphStatus "ERROR" "Prompt file '$($script:PROMPT_FILE)' not found!"
        Write-Host ""

        # Check if this looks like a partial Ralph project
        if ((Test-Path "@fix_plan.md") -or (Test-Path "specs") -or (Test-Path "@AGENT.md")) {
            Write-Host "This appears to be a Ralph project but is missing PROMPT.md."
            Write-Host "You may need to create or restore the PROMPT.md file."
        }
        else {
            Write-Host "This directory is not a Ralph project."
        }

        Write-Host ""
        Write-Host "To fix this:"
        Write-Host "  1. Create a new project: ralph-setup my-project"
        Write-Host "  2. Import existing requirements: ralph-import requirements.md"
        Write-Host "  3. Navigate to an existing Ralph project directory"
        Write-Host "  4. Or create PROMPT.md manually in this directory"
        Write-Host ""
        Write-Host "Ralph projects should contain: PROMPT.md, @fix_plan.md, specs\, src\, etc."
        exit 1
    }

    # Initialize session tracking before entering the loop
    Initialize-SessionTracking

    Write-RalphStatus "INFO" "Starting main loop..."

    # Register Ctrl+C handler
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        Invoke-Cleanup
    }

    try {
        while ($true) {
            $script:LoopCount++

            # Update session last_used timestamp
            Update-SessionLastUsed

            Write-RalphStatus "INFO" "Loop #$($script:LoopCount) - calling Initialize-CallTracking..."
            Initialize-CallTracking

            Write-RalphStatus "LOOP" "=== Starting Loop #$($script:LoopCount) ==="

            # Check circuit breaker before attempting execution
            if (Test-ShouldHaltExecution) {
                Reset-RalphSession -Reason "circuit_breaker_open"
                Update-RalphStatus -LoopCount $script:LoopCount -CallsMade (Get-CallCount) -LastAction "circuit_breaker_open" -Status "halted" -ExitReason "stagnation_detected"
                Write-RalphStatus "ERROR" "Circuit breaker has opened - execution halted"
                break
            }

            # Check rate limits
            if (-not (Test-CanMakeCall)) {
                Wait-ForReset
                continue
            }

            # Check for graceful exit conditions
            $exitReason = Test-ShouldExitGracefully
            if ($null -ne $exitReason) {
                Write-RalphStatus "SUCCESS" "Graceful exit triggered: $exitReason"
                Reset-RalphSession -Reason "project_complete"
                Update-RalphStatus -LoopCount $script:LoopCount -CallsMade (Get-CallCount) -LastAction "graceful_exit" -Status "completed" -ExitReason $exitReason

                Write-RalphStatus "SUCCESS" "Ralph has completed the project! Final stats:"
                Write-RalphStatus "INFO" "  - Total loops: $($script:LoopCount)"
                Write-RalphStatus "INFO" "  - API calls used: $(Get-CallCount)"
                Write-RalphStatus "INFO" "  - Exit reason: $exitReason"

                break
            }

            # Update status
            $callsMade = Get-CallCount
            Update-RalphStatus -LoopCount $script:LoopCount -CallsMade $callsMade -LastAction "executing" -Status "running"

            # Execute Claude Code
            $execResult = Invoke-ClaudeCode -LoopCount $script:LoopCount

            switch ($execResult) {
                0 {
                    Update-RalphStatus -LoopCount $script:LoopCount -CallsMade (Get-CallCount) -LastAction "completed" -Status "success"
                    # Brief pause between successful executions
                    Start-Sleep -Seconds 5
                }
                3 {
                    # Circuit breaker opened
                    Reset-RalphSession -Reason "circuit_breaker_trip"
                    Update-RalphStatus -LoopCount $script:LoopCount -CallsMade (Get-CallCount) -LastAction "circuit_breaker_open" -Status "halted" -ExitReason "stagnation_detected"
                    Write-RalphStatus "ERROR" "Circuit breaker has opened - halting loop"
                    Write-RalphStatus "INFO" "Run 'ralph -ResetCircuit' to reset the circuit breaker after addressing issues"
                    break
                }
                2 {
                    # API 5-hour limit reached
                    Update-RalphStatus -LoopCount $script:LoopCount -CallsMade (Get-CallCount) -LastAction "api_limit" -Status "paused"
                    Write-RalphStatus "WARN" "Claude API 5-hour limit reached!"

                    Write-Host ""
                    Write-Host "$($script:Colors.Yellow)The Claude API 5-hour usage limit has been reached.$($script:Colors.Reset)"
                    Write-Host "$($script:Colors.Yellow)You can either:$($script:Colors.Reset)"
                    Write-Host "  $($script:Colors.Green)1)$($script:Colors.Reset) Wait for the limit to reset (usually within an hour)"
                    Write-Host "  $($script:Colors.Green)2)$($script:Colors.Reset) Exit the loop and try again later"
                    Write-Host ""
                    Write-Host "$($script:Colors.Blue)Choose an option (1 or 2):$($script:Colors.Reset) " -NoNewline

                    $userChoice = Read-Host

                    if ($userChoice -eq "2" -or [string]::IsNullOrEmpty($userChoice)) {
                        Write-RalphStatus "INFO" "User chose to exit. Exiting loop..."
                        Update-RalphStatus -LoopCount $script:LoopCount -CallsMade (Get-CallCount) -LastAction "api_limit_exit" -Status "stopped" -ExitReason "api_5hour_limit"
                        break
                    }
                    else {
                        Write-RalphStatus "INFO" "User chose to wait. Waiting for API limit reset..."
                        $waitMinutes = 60
                        Write-RalphStatus "INFO" "Waiting $waitMinutes minutes before retrying..."

                        $waitSeconds = $waitMinutes * 60
                        while ($waitSeconds -gt 0) {
                            $minutes = [int]($waitSeconds / 60)
                            $seconds = [int]($waitSeconds % 60)
                            Write-Host -NoNewline "`r$($script:Colors.Yellow)Time until retry: $($minutes.ToString('00')):$($seconds.ToString('00'))$($script:Colors.Reset)"
                            Start-Sleep -Seconds 1
                            $waitSeconds--
                        }
                        Write-Host ""
                    }
                }
                default {
                    Update-RalphStatus -LoopCount $script:LoopCount -CallsMade (Get-CallCount) -LastAction "failed" -Status "error"
                    Write-RalphStatus "WARN" "Execution failed, waiting 30 seconds before retry..."
                    Start-Sleep -Seconds 30
                }
            }

            Write-RalphStatus "LOOP" "=== Completed Loop #$($script:LoopCount) ==="
        }
    }
    finally {
        Unregister-Event -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

# Handle special command-line flags
if ($Status) {
    if (Test-Path $script:STATUS_FILE) {
        Write-Host "Current Status:"
        Get-Content $script:STATUS_FILE -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 10
    }
    else {
        Write-Host "No status file found. Ralph may not be running."
    }
    exit 0
}

if ($ResetCircuit) {
    Reset-CircuitBreaker -Reason "Manual reset via command line"
    Reset-RalphSession -Reason "manual_circuit_reset"
    exit 0
}

if ($ResetSession) {
    Reset-RalphSession -Reason "manual_reset_flag"
    Write-Host "$($script:Colors.Green)Session state reset successfully$($script:Colors.Reset)"
    exit 0
}

if ($CircuitStatus) {
    Show-CircuitStatus
    exit 0
}

# Validate allowed tools
if (-not (Test-AllowedTools -ToolsInput $script:CLAUDE_ALLOWED_TOOLS)) {
    exit 1
}

# Initialize directories
Initialize-Directories

# If monitor mode requested, set it up
if ($Monitor) {
    Start-WithMonitor
}

# Start the main loop
Start-RalphLoop
