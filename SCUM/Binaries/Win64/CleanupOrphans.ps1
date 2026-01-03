<#
.SYNOPSIS
    Cleanup script to kill orphaned SCUM server processes

.DESCRIPTION
    This script is called by AMP after stopping the wrapper to ensure
    all SCUM server processes are terminated. This is a failsafe in case
    the wrapper's finally block doesn't execute.

.NOTES
    This script should be configured in scum.kvp as a post-stop action
#>

$logDir = Join-Path $PSScriptRoot "Logs"
$logFile = Join-Path $logDir "SCUMWrapper_$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-CleanupLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry = "[$timestamp] [CLEANUP] $Message"
    Write-Host $logEntry
    try {
        Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    catch {}
}

Write-CleanupLog "Cleanup script started"

# Find all SCUM server processes
$scumProcesses = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue

if ($scumProcesses) {
    Write-CleanupLog "Found $($scumProcesses.Count) SCUM server process(es)"
    
    foreach ($proc in $scumProcesses) {
        Write-CleanupLog "Killing SCUMServer PID: $($proc.Id)"
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            Write-CleanupLog "Successfully killed SCUMServer PID: $($proc.Id)"
        }
        catch {
            Write-CleanupLog "Failed to kill SCUMServer PID $($proc.Id): $_"
        }
    }
    
    # Wait for processes to terminate
    Start-Sleep -Seconds 2
    
    # Verify all are gone
    $remaining = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
    if ($remaining) {
        Write-CleanupLog "WARNING: $($remaining.Count) SCUMServer process(es) still running!"
    }
    else {
        Write-CleanupLog "All SCUM server processes terminated successfully"
    }
}
else {
    Write-CleanupLog "No SCUM server processes found"
}

# Find and kill wrapper PowerShell processes running SCUMWrapper.ps1
# This is necessary because AMP does NOT terminate the wrapper process
Write-CleanupLog "Scanning for orphaned wrapper processes..."
$allPowerShell = Get-Process -Name "powershell" -ErrorAction SilentlyContinue

if ($allPowerShell) {
    foreach ($ps in $allPowerShell) {
        try {
            # Check if this PowerShell process is running SCUMWrapper.ps1
            $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($ps.Id)" -ErrorAction SilentlyContinue).CommandLine
            
            if ($cmdLine -and $cmdLine -match "SCUMWrapper\.ps1") {
                Write-CleanupLog "Found orphaned wrapper process PID: $($ps.Id)"
                Write-CleanupLog "Killing wrapper PID: $($ps.Id)"
                Stop-Process -Id $ps.Id -Force -ErrorAction Stop
                Write-CleanupLog "Successfully killed wrapper PID: $($ps.Id)"
            }
        }
        catch {
            # Silently continue if we can't query or kill the process
        }
    }
}
else {
    Write-CleanupLog "No PowerShell processes found"
}

# Clean up PID file
$pidFile = Join-Path $PSScriptRoot "scum_server.pid"
if (Test-Path $pidFile) {
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    Write-CleanupLog "Removed PID file"
}

# Clean up stop signal file
$stopSignalFile = Join-Path $PSScriptRoot "scum_stop.signal"
if (Test-Path $stopSignalFile) {
    Remove-Item $stopSignalFile -Force -ErrorAction SilentlyContinue
    Write-CleanupLog "Removed stop signal file"
}

Write-CleanupLog "Cleanup script completed"
