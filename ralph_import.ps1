#Requires -Version 5.1
<#
.SYNOPSIS
    Ralph Import - Convert PRDs to Ralph format using Claude Code.

.DESCRIPTION
    Converts Product Requirements Documents (PRD) or specifications into Ralph format
    using Claude Code to intelligently analyze and structure the content.
    PowerShell port of ralph_import.sh for native Windows support.

.PARAMETER SourceFile
    Path to your PRD/specification file (any format)

.PARAMETER ProjectName
    Name for the new Ralph project (optional, defaults to filename)

.PARAMETER Help
    Show help message

.EXAMPLE
    .\ralph_import.ps1 my-app-prd.md
    Imports PRD and creates a project named "my-app-prd"

.EXAMPLE
    .\ralph_import.ps1 requirements.txt my-awesome-app
    Imports PRD and creates a project named "my-awesome-app"
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$SourceFile,

    [Parameter(Position = 1)]
    [string]$ProjectName,

    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Configuration
$script:CLAUDE_CODE_CMD = "claude"
$script:CLAUDE_OUTPUT_FORMAT = "json"
$script:CLAUDE_ALLOWED_TOOLS = @('Read', 'Write', 'Bash(mkdir:*)', 'Bash(cp:*)')
$script:CLAUDE_MIN_VERSION = "2.0.76"

# Temporary file names
$script:CONVERSION_OUTPUT_FILE = ".ralph_conversion_output.json"
$script:CONVERSION_PROMPT_FILE = ".ralph_conversion_prompt.md"

# Parsed conversion result variables
$script:ParsedResult = ""
$script:ParsedSessionId = ""
$script:ParsedFilesChanged = 0
$script:ParsedHasErrors = $false
$script:ParsedCompletionStatus = ""
$script:ParsedErrorMessage = ""
$script:ParsedErrorCode = ""
$script:ParsedFilesCreated = @()
$script:ParsedMissingFiles = @()

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

# Detect response format (json or text)
function Get-ResponseFormat {
    param([string]$OutputFile)

    if (-not (Test-Path $OutputFile) -or (Get-Item $OutputFile).Length -eq 0) {
        return "text"
    }

    $content = Get-Content $OutputFile -Raw
    $firstChar = $content.Trim()[0]

    if ($firstChar -ne '{' -and $firstChar -ne '[') {
        return "text"
    }

    try {
        $null = $content | ConvertFrom-Json
        return "json"
    }
    catch {
        return "text"
    }
}

# Parse conversion response from JSON
function Read-ConversionResponse {
    param([string]$OutputFile)

    if (-not (Test-Path $OutputFile)) {
        return $false
    }

    try {
        $content = Get-Content $OutputFile -Raw
        $json = $content | ConvertFrom-Json

        # Extract fields from JSON response
        $script:ParsedResult = if ($json.result) { $json.result } elseif ($json.summary) { $json.summary } else { "" }
        $script:ParsedSessionId = if ($json.sessionId) { $json.sessionId } elseif ($json.session_id) { $json.session_id } else { "" }
        $script:ParsedFilesChanged = if ($null -ne $json.metadata.files_changed) { $json.metadata.files_changed } elseif ($null -ne $json.files_changed) { $json.files_changed } else { 0 }
        $script:ParsedHasErrors = if ($null -ne $json.metadata.has_errors) { $json.metadata.has_errors } elseif ($null -ne $json.has_errors) { $json.has_errors } else { $false }
        $script:ParsedCompletionStatus = if ($json.metadata.completion_status) { $json.metadata.completion_status } elseif ($json.completion_status) { $json.completion_status } else { "unknown" }
        $script:ParsedErrorMessage = if ($json.metadata.error_message) { $json.metadata.error_message } elseif ($json.error_message) { $json.error_message } else { "" }
        $script:ParsedErrorCode = if ($json.metadata.error_code) { $json.metadata.error_code } elseif ($json.error_code) { $json.error_code } else { "" }
        $script:ParsedFilesCreated = if ($json.metadata.files_created) { @($json.metadata.files_created) } else { @() }
        $script:ParsedMissingFiles = if ($json.metadata.missing_files) { @($json.metadata.missing_files) } else { @() }

        return $true
    }
    catch {
        Write-Log "WARN" "Failed to parse JSON response: $_"
        return $false
    }
}

