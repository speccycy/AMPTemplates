<#
.SYNOPSIS
    SCUM Server Watchdog - External Process Monitor

.DESCRIPTION
    This watchdog runs as a separate process to monitor the wrapper and server.
    When the wrapper dies (killed by AMP during Abort), the watchdog immediately
    kills the SCUMServer.exe process to prevent orphans.
    
    This solves the fundamental problem: When AMP sends WM_EXIT to kill the wrapper,
    the wrapper dies before it can clean up. The watchdog survives and does the cleanup.

.PARAMETER WrapperPID
    The Process ID of the wrapper to monitor

.PARAMETER ServerPID
    The Process ID of the SCUMServer.exe to kill if wrapper dies

.PARAMETER PIDFile
    Path to the PID file for cleanup

.NOTES
    Version:        1.0
    Author:         CubeCoders AMP Template
    Purpose:        Prevent orphan processes during Abort
    
    CRITICAL: This script runs as a completely separate process from the wrapper.
    It will continue running even if the wrapper is force-killed by AMP.

.EXAMPLE
    pwsh.exe -File SCUMWatchdog.ps1 -WrapperPID 12345 -ServerPID 67890 -PIDFile "scum_server.pid"
#>

param(
    [Parameter(Mandatory=$true)]
    [int]$WrapperPID,
    
    [Parameter(Mandatory=$true)]
    [int]$ServerPID,
    
    [Parameter(Mandatory=$true)]
    [string]$PIDFile,
    
    [Parameter(Mandatory=$true)]
    [string]$SCUMLogPath
)

# ============================================================================
# CONFIGURATION
# ============================================================================

Set-Variable -Name CHECK_INTERVAL_MS -Value 200 -Option Constant
    # How often to check if wrapper is alive (milliseconds)
    # 200ms = very responsive, low CPU usage

Set-Variable -Name GRACE_PERIOD_MS -Value 500 -Option Constant
    # Wait this long after wrapper dies before checking server
    # Reduced to 500ms for faster response (trap doesn't work anyway)

Set-Variable -Name GRACEFUL_SHUTDOWN_TIMEOUT -Value 30 -Option Constant
    # Maximum wait time for LogExit pattern during graceful shutdown
    # Full 30 seconds for proper graceful shutdown

# ============================================================================
# LOGGING
# ============================================================================

$logDir = Join-Path $PSScriptRoot "Logs"
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$logFile = Join-Path $logDir "SCUMWatchdog_$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-WatchdogLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry = "[$timestamp] [WATCHDOG-$Level] $Message"
    
    # Write to console
    Write-Host $logEntry
    
    # Write to log file
    try {
        Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    catch {
        # Silently fail if can't write to log
    }
}

# ============================================================================
# MAIN WATCHDOG LOGIC
# ============================================================================

Write-WatchdogLog "=================================================="
Write-WatchdogLog "SCUM Server Watchdog Started"
Write-WatchdogLog "=================================================="
Write-WatchdogLog "Watchdog PID: $PID"
Write-WatchdogLog "Parent Wrapper PID: $WrapperPID"
Write-WatchdogLog "Target Server PID: $ServerPID"
Write-WatchdogLog "PID File Path: $PIDFile"
Write-WatchdogLog "SCUM Log Path: $SCUMLogPath"
Write-WatchdogLog "Check Interval: ${CHECK_INTERVAL_MS}ms"
Write-WatchdogLog "Grace Period: ${GRACE_PERIOD_MS}ms"
Write-WatchdogLog "=================================================="

# Verify wrapper exists at startup
Write-WatchdogLog "Step 1: Verifying wrapper process exists..." "DEBUG"
try {
    $wrapper = Get-Process -Id $WrapperPID -ErrorAction Stop
    Write-WatchdogLog "✓ Wrapper process found: $($wrapper.ProcessName) (PID: $WrapperPID)" "DEBUG"
    Write-WatchdogLog "  - Start Time: $($wrapper.StartTime)" "DEBUG"
    Write-WatchdogLog "  - Working Set: $([math]::Round($wrapper.WorkingSet64 / 1MB, 2)) MB" "DEBUG"
}
catch {
    Write-WatchdogLog "✗ ERROR: Wrapper PID $WrapperPID not found at startup!" "ERROR"
    Write-WatchdogLog "  Watchdog cannot function without wrapper - exiting" "ERROR"
    exit 1
}

