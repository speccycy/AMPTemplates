<#
.SYNOPSIS
    Creates stop signal file to trigger wrapper shutdown

.DESCRIPTION
    This script is called by AMP's PreStopStages to signal the wrapper
    that it should initiate shutdown. The wrapper actively monitors for
    this file and triggers graceful shutdown when detected.
    
    This is necessary because AMP does NOT send Ctrl+C signals to PowerShell
    wrappers and does NOT terminate the wrapper process when Stop/Abort is clicked.

.NOTES
    Called by: AMP PreStopStages
    Monitored by: SCUMWrapper.ps1 monitoring loop
    File location: Binaries/Win64/scum_stop.signal
#>

$signalFile = Join-Path $PSScriptRoot "scum_stop.signal"

try {
    # Create stop signal file
    "STOP" | Out-File $signalFile -Force
    Write-Host "[SIGNAL] Stop signal file created: $signalFile"
    exit 0
}
catch {
    Write-Host "[SIGNAL-ERROR] Failed to create stop signal file: $_"
    exit 1
}
