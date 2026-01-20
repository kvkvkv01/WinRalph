#Requires -Version 5.1
<#
.SYNOPSIS
    Ralph for Claude Code - Uninstallation Script.

.DESCRIPTION
    Removes Ralph for Claude Code installation from Windows.

.PARAMETER Yes
    Skip confirmation prompt

.PARAMETER Help
    Show help message

.EXAMPLE
    .\Uninstall-Ralph.ps1
    Uninstalls Ralph with confirmation

.EXAMPLE
    .\Uninstall-Ralph.ps1 -Yes
    Uninstalls Ralph without confirmation
#>

[CmdletBinding()]
param(
    [Alias("y")]
    [switch]$Yes,

    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Configuration
$script:INSTALL_DIR = Join-Path $env:LOCALAPPDATA "Ralph\bin"
$script:RALPH_HOME = Join-Path $env:USERPROFILE ".ralph"

# ANSI Colors
$script:Colors = @{
    Red = "`e[31m"
    Green = "`e[32m"
    Yellow = "`e[33m"
    Blue = "`e[34m"
    Reset = "`e[0m"
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $color = switch ($Level) {
        "INFO" { $script:Colors.Blue }
        "WARN" { $script:Colors.Yellow }
        "ERROR" { $script:Colors.Red }
        "SUCCESS" { $script:Colors.Green }
    }

    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "$color[$timestamp] [$Level] $Message$($script:Colors.Reset)"
}

# Check if Ralph is installed
function Test-Installation {
    $installed = $false

    # Check for commands
    $commands = @("ralph.cmd", "ralph.ps1", "ralph-monitor.cmd", "ralph-setup.cmd", "ralph-import.cmd")
    foreach ($cmd in $commands) {
        if (Test-Path (Join-Path $script:INSTALL_DIR $cmd)) {
            $installed = $true
            break
        }
    }

    # Also check for Ralph home directory
    if (-not $installed -and (Test-Path $script:RALPH_HOME)) {
        $installed = $true
    }

    if (-not $installed) {
        Write-Log "WARN" "Ralph does not appear to be installed"
        Write-Host "Checked locations:"
        Write-Host "  - $($script:INSTALL_DIR)\{ralph,ralph-monitor,ralph-setup,ralph-import}.cmd"
        Write-Host "  - $($script:RALPH_HOME)"
        exit 0
    }
}

# Show what will be removed
function Show-RemovalPlan {
    Write-Host ""
    Write-Log "INFO" "The following will be removed:"
    Write-Host ""

    # Commands
    if (Test-Path $script:INSTALL_DIR) {
        Write-Host "Commands in $($script:INSTALL_DIR):"
        Get-ChildItem $script:INSTALL_DIR -Filter "ralph*" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "  - $($_.Name)"
        }
    }

    # Ralph home
    if (Test-Path $script:RALPH_HOME) {
        Write-Host ""
        Write-Host "Ralph home directory:"
        Write-Host "  - $($script:RALPH_HOME) (includes templates, scripts, and libraries)"
    }

    Write-Host ""
}

# Confirm uninstallation
function Confirm-Uninstall {
    param([switch]$SkipConfirmation)

    if ($SkipConfirmation) {
        return $true
    }

    $confirm = Read-Host "Are you sure you want to uninstall Ralph? [y/N]"
    if ($confirm -notmatch '^[Yy]') {
        Write-Log "INFO" "Uninstallation cancelled"
        exit 0
    }

    return $true
}

# Remove Ralph commands
function Remove-RalphCommands {
    Write-Log "INFO" "Removing Ralph commands..."

    if (Test-Path $script:INSTALL_DIR) {
        $removed = 0
        Get-ChildItem $script:INSTALL_DIR -Filter "ralph*" -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Force
            $removed++
        }

        # Remove the directory if empty
        if ((Get-ChildItem $script:INSTALL_DIR -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
            Remove-Item $script:INSTALL_DIR -Force -ErrorAction SilentlyContinue
            # Also remove parent Ralph directory if empty
            $parentDir = Split-Path $script:INSTALL_DIR -Parent
            if ((Get-ChildItem $parentDir -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
                Remove-Item $parentDir -Force -ErrorAction SilentlyContinue
            }
        }

        if ($removed -gt 0) {
            Write-Log "SUCCESS" "Removed $removed command(s) from $($script:INSTALL_DIR)"
        }
        else {
            Write-Log "INFO" "No commands found in $($script:INSTALL_DIR)"
        }
    }
    else {
        Write-Log "INFO" "No commands found in $($script:INSTALL_DIR)"
    }
}

# Remove Ralph home directory
function Remove-RalphHome {
    Write-Log "INFO" "Removing Ralph home directory..."

    if (Test-Path $script:RALPH_HOME) {
        Remove-Item -Path $script:RALPH_HOME -Recurse -Force
        Write-Log "SUCCESS" "Removed $($script:RALPH_HOME)"
    }
    else {
        Write-Log "INFO" "Ralph home directory not found"
    }
}

# Remove from PATH
function Remove-FromPath {
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")

    if ($currentPath -like "*$($script:INSTALL_DIR)*") {
        Write-Log "INFO" "Removing from PATH..."
        $newPath = ($currentPath -split ';' | Where-Object { $_ -ne $script:INSTALL_DIR -and $_ -ne "" }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Log "SUCCESS" "Removed $($script:INSTALL_DIR) from PATH"
    }
}

# Main uninstallation
function Uninstall-Ralph {
    param([switch]$SkipConfirmation)

    Write-Host "Uninstalling Ralph for Claude Code..."

    Test-Installation
    Show-RemovalPlan
    Confirm-Uninstall -SkipConfirmation:$SkipConfirmation

    Write-Host ""
    Remove-RalphCommands
    Remove-RalphHome
    Remove-FromPath

    Write-Host ""
    Write-Log "SUCCESS" "Ralph for Claude Code has been uninstalled"
    Write-Host ""
    Write-Host "Note: Project files created with ralph-setup are not removed."
    Write-Host "You can safely delete those project directories manually if needed."
    Write-Host ""
}

# Show help
function Show-UninstallHelp {
    @"
Ralph for Claude Code - Uninstallation Script

Usage: .\Uninstall-Ralph.ps1 [OPTIONS]

Options:
  -y, -Yes      Skip confirmation prompt
  -h, -Help     Show this help message

This script removes:
  - Ralph commands from $($script:INSTALL_DIR)
  - Ralph home directory ($($script:RALPH_HOME))
  - Ralph from the user PATH

Project directories created with ralph-setup are NOT removed.

"@ | Write-Host
}

# Main entry point
if ($Help) {
    Show-UninstallHelp
    exit 0
}

Uninstall-Ralph -SkipConfirmation:$Yes
