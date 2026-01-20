#Requires -Version 5.1
<#
.SYNOPSIS
    Response Analyzer Component for Ralph.

.DESCRIPTION
    Analyzes Claude Code output to detect completion signals, test-only loops, and progress.
    Equivalent to lib/response_analyzer.sh in the bash implementation.
#>

# Import DateUtils module
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptPath "DateUtils.psm1") -Force

# ANSI Colors
$script:Colors = @{
    Red = "`e[31m"
    Green = "`e[32m"
    Yellow = "`e[33m"
    Blue = "`e[34m"
    Reset = "`e[0m"
}

# Analysis configuration
$script:COMPLETION_KEYWORDS = @("done", "complete", "finished", "all tasks complete", "project complete", "ready for review")
$script:TEST_ONLY_PATTERNS = @("npm test", "bats", "pytest", "jest", "cargo test", "go test", "running tests")
$script:NO_WORK_PATTERNS = @("nothing to do", "no changes", "already implemented", "up to date")

# Session file location
$script:SESSION_FILE = ".claude_session_id"
$script:SESSION_EXPIRATION_SECONDS = 86400  # 24 hours

# Session lifecycle management files
$script:RALPH_SESSION_FILE = ".ralph_session"
$script:RALPH_SESSION_HISTORY_FILE = ".ralph_session_history"

# =============================================================================
# JSON OUTPUT FORMAT DETECTION AND PARSING
# =============================================================================

# Detect output format (json or text)
# Returns: "json" if valid JSON, "text" otherwise
function Get-OutputFormat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputFile
    )

    if (-not (Test-Path $OutputFile)) {
        return "text"
    }

    $content = Get-Content $OutputFile -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) {
        return "text"
    }

    # Check if content starts with { or [ (JSON indicators)
    $firstChar = $content.Trim()[0]
    if ($firstChar -ne '{' -and $firstChar -ne '[') {
        return "text"
    }

    # Validate as JSON
    try {
        $null = $content | ConvertFrom-Json
        return "json"
    }
    catch {
        return "text"
    }
}

