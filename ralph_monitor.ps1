#Requires -Version 5.1
<#
.SYNOPSIS
    Ralph Status Monitor - Live terminal dashboard for the Ralph loop.

.DESCRIPTION
    Displays a live dashboard showing Ralph loop status, progress, and recent activity.
    PowerShell port of ralph_monitor.sh for native Windows support.

.PARAMETER RefreshInterval
    Refresh interval in seconds (default: 2)
#>

[CmdletBinding()]
param(
    [int]$RefreshInterval = 2
)

$ErrorActionPreference = 'Continue'

$script:STATUS_FILE = "status.json"
$script:LOG_FILE = "logs\ralph.log"

# ANSI Colors
$script:Colors = @{
    Red = "`e[31m"
    Green = "`e[32m"
    Yellow = "`e[33m"
    Blue = "`e[34m"
    Purple = "`e[35m"
    Cyan = "`e[36m"
    White = "`e[97m"
    Reset = "`e[0m"
}

# Hide cursor
function Hide-Cursor {
    Write-Host "`e[?25l" -NoNewline
}

# Show cursor
function Show-Cursor {
    Write-Host "`e[?25h" -NoNewline
}

# Clear screen
function Clear-Display {
    Clear-Host
    Hide-Cursor
}

# Cleanup function
function Invoke-MonitorCleanup {
    Show-Cursor
    Write-Host ""
    Write-Host "Monitor stopped."
}

# Register cleanup on exit
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Show-Cursor
}

# Main display function
function Show-Status {
    Clear-Display

    # Header
    Write-Host "$($script:Colors.White)=========================================================================$($script:Colors.Reset)"
    Write-Host "$($script:Colors.White)                           RALPH MONITOR                                $($script:Colors.Reset)"
    Write-Host "$($script:Colors.White)                        Live Status Dashboard                           $($script:Colors.Reset)"
    Write-Host "$($script:Colors.White)=========================================================================$($script:Colors.Reset)"
    Write-Host ""

    # Status section
    if (Test-Path $script:STATUS_FILE) {
        try {
            $statusData = Get-Content $script:STATUS_FILE -Raw | ConvertFrom-Json

            $loopCount = if ($statusData.loop_count) { $statusData.loop_count } else { "0" }
            $callsMade = if ($statusData.calls_made_this_hour) { $statusData.calls_made_this_hour } else { "0" }
            $maxCalls = if ($statusData.max_calls_per_hour) { $statusData.max_calls_per_hour } else { "100" }
            $status = if ($statusData.status) { $statusData.status } else { "unknown" }

            Write-Host "$($script:Colors.Cyan)--- Current Status -------------------------------------------------------$($script:Colors.Reset)"
            Write-Host "$($script:Colors.Cyan)|$($script:Colors.Reset) Loop Count:     $($script:Colors.White)#$loopCount$($script:Colors.Reset)"
            Write-Host "$($script:Colors.Cyan)|$($script:Colors.Reset) Status:         $($script:Colors.Green)$status$($script:Colors.Reset)"
            Write-Host "$($script:Colors.Cyan)|$($script:Colors.Reset) API Calls:      $callsMade/$maxCalls"
            Write-Host "$($script:Colors.Cyan)-------------------------------------------------------------------------$($script:Colors.Reset)"
            Write-Host ""
        }
        catch {
            Write-Host "$($script:Colors.Red)--- Status ---------------------------------------------------------------$($script:Colors.Reset)"
            Write-Host "$($script:Colors.Red)|$($script:Colors.Reset) Error reading status file: $_"
            Write-Host "$($script:Colors.Red)-------------------------------------------------------------------------$($script:Colors.Reset)"
            Write-Host ""
        }
    }
    else {
        Write-Host "$($script:Colors.Red)--- Status ---------------------------------------------------------------$($script:Colors.Reset)"
        Write-Host "$($script:Colors.Red)|$($script:Colors.Reset) Status file not found. Ralph may not be running."
        Write-Host "$($script:Colors.Red)-------------------------------------------------------------------------$($script:Colors.Reset)"
        Write-Host ""
    }

    # Claude Code Progress section
    if (Test-Path "progress.json") {
        try {
            $progressData = Get-Content "progress.json" -Raw | ConvertFrom-Json
            $progressStatus = if ($progressData.status) { $progressData.status } else { "idle" }

            if ($progressStatus -eq "executing") {
                $indicator = if ($progressData.indicator) { $progressData.indicator } else { "..." }
                $elapsed = if ($progressData.elapsed_seconds) { $progressData.elapsed_seconds } else { "0" }
                $lastOutput = if ($progressData.last_output) { $progressData.last_output } else { "" }

                Write-Host "$($script:Colors.Yellow)--- Claude Code Progress -------------------------------------------------$($script:Colors.Reset)"
                Write-Host "$($script:Colors.Yellow)|$($script:Colors.Reset) Status:         $indicator Working (${elapsed}s elapsed)"
                if (-not [string]::IsNullOrWhiteSpace($lastOutput)) {
                    # Truncate long output for display
                    $displayOutput = $lastOutput.Substring(0, [Math]::Min(60, $lastOutput.Length))
                    Write-Host "$($script:Colors.Yellow)|$($script:Colors.Reset) Output:         $displayOutput..."
                }
                Write-Host "$($script:Colors.Yellow)-------------------------------------------------------------------------$($script:Colors.Reset)"
                Write-Host ""
            }
        }
        catch { }
    }

    # Recent logs
    Write-Host "$($script:Colors.Blue)--- Recent Activity ------------------------------------------------------$($script:Colors.Reset)"
    if (Test-Path $script:LOG_FILE) {
        $logLines = Get-Content $script:LOG_FILE -Tail 8 -ErrorAction SilentlyContinue
        foreach ($line in $logLines) {
            Write-Host "$($script:Colors.Blue)|$($script:Colors.Reset) $line"
        }
    }
    else {
        Write-Host "$($script:Colors.Blue)|$($script:Colors.Reset) No log file found"
    }
    Write-Host "$($script:Colors.Blue)-------------------------------------------------------------------------$($script:Colors.Reset)"

    # Footer
    Write-Host ""
    $currentTime = Get-Date -Format "HH:mm:ss"
    Write-Host "$($script:Colors.Yellow)Controls: Ctrl+C to exit | Refreshes every ${RefreshInterval}s | $currentTime$($script:Colors.Reset)"
}

# Main monitor loop
function Start-Monitor {
    Write-Host "Starting Ralph Monitor..."
    Start-Sleep -Seconds 2

    try {
        while ($true) {
            Show-Status
            Start-Sleep -Seconds $RefreshInterval
        }
    }
    finally {
        Invoke-MonitorCleanup
    }
}

# Run the monitor
Start-Monitor