# Verify server exists at startup
Write-WatchdogLog "Step 2: Verifying server process exists..." "DEBUG"
try {
    $server = Get-Process -Id $ServerPID -ErrorAction Stop
    Write-WatchdogLog "✓ Server process found: $($server.ProcessName) (PID: $ServerPID)" "DEBUG"
    Write-WatchdogLog "  - Start Time: $($server.StartTime)" "DEBUG"
    Write-WatchdogLog "  - Working Set: $([math]::Round($server.WorkingSet64 / 1MB, 2)) MB" "DEBUG"
    Write-WatchdogLog "  - Command Line: $($server.Path)" "DEBUG"
}
catch {
    Write-WatchdogLog "✗ ERROR: Server PID $ServerPID not found at startup!" "ERROR"
    Write-WatchdogLog "  Watchdog cannot function without server - exiting" "ERROR"
    exit 1
}

Write-WatchdogLog "=================================================="
Write-WatchdogLog "Step 3: Starting monitoring loop..."
Write-WatchdogLog "  Watchdog will check every ${CHECK_INTERVAL_MS}ms if wrapper is alive"
Write-WatchdogLog "  If wrapper dies, watchdog will kill server after ${GRACE_PERIOD_MS}ms grace period"
Write-WatchdogLog "=================================================="

# ============================================================================
# MONITORING LOOP
# ============================================================================

$loopCount = 0
$lastHeartbeat = Get-Date
$lastDetailedCheck = Get-Date

while ($true) {
    Start-Sleep -Milliseconds $CHECK_INTERVAL_MS
    $loopCount++
    
    # Heartbeat every 5 seconds
    $now = Get-Date
    if (($now - $lastHeartbeat).TotalSeconds -ge 5) {
        $lastHeartbeat = $now
        Write-WatchdogLog "Heartbeat: Monitoring active (checks: $loopCount, uptime: $([math]::Round(($now - $wrapper.StartTime).TotalSeconds, 1))s)" "DEBUG"
    }
    
    # Detailed check every 30 seconds
    if (($now - $lastDetailedCheck).TotalSeconds -ge 30) {
        $lastDetailedCheck = $now
        try {
            $wrapper.Refresh()
            $server.Refresh()
            Write-WatchdogLog "Detailed Status Check:" "DEBUG"
            Write-WatchdogLog "  - Wrapper: Alive, CPU: $([math]::Round($wrapper.TotalProcessorTime.TotalSeconds, 2))s, Memory: $([math]::Round($wrapper.WorkingSet64 / 1MB, 2)) MB" "DEBUG"
            Write-WatchdogLog "  - Server: Alive, CPU: $([math]::Round($server.TotalProcessorTime.TotalSeconds, 2))s, Memory: $([math]::Round($server.WorkingSet64 / 1MB, 2)) MB" "DEBUG"
        }
        catch {
            # Process might have exited, will be caught in main checks below
        }
    }
    
    # ========================================================================
    # CHECK 1: Is wrapper still alive?
    # ========================================================================
    
    $wrapperAlive = $false
    try {
        $wrapper = Get-Process -Id $WrapperPID -ErrorAction Stop
        $wrapperAlive = $true
    }
    catch {
        # Wrapper is dead!
        $wrapperUptime = ($now - $wrapper.StartTime).TotalSeconds
        Write-WatchdogLog "=================================================="
        Write-WatchdogLog "WRAPPER DIED! (PID: $WrapperPID)" "WARNING"
        Write-WatchdogLog "=================================================="
        Write-WatchdogLog "Detection Details:" "WARNING"
        Write-WatchdogLog "  - Wrapper uptime before death: $([math]::Round($wrapperUptime, 2))s" "WARNING"
        Write-WatchdogLog "  - Detection time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')" "WARNING"
        Write-WatchdogLog "  - Total monitoring checks performed: $loopCount" "WARNING"
        Write-WatchdogLog "  - Likely cause: AMP sent WM_EXIT (Abort/Stop button)" "WARNING"
        Write-WatchdogLog "=================================================="
        break
    }
    
    # ========================================================================
    # CHECK 2: Is server still alive?
    # ========================================================================
    
    $serverAlive = $false
    try {
        $server = Get-Process -Id $ServerPID -ErrorAction Stop
        $serverAlive = $true
    }
    catch {
        # Server died on its own (normal exit)
        Write-WatchdogLog "=================================================="
        Write-WatchdogLog "Server process exited normally (PID: $ServerPID)" "DEBUG"
        Write-WatchdogLog "  - Server was running for: $([math]::Round(($now - $server.StartTime).TotalSeconds, 2))s" "DEBUG"
        Write-WatchdogLog "  - Watchdog no longer needed - exiting" "DEBUG"
        Write-WatchdogLog "=================================================="
        break
    }
}

