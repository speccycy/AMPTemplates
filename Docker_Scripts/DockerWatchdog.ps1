# ============================================================================
# DockerWatchdog.ps1 - External Container Monitor for Docker Wrapper
# ============================================================================
#
# Monitors the wrapper PID. When wrapper dies (AMP kills it during Stop/Abort),
# the watchdog handles Docker container cleanup to prevent orphaned containers.
#
# Shutdown decision is based on the flag file (container_ready.flag):
#   - Flag file EXISTS  → Graceful: docker stop -t 30, then docker rm
#   - Flag file MISSING → Force:    docker kill, then docker rm
#
# This mirrors the proven SCUM watchdog pattern adapted for Docker containers.
#
# Version: 1.0
# Requires: PowerShell 7.0+, Docker CLI
# ============================================================================

param(
    [Parameter(Mandatory=$true)]
    [int]$WrapperPID,

    [Parameter(Mandatory=$true)]
    [string]$ContainerName,

    [Parameter(Mandatory=$true)]
    [string]$ContainerID,

    [Parameter(Mandatory=$true)]
    [string]$ScriptRoot
)

# ============================================================================
# CONFIGURATION CONSTANTS
# ============================================================================

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

Set-Variable -Name CHECK_INTERVAL_MS -Value 200 -Option Constant
Set-Variable -Name GRACE_PERIOD_MS -Value 500 -Option Constant
Set-Variable -Name DOCKER_STOP_TIMEOUT -Value 30 -Option Constant
Set-Variable -Name HEARTBEAT_INTERVAL_SECONDS -Value 30 -Option Constant
Set-Variable -Name LOG_RETENTION_DAYS -Value 7 -Option Constant

# ============================================================================
# LOGGING INFRASTRUCTURE
# ============================================================================

$logDir = Join-Path $ScriptRoot "Logs"
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$logFile = Join-Path $logDir "DockerWatchdog_$(Get-Date -Format 'yyyy-MM-dd').log"

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
        $logEntry | Out-File -FilePath $logFile -Append -Encoding UTF8
    } catch {}
}

function Remove-OldLogs {
    param(
        [string]$LogDirectory = $logDir,
        [string]$Filter = "DockerWatchdog_*.log",
        [int]$RetentionDays = $LOG_RETENTION_DAYS
    )
    $cutoffDate = (Get-Date).AddDays(-$RetentionDays)
    try {
        Get-ChildItem -Path $LogDirectory -Filter $Filter -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoffDate } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
}

# Run log cleanup at startup
Remove-OldLogs

# ============================================================================
# FILE PATHS
# ============================================================================

$pidFile  = Join-Path $ScriptRoot "docker_container.pid"
$flagFile = Join-Path $ScriptRoot "container_ready.flag"

# ============================================================================
# STARTUP
# ============================================================================

Write-WatchdogLog "=================================================="
Write-WatchdogLog "Docker Watchdog Started"
Write-WatchdogLog "=================================================="
Write-WatchdogLog "Watchdog PID:    $PID"
Write-WatchdogLog "Wrapper PID:     $WrapperPID"
Write-WatchdogLog "Container Name:  $ContainerName"
Write-WatchdogLog "Container ID:    $ContainerID"
Write-WatchdogLog "Script Root:     $ScriptRoot"
Write-WatchdogLog "Check Interval:  ${CHECK_INTERVAL_MS}ms"
Write-WatchdogLog "=================================================="

# ============================================================================
# STARTUP VERIFICATION (Req 5.6)
# ============================================================================

Write-WatchdogLog "Verifying wrapper process exists..." "DEBUG"

$wrapperAliveAtStart = $false
try {
    $wrapperProc = Get-Process -Id $WrapperPID -ErrorAction Stop
    $wrapperAliveAtStart = $true
    Write-WatchdogLog "Wrapper process found: $($wrapperProc.ProcessName) (PID: $WrapperPID)" "DEBUG"
} catch {
    Write-WatchdogLog "Wrapper already dead at startup (PID: $WrapperPID) - proceeding to cleanup" "WARNING"
}

Write-WatchdogLog "Verifying container exists..." "DEBUG"

$containerExistsAtStart = $false
try {
    $inspectOutput = & docker inspect --format '{{.State.Status}}' $ContainerName 2>&1
    if ($LASTEXITCODE -eq 0) {
        $containerExistsAtStart = $true
        Write-WatchdogLog "Container found: $ContainerName (status: $($inspectOutput.Trim()))" "DEBUG"
    } else {
        Write-WatchdogLog "Container not found: $ContainerName" "WARNING"
    }
} catch {
    Write-WatchdogLog "Failed to inspect container: $_" "WARNING"
}