# Check Claude CLI version
function Test-ClaudeVersion {
    try {
        $versionOutput = & $script:CLAUDE_CODE_CMD --version 2>$null
        $version = [regex]::Match($versionOutput, '\d+\.\d+\.\d+').Value

        if ([string]::IsNullOrEmpty($version)) {
            Write-Log "WARN" "Could not determine Claude Code CLI version"
            return $false
        }

        $verParts = $version.Split('.')
        $minParts = $script:CLAUDE_MIN_VERSION.Split('.')

        $verNum = [int]$verParts[0] * 10000 + [int]$verParts[1] * 100 + [int]$verParts[2]
        $minNum = [int]$minParts[0] * 10000 + [int]$minParts[1] * 100 + [int]$minParts[2]

        if ($verNum -lt $minNum) {
            Write-Log "WARN" "Claude Code CLI version $version is below recommended $($script:CLAUDE_MIN_VERSION)"
            return $false
        }

        return $true
    }
    catch {
        Write-Log "WARN" "Could not check Claude Code CLI version: $_"
        return $false
    }
}

function Show-HelpMessage {
    @"
Ralph Import - Convert PRDs to Ralph Format

Usage: ralph_import.ps1 <source-file> [project-name]

Arguments:
    source-file     Path to your PRD/specification file (any format)
    project-name    Name for the new Ralph project (optional, defaults to filename)

Examples:
    .\ralph_import.ps1 my-app-prd.md
    .\ralph_import.ps1 requirements.txt my-awesome-app
    .\ralph_import.ps1 project-spec.json
    .\ralph_import.ps1 design-doc.docx webapp

Supported formats:
    - Markdown (.md)
    - Text files (.txt)
    - JSON (.json)
    - Word documents (.docx)
    - PDFs (.pdf)
    - Any text-based format

The command will:
1. Create a new Ralph project
2. Use Claude Code to intelligently convert your PRD into:
   - PROMPT.md (Ralph instructions)
   - @fix_plan.md (prioritized tasks)
   - specs/ (technical specifications)

"@ | Write-Host
}

# Check dependencies
function Test-Dependencies {
    # Check for ralph-setup
    $ralphSetup = Get-Command ralph-setup -ErrorAction SilentlyContinue
    if (-not $ralphSetup) {
        # Try to find setup.ps1 in script directory
        $scriptDir = $PSScriptRoot
        if (-not $scriptDir) {
            $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        }
        $setupScript = Join-Path $scriptDir "setup.ps1"
        if (-not (Test-Path $setupScript)) {
            $ralphHome = Join-Path $env:USERPROFILE ".ralph"
            $setupScript = Join-Path $ralphHome "setup.ps1"
            if (-not (Test-Path $setupScript)) {
                Write-Log "ERROR" "Ralph not installed. Run Install-Ralph.ps1 first"
                exit 1
            }
        }
    }

    # Check for Claude Code CLI
    try {
        $null = & npx @anthropic/claude-code --version 2>$null
    }
    catch {
        Write-Log "WARN" "Claude Code CLI not found. It will be downloaded when first used."
    }
}