# Parse JSON response and extract structured fields
# Creates result file with normalized analysis data
function Read-JsonResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputFile,

        [Parameter(Mandatory = $false)]
        [string]$ResultFile = ".json_parse_result"
    )

    if (-not (Test-Path $OutputFile)) {
        Write-Error "Output file not found: $OutputFile"
        return $false
    }

    $content = Get-Content $OutputFile -Raw
    try {
        $json = $content | ConvertFrom-Json
    }
    catch {
        Write-Error "Invalid JSON in output file"
        return $false
    }

    # Detect JSON format by checking for Claude CLI fields
    $hasResultField = $null -ne $json.result

    # Extract fields - support both flat format and Claude CLI format
    # Status: from flat format OR derived from metadata.completion_status
    $status = if ($json.status) { $json.status } else { "UNKNOWN" }
    $completionStatus = if ($json.metadata.completion_status) { $json.metadata.completion_status } else { "" }
    if ($completionStatus -eq "complete" -or $completionStatus -eq "COMPLETE") {
        $status = "COMPLETE"
    }

    # Exit signal: from flat format OR derived from completion_status
    $exitSignal = if ($null -ne $json.exit_signal) { $json.exit_signal } else { $false }

    # Work type: from flat format
    $workType = if ($json.work_type) { $json.work_type } else { "UNKNOWN" }

    # Files modified: from flat format OR from metadata.files_changed
    $filesModified = if ($null -ne $json.metadata.files_changed) {
        [int]$json.metadata.files_changed
    } elseif ($null -ne $json.files_modified) {
        [int]$json.files_modified
    } else {
        0
    }

    # Error count: from flat format OR derived from metadata.has_errors
    $errorCount = if ($null -ne $json.error_count) { [int]$json.error_count } else { 0 }
    $hasErrors = if ($null -ne $json.metadata.has_errors) { $json.metadata.has_errors } else { $false }
    if ($hasErrors -and $errorCount -eq 0) {
        $errorCount = 1  # At least one error if has_errors is true
    }

    # Summary: from flat format OR from result field (Claude CLI format)
    $summary = if ($json.result) { $json.result } elseif ($json.summary) { $json.summary } else { "" }

    # Session ID: from Claude CLI format (sessionId) OR from metadata.session_id
    $sessionId = if ($json.sessionId) { $json.sessionId } elseif ($json.metadata.session_id) { $json.metadata.session_id } else { "" }

    # Loop number: from metadata
    $loopNumber = if ($null -ne $json.metadata.loop_number) {
        [int]$json.metadata.loop_number
    } elseif ($null -ne $json.loop_number) {
        [int]$json.loop_number
    } else {
        0
    }

    # Confidence: from flat format
    $confidence = if ($null -ne $json.confidence) { [int]$json.confidence } else { 0 }

    # Progress indicators: from Claude CLI metadata (optional)
    $progressCount = 0
    if ($json.metadata.progress_indicators) {
        $progressCount = @($json.metadata.progress_indicators).Count
    }

    # Normalize values
    if ($exitSignal -eq $true -or $status -eq "COMPLETE" -or $completionStatus -eq "complete" -or $completionStatus -eq "COMPLETE") {
        $exitSignal = $true
    }
    else {
        $exitSignal = $false
    }

    # Determine is_test_only from work_type
    $isTestOnly = $workType -eq "TEST_ONLY"

    # Determine is_stuck from error_count (threshold >5)
    $isStuck = $errorCount -gt 5

    # Calculate has_completion_signal
    $hasCompletionSignal = $status -eq "COMPLETE" -or $exitSignal -eq $true

    # Boost confidence based on structured data availability
    if ($hasResultField) {
        $confidence += 20  # Structured response boost
    }
    if ($progressCount -gt 0) {
        $confidence += $progressCount * 5  # Progress indicators boost
    }

    # Write normalized result
    $result = @{
        status = $status
        exit_signal = $exitSignal
        is_test_only = $isTestOnly
        is_stuck = $isStuck
        has_completion_signal = $hasCompletionSignal
        files_modified = $filesModified
        error_count = $errorCount
        summary = $summary
        loop_number = $loopNumber
        session_id = $sessionId
        confidence = $confidence
        metadata = @{
            loop_number = $loopNumber
            session_id = $sessionId
        }
    }

    $result | ConvertTo-Json -Depth 10 | Set-Content $ResultFile
    return $true
}