if (-not $containerExistsAtStart) {
    Write-WatchdogLog "Container does not exist - nothing to monitor. Cleaning up and exiting." "WARNING"
    # Clean up files
    if (Test-Path $pidFile)  { Remove-Item $pidFile  -Force -ErrorAction SilentlyContinue }
    if (Test-Path $flagFile) { Remove-Item $flagFile -Force -ErrorAction SilentlyContinue }
    Write-WatchdogLog "Watchdog exiting - no container to monitor"
    exit 0
}

# If wrapper is already dead at startup, skip monitoring and go straight to cleanup
if (-not $wrapperAliveAtStart) {
    Write-WatchdogLog "Wrapper already dead - skipping monitoring loop, proceeding to cleanup" "WARNING"
    # Fall through to cleanup section below
}

# ============================================================================
# MONITORING LOOP (Req 5.2, 5.3, 5.4)
# ============================================================================
# Check wrapper PID every 200ms, check container status, heartbeat every 30s.
# Exit conditions: wrapper dies OR container exits on its own.
# ============================================================================

$checkCount = 0
$lastHeartbeat = Get-Date
$wrapperDied = -not $wrapperAliveAtStart
$containerSelfExited = $false

if ($wrapperAliveAtStart) {
    Write-WatchdogLog "Starting monitoring loop..." "DEBUG"

    while ($true) {
        Start-Sleep -Milliseconds $CHECK_INTERVAL_MS
        $checkCount++

        # CHECK 1: Is wrapper still alive? (Req 5.2)
        try {
            Get-Process -Id $WrapperPID -ErrorAction Stop | Out-Null
        } catch {
            $wrapperDied = $true
            Write-WatchdogLog "=================================================="
            Write-WatchdogLog "WRAPPER DIED! (PID: $WrapperPID) after $checkCount checks" "WARNING"
            Write-WatchdogLog "=================================================="
            break
        }

        # CHECK 2: Is container still running? (Req 5.4)
        try {
            $statusOutput = & docker inspect --format '{{.State.Running}}' $ContainerName 2>&1
            if ($LASTEXITCODE -ne 0 -or $statusOutput.Trim() -ne "true") {
                $containerSelfExited = $true
                Write-WatchdogLog "Container exited on its own ($ContainerName) - watchdog no longer needed" "DEBUG"
                break
            }
        } catch {
            $containerSelfExited = $true
            Write-WatchdogLog "Cannot inspect container ($ContainerName) - assuming exited" "DEBUG"
            break
        }

        # Heartbeat logging every 30s (Req 5.5)
        $now = Get-Date
        if (($now - $lastHeartbeat).TotalSeconds -ge $HEARTBEAT_INTERVAL_SECONDS) {
            $lastHeartbeat = $now
            Write-WatchdogLog "Heartbeat: wrapper=$WrapperPID container=$ContainerName alive (checks: $checkCount)" "DEBUG"
        }
    }
}

# ============================================================================
# CONTAINER SELF-EXIT HANDLING (Req 5.4)
# ============================================================================

if ($containerSelfExited) {
    Write-WatchdogLog "Container exited on its own - wrapper should handle cleanup" "DEBUG"
    Write-WatchdogLog "Watchdog exiting - no cleanup needed"
    exit 0
}

# ============================================================================
# WRAPPER DIED - CONTAINER CLEANUP (Req 3.1-3.5, 4.1-4.3)
# ============================================================================
# Decision based on flag file:
#   Flag file EXISTS  → Graceful stop (AMP user clicked Stop)
#   Flag file MISSING → Force kill (AMP user clicked Abort, or container never reached RUNNING)
# ============================================================================

Write-WatchdogLog "=================================================="
Write-WatchdogLog "CLEANUP PHASE: Wrapper died, handling container..."
Write-WatchdogLog "=================================================="

# Grace period before cleanup
Write-WatchdogLog "Grace period: waiting ${GRACE_PERIOD_MS}ms..." "DEBUG"
Start-Sleep -Milliseconds $GRACE_PERIOD_MS

# Verify container is still running
$containerStillRunning = $false
try {
    $statusOutput = & docker inspect --format '{{.State.Running}}' $ContainerName 2>&1
    if ($LASTEXITCODE -eq 0 -and $statusOutput.Trim() -eq "true") {
        $containerStillRunning = $true
        Write-WatchdogLog "Container is still running: $ContainerName" "WARNING"
    } else {
        Write-WatchdogLog "Container already stopped: $ContainerName (status: $($statusOutput.Trim()))" "DEBUG"
    }
} catch {
    Write-WatchdogLog "Cannot inspect container - may already be removed" "DEBUG"
}

