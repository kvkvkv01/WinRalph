#Requires -Version 5.1
<#
.SYNOPSIS
    Ralph Project Setup Script.

.DESCRIPTION
    Creates a new Ralph-managed project with the standard directory structure and templates.
    PowerShell port of setup.sh for native Windows support.

.PARAMETER ProjectName
    Name of the project to create (default: my-project)

.EXAMPLE
    .\setup.ps1 my-new-project
    Creates a new Ralph project called "my-new-project"
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ProjectName = "my-project"
)

$ErrorActionPreference = 'Stop'

# Get script directory for template paths
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Determine templates directory
# When installed globally, templates are in ~/.ralph/templates
# When running from source, templates are in the same directory as the script
$RalphHome = Join-Path $env:USERPROFILE ".ralph"
$TemplatesDir = Join-Path $RalphHome "templates"

if (-not (Test-Path $TemplatesDir)) {
    # Try source directory
    $TemplatesDir = Join-Path $ScriptDir "templates"
}

Write-Host "Setting up Ralph project: $ProjectName"

# Create project directory
New-Item -ItemType Directory -Path $ProjectName -Force | Out-Null
Push-Location $ProjectName

try {
    # Create structure
    $directories = @(
        "specs\stdlib",
        "src",
        "examples",
        "logs",
        "docs\generated"
    )

    foreach ($dir in $directories) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Copy templates
    $templateMappings = @{
        "PROMPT.md" = "PROMPT.md"
        "fix_plan.md" = "@fix_plan.md"
        "AGENT.md" = "@AGENT.md"
    }

    foreach ($mapping in $templateMappings.GetEnumerator()) {
        $sourcePath = Join-Path $TemplatesDir $mapping.Key
        if (Test-Path $sourcePath) {
            Copy-Item -Path $sourcePath -Destination $mapping.Value -Force
        }
        else {
            Write-Warning "Template not found: $sourcePath"
        }
    }

    # Copy specs templates if they exist
    $specsTemplatePath = Join-Path $TemplatesDir "specs"
    if (Test-Path $specsTemplatePath) {
        Copy-Item -Path "$specsTemplatePath\*" -Destination "specs\" -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Initialize git
    if (Get-Command git -ErrorAction SilentlyContinue) {
        git init 2>$null
        "# $ProjectName" | Set-Content "README.md"
        git add . 2>$null
        git commit -m "Initial Ralph project setup" 2>$null
    }
    else {
        Write-Warning "Git not found. Skipping git initialization."
        "# $ProjectName" | Set-Content "README.md"
    }

    Write-Host ""
    Write-Host "Project $ProjectName created!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Edit PROMPT.md with your project requirements"
    Write-Host "  2. Update specs\ with your project specifications"
    Write-Host "  3. Run: ralph" -ForegroundColor Cyan
    Write-Host "  4. Monitor: ralph-monitor" -ForegroundColor Cyan
}
finally {
    Pop-Location
}