# Analyze Claude Code response and extract signals
function Invoke-ResponseAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputFile,

        [Parameter(Mandatory = $true)]
        [int]$LoopNumber,

        [Parameter(Mandatory = $false)]
        [string]$AnalysisResultFile = ".response_analysis"
    )

    # Initialize analysis result
    $hasCompletionSignal = $false
    $isTestOnly = $false
    $isStuck = $false
    $hasProgress = $false
    $confidenceScore = 0
    $exitSignal = $false
    $workSummary = ""
    $filesModified = 0

    # Read output file
    if (-not (Test-Path $OutputFile)) {
        Write-Error "Output file not found: $OutputFile"
        return $false
    }

    $outputContent = Get-Content $OutputFile -Raw
    $outputLength = $outputContent.Length

    # Detect output format and try JSON parsing first
    $outputFormat = Get-OutputFormat -OutputFile $OutputFile

    if ($outputFormat -eq "json") {
        # Try JSON parsing
        if (Read-JsonResponse -OutputFile $OutputFile -ResultFile ".json_parse_result") {
            $parseResult = Get-Content ".json_parse_result" -Raw | ConvertFrom-Json

            $hasCompletionSignal = $parseResult.has_completion_signal
            $exitSignal = $parseResult.exit_signal
            $isTestOnly = $parseResult.is_test_only
            $isStuck = $parseResult.is_stuck
            $workSummary = $parseResult.summary
            $filesModified = [int]$parseResult.files_modified
            $jsonConfidence = [int]$parseResult.confidence
            $sessionId = $parseResult.session_id

            # Persist session ID if present
            if (-not [string]::IsNullOrWhiteSpace($sessionId) -and $sessionId -ne "null") {
                Save-SessionId -SessionId $sessionId
                if ($env:VERBOSE_PROGRESS -eq "true") {
                    Write-Verbose "Persisted session ID: $sessionId"
                }
            }

            # JSON parsing provides high confidence
            if ($exitSignal) {
                $confidenceScore = 100
            }
            else {
                $confidenceScore = $jsonConfidence + 50
            }

            # Check for file changes via git (supplements JSON data)
            if (Get-Command git -ErrorAction SilentlyContinue) {
                try {
                    $gitFiles = @(git diff --name-only 2>$null)
                    if ($gitFiles.Count -gt 0) {
                        $hasProgress = $true
                        $filesModified = $gitFiles.Count
                    }
                }
                catch { }
            }

            # Write analysis results for JSON path
            $analysis = @{
                loop_number = $LoopNumber
                timestamp = (Get-IsoTimestamp)
                output_file = $OutputFile
                output_format = "json"
                analysis = @{
                    has_completion_signal = $hasCompletionSignal
                    is_test_only = $isTestOnly
                    is_stuck = $isStuck
                    has_progress = $hasProgress
                    files_modified = $filesModified
                    confidence_score = $confidenceScore
                    exit_signal = $exitSignal
                    work_summary = $workSummary
                    output_length = $outputLength
                }
            }

            $analysis | ConvertTo-Json -Depth 10 | Set-Content $AnalysisResultFile
            Remove-Item ".json_parse_result" -Force -ErrorAction SilentlyContinue
            return $true
        }
        # If JSON parsing failed, fall through to text parsing
    }

    # Text parsing fallback (original logic)
    $explicitExitSignalFound = $false

    # 1. Check for explicit structured output (if Claude follows schema)
    if ($outputContent -match "---RALPH_STATUS---") {
        # Parse structured output
        if ($outputContent -match "STATUS:\s*(\w+)") {
            $status = $Matches[1]
        }
        if ($outputContent -match "EXIT_SIGNAL:\s*(true|false)") {
            $exitSig = $Matches[1]
            $explicitExitSignalFound = $true
            if ($exitSig -eq "true") {
                $hasCompletionSignal = $true
                $exitSignal = $true
                $confidenceScore = 100
            }
            else {
                $exitSignal = $false
            }
        }
        elseif ($status -eq "COMPLETE") {
            $hasCompletionSignal = $true
            $exitSignal = $true
            $confidenceScore = 100
        }
    }

    # 2. Detect completion keywords in natural language output
    foreach ($keyword in $script:COMPLETION_KEYWORDS) {
        if ($outputContent -match [regex]::Escape($keyword)) {
            $hasCompletionSignal = $true
            $confidenceScore += 10
            break
        }
    }

    # 3. Detect test-only loops
    $testCommandCount = 0
    $implementationCount = 0
    $errorCount = 0

    $testMatches = [regex]::Matches($outputContent, "running tests|npm test|bats|pytest|jest", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $testCommandCount = $testMatches.Count

    $implMatches = [regex]::Matches($outputContent, "implementing|creating|writing|adding|function|class", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $implementationCount = $implMatches.Count

    if ($testCommandCount -gt 0 -and $implementationCount -eq 0) {
        $isTestOnly = $true
        $workSummary = "Test execution only, no implementation"
    }

    # 4. Detect stuck/error loops
    # Two-stage filtering to avoid counting JSON field names as errors
    $lines = $outputContent -split "`n"
    $filteredLines = $lines | Where-Object { $_ -notmatch '"[^"]*error[^"]*":' }
    $filteredContent = $filteredLines -join "`n"

    $errorMatches = [regex]::Matches($filteredContent, '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $errorCount = $errorMatches.Count

    if ($errorCount -gt 5) {
        $isStuck = $true
    }

    # 5. Detect "nothing to do" patterns
    foreach ($pattern in $script:NO_WORK_PATTERNS) {
        if ($outputContent -match [regex]::Escape($pattern)) {
            $hasCompletionSignal = $true
            $confidenceScore += 15
            $workSummary = "No work remaining"
            break
        }
    }

    # 6. Check for file changes (git integration)
    if (Get-Command git -ErrorAction SilentlyContinue) {
        try {
            $gitFiles = @(git diff --name-only 2>$null)
            $filesModified = $gitFiles.Count
            if ($filesModified -gt 0) {
                $hasProgress = $true
                $confidenceScore += 20
            }
        }
        catch { }
    }

    # 7. Analyze output length trends
    if (Test-Path ".last_output_length") {
        $lastLength = [int](Get-Content ".last_output_length" -Raw)
        if ($lastLength -gt 0) {
            $lengthRatio = [int]($outputLength * 100 / $lastLength)
            if ($lengthRatio -lt 50) {
                $confidenceScore += 10
            }
        }
    }
    $outputLength | Set-Content ".last_output_length"

    # 8. Extract work summary from output
    if ([string]::IsNullOrWhiteSpace($workSummary)) {
        $summaryMatch = [regex]::Match($outputContent, "(?i)(summary|completed|implemented).{0,100}")
        if ($summaryMatch.Success) {
            $workSummary = $summaryMatch.Value.Substring(0, [Math]::Min(100, $summaryMatch.Value.Length))
        }
        else {
            $workSummary = "Output analyzed, no explicit summary found"
        }
    }

    # 9. Determine exit signal based on confidence (heuristic)
    if (-not $explicitExitSignalFound) {
        if ($confidenceScore -ge 40 -or $hasCompletionSignal) {
            $exitSignal = $true
        }
    }

    # Write analysis results to file (text parsing path)
    $analysis = @{
        loop_number = $LoopNumber
        timestamp = (Get-IsoTimestamp)
        output_file = $OutputFile
        output_format = "text"
        analysis = @{
            has_completion_signal = $hasCompletionSignal
            is_test_only = $isTestOnly
            is_stuck = $isStuck
            has_progress = $hasProgress
            files_modified = $filesModified
            confidence_score = $confidenceScore
            exit_signal = $exitSignal
            work_summary = $workSummary
            output_length = $outputLength
        }
    }

    $analysis | ConvertTo-Json -Depth 10 | Set-Content $AnalysisResultFile
    return $true
}

# Update exit signals file based on analysis
function Update-ExitSignals {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$AnalysisFile = ".response_analysis",

        [Parameter(Mandatory = $false)]
        [string]$ExitSignalsFile = ".exit_signals"
    )

    if (-not (Test-Path $AnalysisFile)) {
        Write-Error "Analysis file not found: $AnalysisFile"
        return $false
    }

    $analysis = Get-Content $AnalysisFile -Raw | ConvertFrom-Json
    $isTestOnly = $analysis.analysis.is_test_only
    $hasCompletionSignal = $analysis.analysis.has_completion_signal
    $loopNumber = $analysis.loop_number
    $hasProgress = $analysis.analysis.has_progress

    # Read current exit signals
    $signals = @{
        test_only_loops = @()
        done_signals = @()
        completion_indicators = @()
    }
    if (Test-Path $ExitSignalsFile) {
        try {
            $signals = Get-Content $ExitSignalsFile -Raw | ConvertFrom-Json
            # Convert to hashtable for easier manipulation
            $signals = @{
                test_only_loops = @($signals.test_only_loops)
                done_signals = @($signals.done_signals)
                completion_indicators = @($signals.completion_indicators)
            }
        }
        catch { }
    }

    # Update test_only_loops array
    if ($isTestOnly) {
        $signals.test_only_loops = @($signals.test_only_loops) + $loopNumber
    }
    elseif ($hasProgress) {
        $signals.test_only_loops = @()
    }

    # Update done_signals array
    if ($hasCompletionSignal) {
        $signals.done_signals = @($signals.done_signals) + $loopNumber
    }

    # Update completion_indicators array (strong signals)
    $confidence = $analysis.analysis.confidence_score
    if ($confidence -ge 60) {
        $signals.completion_indicators = @($signals.completion_indicators) + $loopNumber
    }

    # Keep only last 5 signals (rolling window)
    if ($signals.test_only_loops.Count -gt 5) {
        $signals.test_only_loops = $signals.test_only_loops[-5..-1]
    }
    if ($signals.done_signals.Count -gt 5) {
        $signals.done_signals = $signals.done_signals[-5..-1]
    }
    if ($signals.completion_indicators.Count -gt 5) {
        $signals.completion_indicators = $signals.completion_indicators[-5..-1]
    }

    # Write updated signals
    $signals | ConvertTo-Json -Depth 10 | Set-Content $ExitSignalsFile
    return $true
}

# Log analysis results in human-readable format
function Write-AnalysisSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$AnalysisFile = ".response_analysis"
    )

    if (-not (Test-Path $AnalysisFile)) {
        return
    }

    $analysis = Get-Content $AnalysisFile -Raw | ConvertFrom-Json
    $loop = $analysis.loop_number
    $exitSig = $analysis.analysis.exit_signal
    $confidence = $analysis.analysis.confidence_score
    $testOnly = $analysis.analysis.is_test_only
    $filesChanged = $analysis.analysis.files_modified
    $summary = $analysis.analysis.work_summary

    Write-Host "$($script:Colors.Blue)============================================================$($script:Colors.Reset)"
    Write-Host "$($script:Colors.Blue)           Response Analysis - Loop #$loop                 $($script:Colors.Reset)"
    Write-Host "$($script:Colors.Blue)============================================================$($script:Colors.Reset)"
    Write-Host "$($script:Colors.Yellow)Exit Signal:$($script:Colors.Reset)      $exitSig"
    Write-Host "$($script:Colors.Yellow)Confidence:$($script:Colors.Reset)       $confidence%"
    Write-Host "$($script:Colors.Yellow)Test Only:$($script:Colors.Reset)        $testOnly"
    Write-Host "$($script:Colors.Yellow)Files Changed:$($script:Colors.Reset)    $filesChanged"
    Write-Host "$($script:Colors.Yellow)Summary:$($script:Colors.Reset)          $summary"
    Write-Host ""
}