# ============================================================================
# CLEANUP: Wrapper died, server still running
# ============================================================================

Write-WatchdogLog "=================================================="
Write-WatchdogLog "CLEANUP PHASE: Checking server status..."
Write-WatchdogLog "=================================================="

# Brief grace period (trap doesn't work, but just in case)
Write-WatchdogLog "Step 1: Grace period - waiting ${GRACE_PERIOD_MS}ms..." "DEBUG"
Start-Sleep -Milliseconds $GRACE_PERIOD_MS

# Check if server is still alive after grace period
Write-WatchdogLog "Step 2: Checking if server is still alive..." "DEBUG"
$serverStillAlive = $false
try {
    $server = Get-Process -Id $ServerPID -ErrorAction Stop
    $serverStillAlive = $true
    $serverUptime = (Get-Date) - $server.StartTime
    Write-WatchdogLog "  - Server is STILL ALIVE (PID: $ServerPID)" "WARNING"
    Write-WatchdogLog "  - Server uptime: $([math]::Round($serverUptime.TotalSeconds, 2))s" "WARNING"
    Write-WatchdogLog "  - Memory usage: $([math]::Round($server.WorkingSet64 / 1MB, 2)) MB" "WARNING"
}
catch {
    Write-WatchdogLog "  - Server already terminated" "DEBUG"
    Write-WatchdogLog "  - No cleanup needed" "DEBUG"
}