if ($containerStillRunning) {
    # Check flag file to determine shutdown method (Req 3.2, 4.1)
    Write-WatchdogLog "Checking flag file: $flagFile" "DEBUG"

    if (Test-Path $flagFile) {
        # ================================================================
        # GRACEFUL STOP: Flag file exists → docker stop (Req 3.2, 3.3, 3.5)
        # ================================================================
        Write-WatchdogLog "=================================================="
        Write-WatchdogLog "DECISION: Flag file EXISTS → Graceful shutdown" "WARNING"
        Write-WatchdogLog "  Running: docker stop -t $DOCKER_STOP_TIMEOUT $ContainerName" "WARNING"
        Write-WatchdogLog "=================================================="

        $stopOutput = & docker stop -t $DOCKER_STOP_TIMEOUT $ContainerName 2>&1
        $stopExitCode = $LASTEXITCODE

        if ($stopExitCode -eq 0) {
            Write-WatchdogLog "docker stop completed successfully" "DEBUG"
        } else {
            # docker stop failed or timed out → fallback to docker kill (Req 3.5)
            Write-WatchdogLog "docker stop failed (exit code: $stopExitCode) - falling back to docker kill" "WARNING"
            Write-WatchdogLog "Docker stop output: $($stopOutput -join ' ')" "DEBUG"

            $killOutput = & docker kill $ContainerName 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-WatchdogLog "docker kill succeeded (fallback)" "DEBUG"
            } else {
                Write-WatchdogLog "docker kill also failed: $($killOutput -join ' ')" "ERROR"
            }
        }
    } else {
        # ================================================================
        # FORCE KILL: No flag file → docker kill (Req 4.1, 4.2)
        # ================================================================
        Write-WatchdogLog "=================================================="
        Write-WatchdogLog "DECISION: Flag file MISSING → Force kill" "WARNING"
        Write-WatchdogLog "  Running: docker kill $ContainerName" "WARNING"
        Write-WatchdogLog "=================================================="

        $killOutput = & docker kill $ContainerName 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-WatchdogLog "docker kill completed successfully" "DEBUG"
        } else {
            Write-WatchdogLog "docker kill failed: $($killOutput -join ' ')" "ERROR"
        }
    }

    # Remove the container (Req 3.3, 4.2)
    Write-WatchdogLog "Removing container: $ContainerName" "DEBUG"
    $rmOutput = & docker rm -f $ContainerName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-WatchdogLog "Container removed successfully" "DEBUG"
    } else {
        Write-WatchdogLog "docker rm failed: $($rmOutput -join ' ')" "ERROR"
        Write-WatchdogLog "Container may need manual cleanup" "WARNING"
    }
} else {
    # Container already stopped - just remove it
    Write-WatchdogLog "Container already stopped - removing..." "DEBUG"
    & docker rm -f $ContainerName 2>&1 | Out-Null
    Write-WatchdogLog "Container removal attempted" "DEBUG"
}

# ============================================================================
# FINAL CLEANUP (Req 3.4, 4.3)
# ============================================================================

Write-WatchdogLog "=================================================="
Write-WatchdogLog "FINAL CLEANUP"
Write-WatchdogLog "=================================================="

# Remove PID file
if (Test-Path $pidFile) {
    try {
        Remove-Item $pidFile -Force -ErrorAction Stop
        Write-WatchdogLog "PID file removed: $pidFile" "DEBUG"
    } catch {
        Write-WatchdogLog "Failed to remove PID file: $_" "WARNING"
    }
} else {
    Write-WatchdogLog "PID file not found (already cleaned up)" "DEBUG"
}

# Remove flag file
if (Test-Path $flagFile) {
    try {
        Remove-Item $flagFile -Force -ErrorAction Stop
        Write-WatchdogLog "Flag file removed: $flagFile" "DEBUG"
    } catch {
        Write-WatchdogLog "Failed to remove flag file: $_" "WARNING"
    }
} else {
    Write-WatchdogLog "Flag file not found (already cleaned up or never created)" "DEBUG"
}

Write-WatchdogLog "=================================================="
Write-WatchdogLog "Watchdog completed - total checks: $checkCount"
Write-WatchdogLog "=================================================="

exit 0
