#Requires -Version 5.1
<#
.SYNOPSIS
    Ralph for Claude Code - Global Installation Script.

.DESCRIPTION
    Installs Ralph for Claude Code globally on Windows.
    Creates wrapper scripts and adds Ralph to the system PATH.

.PARAMETER Uninstall
    Uninstall Ralph instead of installing

.PARAMETER Help
    Show help message

.EXAMPLE
    .\Install-Ralph.ps1
    Installs Ralph globally

.EXAMPLE
    .\Install-Ralph.ps1 -Uninstall
    Uninstalls Ralph
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Configuration
$script:INSTALL_DIR = Join-Path $env:LOCALAPPDATA "Ralph\bin"
$script:RALPH_HOME = Join-Path $env:USERPROFILE ".ralph"
$script:SCRIPT_DIR = $PSScriptRoot
if (-not $script:SCRIPT_DIR) {
    $script:SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
}

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

# Check dependencies
function Test-Dependencies {
    Write-Log "INFO" "Checking dependencies..."

    $missingDeps = @()

    if (-not (Get-Command node -ErrorAction SilentlyContinue) -and -not (Get-Command npx -ErrorAction SilentlyContinue)) {
        $missingDeps += "Node.js/npm"
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $missingDeps += "git"
    }

    if ($missingDeps.Count -gt 0) {
        Write-Log "ERROR" "Missing required dependencies: $($missingDeps -join ', ')"
        Write-Host "Please install the missing dependencies:"
        Write-Host "  - Node.js: https://nodejs.org/"
        Write-Host "  - Git: https://git-scm.com/"
        exit 1
    }

    Write-Log "INFO" "Claude Code CLI (@anthropic-ai/claude-code) will be downloaded when first used."

    Write-Log "SUCCESS" "Dependencies check completed"
}

# Create installation directories
function New-InstallDirectories {
    Write-Log "INFO" "Creating installation directories..."

    New-Item -ItemType Directory -Path $script:INSTALL_DIR -Force | Out-Null
    New-Item -ItemType Directory -Path $script:RALPH_HOME -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:RALPH_HOME "templates") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:RALPH_HOME "lib") -Force | Out-Null

    Write-Log "SUCCESS" "Directories created: $script:INSTALL_DIR, $script:RALPH_HOME"
}

# Install Ralph scripts
function Install-RalphScripts {
    Write-Log "INFO" "Installing Ralph scripts..."

    # Copy templates to Ralph home
    $templatesSource = Join-Path $script:SCRIPT_DIR "templates"
    $templatesDest = Join-Path $script:RALPH_HOME "templates"
    if (Test-Path $templatesSource) {
        Copy-Item -Path "$templatesSource\*" -Destination $templatesDest -Recurse -Force
    }

    # Copy lib modules to Ralph home
    $libSource = Join-Path $script:SCRIPT_DIR "lib"
    $libDest = Join-Path $script:RALPH_HOME "lib"
    if (Test-Path $libSource) {
        Copy-Item -Path "$libSource\*.psm1" -Destination $libDest -Force
    }

    # Copy main scripts to Ralph home
    $scriptsToInstall = @(
        "ralph_loop.ps1",
        "ralph_monitor.ps1",
        "ralph_import.ps1",
        "setup.ps1"
    )

    foreach ($script in $scriptsToInstall) {
        $sourcePath = Join-Path $script:SCRIPT_DIR $script
        if (Test-Path $sourcePath) {
            Copy-Item -Path $sourcePath -Destination $script:RALPH_HOME -Force
        }
    }

    # Create wrapper batch files for PATH
    # These allow running "ralph" from cmd.exe

    # ralph.cmd
    $ralphCmd = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.ralph\ralph_loop.ps1" %*
"@
    $ralphCmd | Set-Content (Join-Path $script:INSTALL_DIR "ralph.cmd")

    # ralph.ps1 (for PowerShell)
    $ralphPs1 = @'
#Requires -Version 5.1
& "$env:USERPROFILE\.ralph\ralph_loop.ps1" @args
'@
    $ralphPs1 | Set-Content (Join-Path $script:INSTALL_DIR "ralph.ps1")

    # ralph-monitor.cmd
    $monitorCmd = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.ralph\ralph_monitor.ps1" %*
"@
    $monitorCmd | Set-Content (Join-Path $script:INSTALL_DIR "ralph-monitor.cmd")

    # ralph-monitor.ps1
    $monitorPs1 = @'
#Requires -Version 5.1
& "$env:USERPROFILE\.ralph\ralph_monitor.ps1" @args
'@
    $monitorPs1 | Set-Content (Join-Path $script:INSTALL_DIR "ralph-monitor.ps1")

    # ralph-setup.cmd
    $setupCmd = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.ralph\setup.ps1" %*
"@
    $setupCmd | Set-Content (Join-Path $script:INSTALL_DIR "ralph-setup.cmd")

    # ralph-setup.ps1
    $setupPs1 = @'
#Requires -Version 5.1
& "$env:USERPROFILE\.ralph\setup.ps1" @args
'@
    $setupPs1 | Set-Content (Join-Path $script:INSTALL_DIR "ralph-setup.ps1")

    # ralph-import.cmd
    $importCmd = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.ralph\ralph_import.ps1" %*
"@
    $importCmd | Set-Content (Join-Path $script:INSTALL_DIR "ralph-import.cmd")

    # ralph-import.ps1
    $importPs1 = @'
#Requires -Version 5.1
& "$env:USERPROFILE\.ralph\ralph_import.ps1" @args
'@
    $importPs1 | Set-Content (Join-Path $script:INSTALL_DIR "ralph-import.ps1")

    Write-Log "SUCCESS" "Ralph scripts installed to $script:INSTALL_DIR"
}

