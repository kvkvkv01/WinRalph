#Requires -Version 5.1
<#
.SYNOPSIS
    Cross-platform date utility functions for Ralph.

.DESCRIPTION
    Provides consistent date formatting and arithmetic for PowerShell.
    Equivalent to lib/date_utils.sh in the bash implementation.
#>

# Get current timestamp in ISO 8601 format with seconds precision
# Returns: yyyy-MM-ddTHH:mm:ssK format (e.g., 2026-01-20T10:30:00+00:00)
function Get-IsoTimestamp {
    [CmdletBinding()]
    param()

    return (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
}

# Get time component (HH:mm:ss) for one hour from now
# Returns: HH:mm:ss format
function Get-NextHourTime {
    [CmdletBinding()]
    param()

    return (Get-Date).AddHours(1).ToString("HH:mm:ss")
}

# Get current timestamp in a basic format (fallback)
# Returns: yyyy-MM-dd HH:mm:ss format
function Get-BasicTimestamp {
    [CmdletBinding()]
    param()

    return (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

# Get current Unix epoch time in seconds
# Returns: Integer seconds since 1970-01-01 00:00:00 UTC
function Get-EpochSeconds {
    [CmdletBinding()]
    param()

    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# Parse ISO timestamp to epoch seconds
# Returns: Integer seconds since 1970-01-01 00:00:00 UTC, or -1 on failure
function ConvertFrom-IsoTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Timestamp
    )

    try {
        # Handle various ISO formats
        $dateTime = [DateTimeOffset]::Parse($Timestamp)
        return $dateTime.ToUnixTimeSeconds()
    }
    catch {
        Write-Verbose "Failed to parse timestamp: $Timestamp"
        return -1
    }
}

# Export module members
Export-ModuleMember -Function @(
    'Get-IsoTimestamp',
    'Get-NextHourTime',
    'Get-BasicTimestamp',
    'Get-EpochSeconds',
    'ConvertFrom-IsoTimestamp'
)