if ($serverStillAlive) {
    # Server is orphaned - check if it was ready
    Write-WatchdogLog "=================================================="
    Write-WatchdogLog "ORPHAN DETECTED!" "WARNING"
    Write-WatchdogLog "=================================================="
    Write-WatchdogLog "Server PID $ServerPID is orphaned (wrapper died but server still running)" "WARNING"
    
    # ========================================================================
    # CRITICAL: Check if server was ready (Started) or still starting
    # ========================================================================
    
    Write-WatchdogLog "Step 3: Checking server ready state..." "DEBUG"
    
    # Check for server ready flag file (created by wrapper)
    $serverReadyFlagFile = Join-Path $PSScriptRoot "server_ready.flag"
    
    Write-WatchdogLog "  - Flag file path: $serverReadyFlagFile" "DEBUG"
    
    $serverWasReady = $false
    if (Test-Path $serverReadyFlagFile) {
        $serverWasReady = $true
        Write-WatchdogLog "  ✓ Server was READY (flag file exists)" "DEBUG"
        Write-WatchdogLog "  This means server was in 'Started' state" "DEBUG"
    }
    else {
        Write-WatchdogLog "  ✗ Server was NOT READY (no flag file)" "DEBUG"
        Write-WatchdogLog "  This means server was still in 'Starting' state" "DEBUG"
    }
    
    # ========================================================================
    # DECISION: Graceful shutdown or force kill
    # ========================================================================
    
    if ($serverWasReady) {
        # Server was ready - attempt graceful shutdown
        Write-WatchdogLog "=================================================="
        Write-WatchdogLog "DECISION: Server was READY (Started state)" "WARNING"
        Write-WatchdogLog "  Attempting GRACEFUL SHUTDOWN..." "WARNING"
        Write-WatchdogLog "  Will send Ctrl+C and wait for LogExit" "WARNING"
        Write-WatchdogLog "=================================================="
        
        Write-WatchdogLog "Step 4: Sending Ctrl+C signal to server..." "DEBUG"
        
        # Load Windows API for Ctrl+C (same as wrapper)
        $ctrlcSignature = @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AttachConsole(uint dwProcessId);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FreeConsole();

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleCtrlHandler(IntPtr HandlerRoutine, bool Add);
'@
        
        try {
            Add-Type -MemberDefinition $ctrlcSignature -Name 'WatchdogWinAPI' -Namespace 'Kernel32' -ErrorAction Stop | Out-Null
            $apiLoaded = $true
            Write-WatchdogLog "  ✓ Windows API loaded" "DEBUG"
        }
        catch {
            $apiLoaded = $false
            Write-WatchdogLog "  ✗ Failed to load Windows API: $_" "WARNING"
        }
        
        $ctrlcSent = $false
        if ($apiLoaded) {
            try {
                [Kernel32.WatchdogWinAPI]::FreeConsole() | Out-Null
                if ([Kernel32.WatchdogWinAPI]::AttachConsole($ServerPID)) {
                    [Kernel32.WatchdogWinAPI]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
                    $result = [Kernel32.WatchdogWinAPI]::GenerateConsoleCtrlEvent(0, 0)
                    Start-Sleep -Milliseconds 100
                    [Kernel32.WatchdogWinAPI]::FreeConsole() | Out-Null
                    [Kernel32.WatchdogWinAPI]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) | Out-Null
                    
                    if ($result) {
                        $ctrlcSent = $true
                        Write-WatchdogLog "  ✓ Ctrl+C sent successfully" "DEBUG"
                    }
                }
            }
            catch {
                Write-WatchdogLog "  ✗ Ctrl+C failed: $_" "WARNING"
            }
        }
        
        if ($ctrlcSent) {
            # Wait for LogExit pattern
            Write-WatchdogLog "Step 5: Waiting for LogExit pattern (max ${GRACEFUL_SHUTDOWN_TIMEOUT}s)..." "DEBUG"
            
            $logExitFound = $false
            $waited = 0
            
            while ($waited -lt $GRACEFUL_SHUTDOWN_TIMEOUT) {
                Start-Sleep -Seconds 2
                $waited += 2
                
                # Check if server exited
                try {
                    $server = Get-Process -Id $ServerPID -ErrorAction Stop
                }
                catch {
                    Write-WatchdogLog "  ✓ Server exited after ${waited}s" "DEBUG"
                    break
                }
                
                # Check for LogExit pattern
                if (Test-Path $scumLogPath) {
                    try {
                        $lastLines = Get-Content $scumLogPath -Tail 50 -ErrorAction SilentlyContinue
                        if ($lastLines -match "LogExit: Exiting") {
                            $logExitFound = $true
                            Write-WatchdogLog "  ✓ LogExit pattern detected after ${waited}s!" "DEBUG"
                            break
                        }
                    }
                    catch {}
                }
                
                # Log progress every 10 seconds
                if ($waited % 10 -eq 0) {
                    Write-WatchdogLog "  Still waiting for LogExit... (${waited}/${GRACEFUL_SHUTDOWN_TIMEOUT}s)" "DEBUG"
                }
            }
            
            # Check final result
            try {
                $server = Get-Process -Id $ServerPID -ErrorAction Stop
                # Server still running - force kill
                Write-WatchdogLog "  ✗ Server did not exit after ${GRACEFUL_SHUTDOWN_TIMEOUT}s" "ERROR"
                Write-WatchdogLog "  Force killing server..." "ERROR"
                Stop-Process -Id $ServerPID -Force
                Write-WatchdogLog "  ✓ Server force killed (timeout)" "WARNING"
            }
            catch {
                # Server exited
                if ($logExitFound) {
                    Write-WatchdogLog "  ✓ GRACEFUL SHUTDOWN SUCCESS (LogExit detected)" "DEBUG"
                }
                else {
                    Write-WatchdogLog "  ⚠ Server exited without LogExit" "WARNING"
                }
            }
        }
        else {
            # Ctrl+C failed - force kill
            Write-WrapperLog "  ✗ Ctrl+C failed - force killing..." "ERROR"
            Stop-Process -Id $ServerPID -Force
            Write-WatchdogLog "  ✓ Server force killed (Ctrl+C failed)" "WARNING"
        }
    }
    else {
        # Server was NOT ready - force kill immediately
        Write-WatchdogLog "=================================================="
        Write-WatchdogLog "DECISION: Server was STARTING (not ready yet)" "DEBUG"
        Write-WatchdogLog "  Force kill is appropriate for startup phase" "DEBUG"
        Write-WatchdogLog "  No data corruption risk" "DEBUG"
        Write-WatchdogLog "=================================================="
        
        Write-WatchdogLog "Step 4: Killing server (startup phase)..." "DEBUG"
        try {
            Stop-Process -Id $ServerPID -Force -ErrorAction Stop
            Write-WatchdogLog "  ✓ Server killed successfully" "DEBUG"
            
            Start-Sleep -Seconds 2
            
            try {
                $stillAlive = Get-Process -Id $ServerPID -ErrorAction Stop
                Write-WatchdogLog "  ✗ WARNING: Server still alive after kill!" "ERROR"
            }
            catch {
                Write-WatchdogLog "  ✓ Server terminated successfully" "DEBUG"
            }
        }
        catch {
            Write-WatchdogLog "  ✗ Failed to kill server: $_" "ERROR"
        }
    }
}
else {
    Write-WatchdogLog "=================================================="
    Write-WatchdogLog "No orphan detected - server already terminated" "DEBUG"
    Write-WatchdogLog "=================================================="
}