# Add to PATH
function Add-ToPath {
    Write-Log "INFO" "Checking PATH configuration..."

    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")

    if ($currentPath -notlike "*$($script:INSTALL_DIR)*") {
        Write-Log "INFO" "Adding $($script:INSTALL_DIR) to user PATH..."

        $newPath = "$($script:INSTALL_DIR);$currentPath"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")

        # Also update current session
        $env:Path = "$($script:INSTALL_DIR);$env:Path"

        Write-Log "SUCCESS" "$($script:INSTALL_DIR) added to PATH"
        Write-Host ""
        Write-Host "$($script:Colors.Yellow)NOTE: You may need to restart your terminal for PATH changes to take effect.$($script:Colors.Reset)"
    }
    else {
        Write-Log "SUCCESS" "$($script:INSTALL_DIR) is already in PATH"
    }
}

# Main installation
function Install-Ralph {
    Write-Host "Installing Ralph for Claude Code globally..."
    Write-Host ""

    Test-Dependencies
    New-InstallDirectories
    Install-RalphScripts
    Add-ToPath

    Write-Host ""
    Write-Log "SUCCESS" "Ralph for Claude Code installed successfully!"
    Write-Host ""
    Write-Host "Global commands available:"
    Write-Host "  ralph -Monitor          # Start Ralph with monitoring"
    Write-Host "  ralph -Help             # Show Ralph options"
    Write-Host "  ralph-setup my-project  # Create new Ralph project"
    Write-Host "  ralph-import prd.md     # Convert PRD to Ralph project"
    Write-Host "  ralph-monitor           # Manual monitoring dashboard"
    Write-Host ""
    Write-Host "Quick start:"
    Write-Host "  1. ralph-setup my-awesome-project"
    Write-Host "  2. cd my-awesome-project"
    Write-Host "  3. # Edit PROMPT.md with your requirements"
    Write-Host "  4. ralph -Monitor"
    Write-Host ""
}

# Uninstall Ralph
function Uninstall-Ralph {
    Write-Host "Uninstalling Ralph for Claude Code..."
    Write-Host ""

    # Check if installed
    $installed = $false
    if (Test-Path $script:INSTALL_DIR) { $installed = $true }
    if (Test-Path $script:RALPH_HOME) { $installed = $true }

    if (-not $installed) {
        Write-Log "WARN" "Ralph does not appear to be installed"
        Write-Host "Checked locations:"
        Write-Host "  - $($script:INSTALL_DIR)"
        Write-Host "  - $($script:RALPH_HOME)"
        return
    }

    # Show what will be removed
    Write-Host ""
    Write-Log "INFO" "The following will be removed:"
    Write-Host ""

    if (Test-Path $script:INSTALL_DIR) {
        Write-Host "Commands in $($script:INSTALL_DIR):"
        Get-ChildItem $script:INSTALL_DIR -Filter "ralph*" | ForEach-Object {
            Write-Host "  - $($_.Name)"
        }
    }

    if (Test-Path $script:RALPH_HOME) {
        Write-Host ""
        Write-Host "Ralph home directory:"
        Write-Host "  - $($script:RALPH_HOME) (includes templates, scripts, and libraries)"
    }

    Write-Host ""

    # Confirm
    $confirm = Read-Host "Are you sure you want to uninstall Ralph? [y/N]"
    if ($confirm -notmatch '^[Yy]') {
        Write-Log "INFO" "Uninstallation cancelled"
        return
    }

    Write-Host ""

    # Remove commands
    Write-Log "INFO" "Removing Ralph commands..."
    if (Test-Path $script:INSTALL_DIR) {
        Remove-Item -Path $script:INSTALL_DIR -Recurse -Force
        Write-Log "SUCCESS" "Removed $($script:INSTALL_DIR)"
    }

    # Remove Ralph home
    Write-Log "INFO" "Removing Ralph home directory..."
    if (Test-Path $script:RALPH_HOME) {
        Remove-Item -Path $script:RALPH_HOME -Recurse -Force
        Write-Log "SUCCESS" "Removed $($script:RALPH_HOME)"
    }

    # Remove from PATH
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -like "*$($script:INSTALL_DIR)*") {
        $newPath = ($currentPath -split ';' | Where-Object { $_ -ne $script:INSTALL_DIR }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Log "INFO" "Removed $($script:INSTALL_DIR) from PATH"
    }

    Write-Host ""
    Write-Log "SUCCESS" "Ralph for Claude Code has been uninstalled"
    Write-Host ""
    Write-Host "Note: Project files created with ralph-setup are not removed."
    Write-Host "You can safely delete those project directories manually if needed."
    Write-Host ""
}

# Show help
function Show-InstallHelp {
    @"
Ralph for Claude Code - Installation Script

Usage: .\Install-Ralph.ps1 [OPTIONS]

Options:
  -Uninstall    Uninstall Ralph instead of installing
  -Help         Show this help message

This script installs:
  - Ralph commands to $($script:INSTALL_DIR)
  - Ralph home directory to $($script:RALPH_HOME)
  - Adds Ralph to the user PATH

Examples:
  .\Install-Ralph.ps1            # Install Ralph
  .\Install-Ralph.ps1 -Uninstall # Uninstall Ralph

"@ | Write-Host
}

# Main entry point
if ($Help) {
    Show-InstallHelp
    exit 0
}

if ($Uninstall) {
    Uninstall-Ralph
}
else {
    Install-Ralph
}