# Convert PRD using Claude Code
function Convert-Prd {
    param(
        [string]$SourceFile,
        [string]$ProjectName
    )

    $useModernCli = $true
    Write-Log "INFO" "Converting PRD to Ralph format using Claude Code..."

    # Check for modern CLI support
    if (-not (Test-ClaudeVersion)) {
        Write-Log "INFO" "Using standard CLI mode (modern features may not be available)"
        $useModernCli = $false
    }
    else {
        Write-Log "INFO" "Using modern CLI with JSON output format"
    }

    # Create conversion prompt
    $conversionPrompt = @'
# PRD to Ralph Conversion Task

You are tasked with converting a Product Requirements Document (PRD) or specification into Ralph for Claude Code format.

## Input Analysis
Analyze the provided specification file and extract:
- Project goals and objectives
- Core features and requirements
- Technical constraints and preferences
- Priority levels and phases
- Success criteria

## Required Outputs

Create these files in the current directory:

### 1. PROMPT.md
Transform the PRD into Ralph development instructions:
```markdown
# Ralph Development Instructions

## Context
You are Ralph, an autonomous AI development agent working on a [PROJECT NAME] project.

## Current Objectives
[Extract and prioritize 4-6 main objectives from the PRD]

## Key Principles
- ONE task per loop - focus on the most important thing
- Search the codebase before assuming something isn't implemented
- Use subagents for expensive operations (file searching, analysis)
- Write comprehensive tests with clear documentation
- Update @fix_plan.md with your learnings
- Commit working changes with descriptive messages

## Testing Guidelines (CRITICAL)
- LIMIT testing to ~20% of your total effort per loop
- PRIORITIZE: Implementation > Documentation > Tests
- Only write tests for NEW functionality you implement
- Do NOT refactor existing tests unless broken
- Focus on CORE functionality first, comprehensive testing later

## Project Requirements
[Convert PRD requirements into clear, actionable development requirements]

## Technical Constraints
[Extract any technical preferences, frameworks, languages mentioned]

## Success Criteria
[Define what "done" looks like based on the PRD]

## Current Task
Follow @fix_plan.md and choose the most important item to implement next.
```

### 2. @fix_plan.md
Convert requirements into a prioritized task list:
```markdown
# Ralph Fix Plan

## High Priority
[Extract and convert critical features into actionable tasks]

## Medium Priority
[Secondary features and enhancements]

## Low Priority
[Nice-to-have features and optimizations]

## Completed
- [x] Project initialization

## Notes
[Any important context from the original PRD]
```

### 3. specs/requirements.md
Create detailed technical specifications:
```markdown
# Technical Specifications

[Convert PRD into detailed technical requirements including:]
- System architecture requirements
- Data models and structures
- API specifications
- User interface requirements
- Performance requirements
- Security considerations
- Integration requirements

[Preserve all technical details from the original PRD]
```

## Instructions
1. Read and analyze the attached specification file
2. Create the three files above with content derived from the PRD
3. Ensure all requirements are captured and properly prioritized
4. Make the PROMPT.md actionable for autonomous development
5. Structure @fix_plan.md with clear, implementable tasks

'@

    # Append the PRD source content to the conversion prompt
    $sourceBasename = Split-Path -Leaf $SourceFile

    if (Test-Path $SourceFile) {
        $sourceContent = Get-Content $SourceFile -Raw
        $fullPrompt = @"
$conversionPrompt

---

## Source PRD File: $sourceBasename

$sourceContent
"@
        $fullPrompt | Set-Content $script:CONVERSION_PROMPT_FILE -Encoding UTF8
    }
    else {
        Write-Log "ERROR" "Source file not found: $SourceFile"
        Remove-Item $script:CONVERSION_PROMPT_FILE -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # Build and execute Claude Code command
    $stderrFile = "$($script:CONVERSION_OUTPUT_FILE).err"
    $cliExitCode = 0

    try {
        if ($useModernCli) {
            # Modern CLI invocation with JSON output
            $promptContent = Get-Content $script:CONVERSION_PROMPT_FILE -Raw
            $claudeArgs = @("--output-format", $script:CLAUDE_OUTPUT_FORMAT, "--allowedTools") + $script:CLAUDE_ALLOWED_TOOLS + @("-p", $promptContent)

            $result = & $script:CLAUDE_CODE_CMD @claudeArgs 2>$stderrFile
            $result | Out-File -FilePath $script:CONVERSION_OUTPUT_FILE -Encoding UTF8
            $cliExitCode = $LASTEXITCODE
        }
        else {
            # Standard CLI invocation
            $promptContent = Get-Content $script:CONVERSION_PROMPT_FILE -Raw
            $result = $promptContent | & $script:CLAUDE_CODE_CMD 2>$stderrFile
            $result | Out-File -FilePath $script:CONVERSION_OUTPUT_FILE -Encoding UTF8
            $cliExitCode = $LASTEXITCODE
        }
    }
    catch {
        Write-Log "ERROR" "Claude Code execution failed: $_"
        $cliExitCode = 1
    }

    # Log stderr if there was any
    if ((Test-Path $stderrFile) -and (Get-Item $stderrFile).Length -gt 0) {
        Write-Log "WARN" "CLI stderr output detected (see $stderrFile)"
    }

    # Process the response
    $outputFormat = "text"
    $jsonParsed = $false

    if (Test-Path $script:CONVERSION_OUTPUT_FILE) {
        $outputFormat = Get-ResponseFormat $script:CONVERSION_OUTPUT_FILE

        if ($outputFormat -eq "json") {
            if (Read-ConversionResponse $script:CONVERSION_OUTPUT_FILE) {
                $jsonParsed = $true
                Write-Log "INFO" "Parsed JSON response from Claude CLI"

                # Check for errors in JSON response
                if ($script:ParsedHasErrors -and $script:ParsedCompletionStatus -eq "failed") {
                    Write-Log "ERROR" "PRD conversion failed"
                    if (-not [string]::IsNullOrEmpty($script:ParsedErrorMessage)) {
                        Write-Log "ERROR" "Error: $($script:ParsedErrorMessage)"
                    }
                    if (-not [string]::IsNullOrEmpty($script:ParsedErrorCode)) {
                        Write-Log "ERROR" "Error code: $($script:ParsedErrorCode)"
                    }
                    Remove-Item $script:CONVERSION_PROMPT_FILE, $script:CONVERSION_OUTPUT_FILE, $stderrFile -Force -ErrorAction SilentlyContinue
                    exit 1
                }

                # Log session ID if available
                if (-not [string]::IsNullOrEmpty($script:ParsedSessionId) -and $script:ParsedSessionId -ne "null") {
                    Write-Log "INFO" "Session ID: $($script:ParsedSessionId)"
                }

                # Log files changed from metadata
                if ($script:ParsedFilesChanged -gt 0) {
                    Write-Log "INFO" "Files changed: $($script:ParsedFilesChanged)"
                }
            }
        }
    }

    # Check CLI exit code
    if ($cliExitCode -ne 0) {
        Write-Log "ERROR" "PRD conversion failed (exit code: $cliExitCode)"
        Remove-Item $script:CONVERSION_PROMPT_FILE, $script:CONVERSION_OUTPUT_FILE, $stderrFile -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # Success message
    if ($jsonParsed -and -not [string]::IsNullOrEmpty($script:ParsedResult) -and $script:ParsedResult -ne "null") {
        Write-Log "SUCCESS" "PRD conversion completed: $($script:ParsedResult)"
    }
    else {
        Write-Log "SUCCESS" "PRD conversion completed"
    }

    # Clean up temp files
    Remove-Item $script:CONVERSION_PROMPT_FILE, $script:CONVERSION_OUTPUT_FILE, $stderrFile -Force -ErrorAction SilentlyContinue

    # Verify files were created
    $missingFiles = @()
    $createdFiles = @()
    $expectedFiles = @("PROMPT.md", "@fix_plan.md", "specs\requirements.md")

    # If JSON provided files_created, use that
    if ($jsonParsed -and $script:ParsedFilesCreated.Count -gt 0) {
        foreach ($file in $script:ParsedFilesCreated) {
            if (Test-Path $file) {
                $createdFiles += $file
            }
            else {
                $missingFiles += $file
            }
        }
    }

    # Always verify expected files exist
    foreach ($file in $expectedFiles) {
        if (Test-Path $file) {
            if ($createdFiles -notcontains $file) {
                $createdFiles += $file
            }
        }
        else {
            if ($missingFiles -notcontains $file) {
                $missingFiles += $file
            }
        }
    }

    # Report created files
    if ($createdFiles.Count -gt 0) {
        Write-Log "INFO" "Created files: $($createdFiles -join ', ')"
    }

    # Report missing files
    if ($missingFiles.Count -gt 0) {
        Write-Log "WARN" "Some files were not created: $($missingFiles -join ', ')"

        if ($jsonParsed -and $script:ParsedMissingFiles.Count -gt 0) {
            Write-Log "INFO" "Missing files reported by Claude: $($script:ParsedMissingFiles -join ', ')"
        }

        Write-Log "INFO" "You may need to create these files manually or run the conversion again"
    }
}

# Main function
function Start-Import {
    param(
        [string]$SourceFile,
        [string]$ProjectName
    )

    # Validate arguments
    if ([string]::IsNullOrEmpty($SourceFile)) {
        Write-Log "ERROR" "Source file is required"
        Show-HelpMessage
        exit 1
    }

    if (-not (Test-Path $SourceFile)) {
        Write-Log "ERROR" "Source file does not exist: $SourceFile"
        exit 1
    }

    # Default project name from filename
    if ([string]::IsNullOrEmpty($ProjectName)) {
        $ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($SourceFile)
    }

    Write-Log "INFO" "Converting PRD: $SourceFile"
    Write-Log "INFO" "Project name: $ProjectName"

    Test-Dependencies

    # Create project directory
    Write-Log "INFO" "Creating Ralph project: $ProjectName"

    # Find ralph-setup or setup.ps1
    $ralphSetup = Get-Command ralph-setup -ErrorAction SilentlyContinue
    if ($ralphSetup) {
        & ralph-setup $ProjectName
    }
    else {
        $scriptDir = $PSScriptRoot
        if (-not $scriptDir) {
            $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        }
        $setupScript = Join-Path $scriptDir "setup.ps1"
        if (-not (Test-Path $setupScript)) {
            $ralphHome = Join-Path $env:USERPROFILE ".ralph"
            $setupScript = Join-Path $ralphHome "setup.ps1"
        }
        & $setupScript $ProjectName
    }

    Push-Location $ProjectName

    try {
        # Copy source file to project
        $sourceBasename = Split-Path -Leaf $SourceFile
        Copy-Item "..\$SourceFile" $sourceBasename -Force

        # Run conversion
        Convert-Prd $sourceBasename $ProjectName

        Write-Log "SUCCESS" "PRD imported successfully!"
        Write-Host ""
        Write-Host "Next steps:"
        Write-Host "  1. Review and edit the generated files:"
        Write-Host "     - PROMPT.md (Ralph instructions)"
        Write-Host "     - @fix_plan.md (task priorities)"
        Write-Host "     - specs\requirements.md (technical specs)"
        Write-Host "  2. Start autonomous development:"
        Write-Host "     ralph -Monitor" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Project created in: $(Get-Location)"
    }
    finally {
        Pop-Location
    }
}

# Handle command line arguments
if ($Help -or [string]::IsNullOrEmpty($SourceFile)) {
    Show-HelpMessage
    exit 0
}

Start-Import -SourceFile $SourceFile -ProjectName $ProjectName