# ============================================================================
# FINAL CLEANUP
# ============================================================================

Write-WatchdogLog "=================================================="
Write-WatchdogLog "FINAL CLEANUP PHASE"
Write-WatchdogLog "=================================================="

Write-WatchdogLog "Step 6: Cleaning up files..." "DEBUG"

# Remove PID file
$pidFilePath = Join-Path $PSScriptRoot $PIDFile
Write-WatchdogLog "  - PID file path: $pidFilePath" "DEBUG"

if (Test-Path $pidFilePath) {
    try {
        Remove-Item $pidFilePath -Force -ErrorAction Stop
        Write-WatchdogLog "  ✓ PID file removed successfully" "DEBUG"
    }
    catch {
        Write-WatchdogLog "  ✗ Failed to remove PID file: $_" "WARNING"
        Write-WatchdogLog "  This may cause issues on next startup" "WARNING"
    }
}
else {
    Write-WatchdogLog "  - PID file not found (already cleaned up by wrapper)" "DEBUG"
}

# Remove server ready flag file
$serverReadyFlagFile = Join-Path $PSScriptRoot "server_ready.flag"
if (Test-Path $serverReadyFlagFile) {
    try {
        Remove-Item $serverReadyFlagFile -Force -ErrorAction Stop
        Write-WatchdogLog "  ✓ Server ready flag file removed" "DEBUG"
    }
    catch {
        Write-WatchdogLog "  ✗ Failed to remove flag file: $_" "WARNING"
    }
}

Write-WatchdogLog "=================================================="
Write-WatchdogLog "WATCHDOG SHUTDOWN SUMMARY"
Write-WatchdogLog "=================================================="
Write-WatchdogLog "Total monitoring checks performed: $loopCount"
Write-WatchdogLog "Total monitoring duration: $([math]::Round(((Get-Date) - $lastHeartbeat).TotalSeconds + 5, 2))s"
Write-WatchdogLog "Watchdog completed successfully"
Write-WatchdogLog "=================================================="

exit 0