# Detect if Claude is stuck (repeating same errors)
function Test-StuckLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentOutput,

        [Parameter(Mandatory = $false)]
        [string]$HistoryDir = "logs"
    )

    # Get last 3 output files
    $recentOutputs = Get-ChildItem "$HistoryDir\claude_output_*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 3

    if ($recentOutputs.Count -eq 0) {
        return $false  # Not enough history
    }

    # Extract key errors from current output using two-stage filtering
    $currentContent = Get-Content $CurrentOutput -Raw
    $lines = $currentContent -split "`n"
    $filteredLines = $lines | Where-Object { $_ -notmatch '"[^"]*error[^"]*":' }
    $filteredContent = $filteredLines -join "`n"

    $errorMatches = [regex]::Matches($filteredContent, '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)', [System.Text.RegularExpressions.RegexOptions]::Multiline)

    if ($errorMatches.Count -eq 0) {
        return $false  # No errors
    }

    $currentErrors = @($errorMatches | ForEach-Object { $_.Value } | Sort-Object | Get-Unique)

    # Check if same errors appear in all recent outputs
    $allFilesMatch = $true
    foreach ($outputFile in $recentOutputs) {
        $historyContent = Get-Content $outputFile.FullName -Raw
        $fileMatchesAll = $true

        foreach ($errorLine in $currentErrors) {
            if ($historyContent -notmatch [regex]::Escape($errorLine)) {
                $fileMatchesAll = $false
                break
            }
        }

        if (-not $fileMatchesAll) {
            $allFilesMatch = $false
            break
        }
    }

    return $allFilesMatch
}

