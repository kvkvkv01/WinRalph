# WinRalph - Ralph for Claude Code (PowerShell Edition)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Version](https://img.shields.io/badge/version-1.0.0-blue)
![Platform](https://img.shields.io/badge/platform-Windows%20PowerShell-blue)

> **Native Windows PowerShell port of the Ralph autonomous AI development loop**

WinRalph is a complete PowerShell port of [Ralph for Claude Code](https://github.com/frankbria/ralph-claude-code), enabling Windows users to run autonomous AI development cycles without WSL or Cygwin.

## Features

- **Native PowerShell** - No bash, WSL, or Unix tools required
- **Autonomous Development Loop** - Continuously executes Claude Code with your project requirements
- **Intelligent Exit Detection** - Dual-condition check requiring BOTH completion indicators AND explicit EXIT_SIGNAL
- **Session Continuity** - Preserves context across loop iterations with automatic session management
- **Rate Limiting** - Built-in API call management with hourly limits and countdown timers
- **Circuit Breaker** - Advanced error detection with automatic recovery
- **Live Monitoring** - Real-time dashboard using Windows Terminal tabs
- **PRD Import** - Convert existing requirements documents to Ralph format

## Quick Start

### Phase 1: Install Ralph (One Time)

```powershell
# Clone the repository
git clone https://github.com/kvkvkv01/WinRalph.git
cd WinRalph

# Install globally
.\Install-Ralph.ps1
```

This adds `ralph`, `ralph-monitor`, `ralph-setup`, and `ralph-import` commands to your PATH.

### Phase 2: Create Projects

```powershell
# Option A: Import existing PRD/specs
ralph-import my-requirements.md my-project
cd my-project
ralph -Monitor

# Option B: Create blank project
ralph-setup my-awesome-project
cd my-awesome-project
# Edit PROMPT.md with your requirements
ralph -Monitor
```

### Uninstalling

```powershell
.\Uninstall-Ralph.ps1
# Or with -Yes to skip confirmation
.\Uninstall-Ralph.ps1 -Yes
```

## Command Reference

### Ralph Loop Options

```powershell
ralph [OPTIONS]
  -Calls <int>          Max API calls per hour (default: 100)
  -Prompt <string>      Prompt file path (default: PROMPT.md)
  -Timeout <int>        Execution timeout in minutes (1-120, default: 15)
  -Status               Show current status and exit
  -Monitor              Start with Windows Terminal monitoring
  -ResetCircuit         Reset the circuit breaker
  -CircuitStatus        Show circuit breaker status
  -ResetSession         Reset session state manually
  -OutputFormat <str>   Output format: json (default) or text
  -AllowedTools <str>   Allowed Claude tools (comma-separated)
  -NoContinue           Disable session continuity
  -SessionExpiry <int>  Session expiration in hours (default: 24)
```

### Examples

```powershell
# Start with monitoring (recommended)
ralph -Monitor

# Custom rate limit and timeout
ralph -Monitor -Calls 50 -Timeout 30

# Check status
ralph -Status

# Reset circuit breaker after fixing issues
ralph -ResetCircuit

# Start fresh without session context
ralph -NoContinue
```

## Project Structure

```
my-project/
├── PROMPT.md           # Main development instructions for Ralph
├── @fix_plan.md        # Prioritized task list
├── @AGENT.md           # Build and run instructions
├── specs/              # Project specifications
├── src/                # Source code
├── logs/               # Execution logs
└── docs/generated/     # Auto-generated documentation
```

## How It Works

1. **Read Instructions** - Loads `PROMPT.md` with your project requirements
2. **Execute Claude Code** - Runs Claude Code with current context
3. **Track Progress** - Updates task lists and logs results
4. **Evaluate Completion** - Checks for exit conditions
5. **Repeat** - Continues until complete or limits reached

### Intelligent Exit Detection

Exit requires BOTH conditions:
1. `completion_indicators >= 2` (from natural language patterns)
2. Claude's explicit `EXIT_SIGNAL: true` in RALPH_STATUS block

This prevents premature exits when Claude is still working.

## System Requirements

- **Windows 10/11** with PowerShell 5.1+
- **Node.js** - For Claude Code CLI
- **Git** - For version control
- **Windows Terminal** (optional) - For integrated monitoring

### Installing Dependencies

```powershell
# Install Node.js from https://nodejs.org/
# Or via winget:
winget install OpenJS.NodeJS

# Install Git from https://git-scm.com/
# Or via winget:
winget install Git.Git
```

## Configuration

### Rate Limiting

```powershell
# Default: 100 calls per hour
ralph -Calls 50

# Check current usage
ralph -Status
```

### Circuit Breaker

The circuit breaker automatically:
- Opens after 3 loops with no progress
- Opens after 5 loops with repeated errors
- Recovers with half-open monitoring state

```powershell
# Check circuit breaker status
ralph -CircuitStatus

# Reset after fixing issues
ralph -ResetCircuit
```

### Session Management

```powershell
# Sessions are enabled by default
ralph -Monitor

# Disable session continuity
ralph -NoContinue

# Reset session manually
ralph -ResetSession

# Configure expiration (default: 24 hours)
ralph -SessionExpiry 48
```

## Module Structure

WinRalph uses PowerShell modules for clean organization:

```
WinRalph/
├── lib/
│   ├── DateUtils.psm1        # Cross-platform date utilities
│   ├── CircuitBreaker.psm1   # Circuit breaker pattern
│   └── ResponseAnalyzer.psm1 # Response analysis & session management
├── ralph_loop.ps1            # Main autonomous loop
├── ralph_monitor.ps1         # Live monitoring dashboard
├── ralph_import.ps1          # PRD/specification import
├── setup.ps1                 # Project initialization
├── Install-Ralph.ps1         # Global installation
├── Uninstall-Ralph.ps1       # Clean removal
└── Ralph.psd1                # Module manifest
```

## Differences from Bash Version

| Feature | Bash (Original) | PowerShell (WinRalph) |
|---------|-----------------|----------------------|
| JSON Parsing | `jq` | `ConvertFrom-Json` |
| Background Jobs | `&` / `wait` | `Start-Job` / `Receive-Job` |
| Monitoring | tmux | Windows Terminal tabs |
| Signal Handling | `trap` | `Register-EngineEvent` |
| Installation | `~/.local/bin` | `$env:LOCALAPPDATA\Ralph` |

## Troubleshooting

### Common Issues

- **"ralph not recognized"** - Restart your terminal after installation for PATH changes
- **Execution Policy** - Run `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`
- **Claude CLI not found** - Install with `npm install -g @anthropic-ai/claude-code`

### Logs and Debugging

```powershell
# View recent logs
Get-Content logs\ralph.log -Tail 20

# Check status file
Get-Content status.json | ConvertFrom-Json

# View circuit breaker state
Get-Content .circuit_breaker_state | ConvertFrom-Json
```

## Contributing

Contributions welcome! This is a community port of the original Ralph project.

```powershell
# Clone and test
git clone https://github.com/kvkvkv01/WinRalph.git
cd WinRalph

# Run tests
.\Test-PowerShell.ps1
```

## Credits

- **Original Ralph**: [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code)
- **Ralph Technique**: [Geoffrey Huntley](https://ghuntley.com/ralph/)
- **Claude Code**: [Anthropic](https://claude.ai/code)

## License

MIT License - see [LICENSE](LICENSE) for details.

---

**Ready to let AI build your project on Windows?** Start with `.\Install-Ralph.ps1` and let WinRalph take it from there!