# =============================================================================
# SESSION MANAGEMENT FUNCTIONS
# =============================================================================

# Store session ID to file with timestamp
function Save-SessionId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return $false
    }

    $sessionData = @{
        session_id = $SessionId
        timestamp = (Get-IsoTimestamp)
    }
    $sessionData | ConvertTo-Json -Depth 10 | Set-Content $script:SESSION_FILE
    return $true
}

# Get the last stored session ID
function Get-LastSessionId {
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:SESSION_FILE)) {
        return ""
    }

    try {
        $session = Get-Content $script:SESSION_FILE -Raw | ConvertFrom-Json
        return $session.session_id
    }
    catch {
        return ""
    }
}

# Check if the stored session should be resumed
function Test-ShouldResumeSession {
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:SESSION_FILE)) {
        return $false
    }

    try {
        $session = Get-Content $script:SESSION_FILE -Raw | ConvertFrom-Json
        $timestamp = $session.timestamp

        if ([string]::IsNullOrWhiteSpace($timestamp)) {
            return $false
        }

        # Calculate session age
        $now = Get-EpochSeconds
        $sessionTime = ConvertFrom-IsoTimestamp -Timestamp $timestamp

        if ($sessionTime -lt 0) {
            return $false
        }

        $age = $now - $sessionTime

        # Check if session is still valid (less than expiration time)
        return $age -lt $script:SESSION_EXPIRATION_SECONDS
    }
    catch {
        return $false
    }
}

# =============================================================================
# SESSION LIFECYCLE MANAGEMENT (v0.9.7+)
# =============================================================================

# Get session ID from ralph session file
function Get-SessionId {
    [CmdletBinding()]
    param()

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
function Reset-Session {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    # Log transition before clearing
    $oldSessionId = Get-SessionId
    if (-not [string]::IsNullOrWhiteSpace($oldSessionId)) {
        Write-SessionTransition -OldSessionId $oldSessionId -NewSessionId "" -Reason $Reason
    }

    # Clear session file
    Remove-Item $script:RALPH_SESSION_FILE -Force -ErrorAction SilentlyContinue
    Remove-Item $script:SESSION_FILE -Force -ErrorAction SilentlyContinue

    Write-Verbose "Session reset: $Reason"
}

# Log session transition to history file
function Write-SessionTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OldSessionId,

        [Parameter(Mandatory = $false)]
        [string]$NewSessionId = "",

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    # Read existing history
    $history = @()
    if (Test-Path $script:RALPH_SESSION_HISTORY_FILE) {
        try {
            $history = @(Get-Content $script:RALPH_SESSION_HISTORY_FILE -Raw | ConvertFrom-Json)
        }
        catch {
            $history = @()
        }
    }

    # Add new transition
    $transition = @{
        timestamp = (Get-IsoTimestamp)
        old_session_id = $OldSessionId
        new_session_id = $NewSessionId
        reason = $Reason
    }

    $history = @($history) + $transition

    # Keep only last 50 transitions
    if ($history.Count -gt 50) {
        $history = $history[-50..-1]
    }

    # Write updated history
    $history | ConvertTo-Json -Depth 10 | Set-Content $script:RALPH_SESSION_HISTORY_FILE
}

# Initialize session tracking
function Initialize-SessionTracking {
    [CmdletBinding()]
    param()

    # Create session file if it doesn't exist
    if (-not (Test-Path $script:RALPH_SESSION_FILE)) {
        $initialSession = @{
            session_id = ""
            timestamp = (Get-IsoTimestamp)
            loop_count = 0
        }
        $initialSession | ConvertTo-Json -Depth 10 | Set-Content $script:RALPH_SESSION_FILE
    }

    # Create history file if it doesn't exist
    if (-not (Test-Path $script:RALPH_SESSION_HISTORY_FILE)) {
        @() | ConvertTo-Json -Depth 10 | Set-Content $script:RALPH_SESSION_HISTORY_FILE
    }
}

# Export module members
Export-ModuleMember -Function @(
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
