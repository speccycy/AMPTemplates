param(
    [Parameter(ValueFromRemainingArguments = $true)]
    $ScriptArgs
)

# SCUM Server Graceful Shutdown Wrapper v3.0
# - Separate log file for troubleshooting
# - Orphan process cleanup
# - Smart PID file with timestamp
# - Event-based cleanup handlers
# - Uptime-based shutdown decision (handles AMP CtrlC signal)

# ============================================================================
# LOGGING SYSTEM
# ============================================================================

# Create logs directory
$logDir = Join-Path $PSScriptRoot "Logs"
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Log file with date
$logFile = Join-Path $logDir "SCUMWrapper_$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-WrapperLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"  # INFO, WARNING, ERROR
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console (for AMP) - with level prefix for visibility
    $consolePrefix = switch ($Level) {
        "ERROR"   { "[WRAPPER-ERROR]" }
        "WARNING" { "[WRAPPER-WARN]" }
        "DEBUG"   { "[WRAPPER-DEBUG]" }
        default   { "[WRAPPER-INFO]" }
    }
    Write-Host "$consolePrefix $Message"
    
    # Write to log file
    try {
        Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    catch {
        # Silently fail if can't write to log
    }
}

# Cleanup old logs (keep last 7 days)
function Remove-OldLogs {
    $cutoffDate = (Get-Date).AddDays(-7)
    Get-ChildItem -Path $logDir -Filter "SCUMWrapper_*.log" -ErrorAction SilentlyContinue | 
    Where-Object { $_.LastWriteTime -lt $cutoffDate } | 
    Remove-Item -Force -ErrorAction SilentlyContinue
}

Remove-OldLogs

Write-WrapperLog "=================================================="
Write-WrapperLog "SCUM Server Graceful Shutdown Wrapper v3.0"
Write-WrapperLog "Wrapper PID: $PID"
Write-WrapperLog "=================================================="

# ============================================================================
# ORPHAN PROCESS CLEANUP
# ============================================================================

function Stop-OrphanedSCUMProcesses {
    Write-WrapperLog "Pre-start check: Scanning for existing SCUM processes..." "DEBUG"
    $orphans = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
    
    if ($orphans) {
        Write-WrapperLog "Pre-start check: Found $($orphans.Count) existing SCUM process(es)" "WARNING"
        foreach ($orphan in $orphans) {
            Write-WrapperLog "Pre-start check: Terminating existing PID: $($orphan.Id)" "WARNING"
            try {
                Stop-Process -Id $orphan.Id -Force -ErrorAction Stop
                Write-WrapperLog "Pre-start check: Successfully terminated PID: $($orphan.Id)" "DEBUG"
            }
            catch {
                Write-WrapperLog "Pre-start check: Failed to terminate PID $($orphan.Id): $_" "ERROR"
            }
        }
        
        # CRITICAL: Wait for processes to fully release
        Write-WrapperLog "Pre-start check: Waiting for process cleanup (5s)..." "DEBUG"
        Start-Sleep -Seconds 5
        
        # Verify cleanup
        $remaining = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
        if ($remaining) {
            Write-WrapperLog "Pre-start check: WARNING - $($remaining.Count) process(es) still running!" "ERROR"
        }
        else {
            Write-WrapperLog "Pre-start check: All processes terminated successfully" "DEBUG"
        }
    }
    else {
        Write-WrapperLog "Pre-start check: No existing processes found - clear to start" "DEBUG"
    }
}

# Run orphan cleanup before starting
Stop-OrphanedSCUMProcesses

# ============================================================================
# PID FILE WITH TIMESTAMP (SMART LOCK)
# ============================================================================

$pidFile = Join-Path $PSScriptRoot "scum_server.pid"

# Check existing PID file
if (Test-Path $pidFile) {
    try {
        $pidData = Get-Content $pidFile | ConvertFrom-Json
        $pidAge = (Get-Date) - [DateTime]$pidData.Timestamp
        
        # If PID file is recent (< 5 min) and process exists, another instance is running
        if ($pidAge.TotalMinutes -lt 5) {
            if (Get-Process -Id $pidData.PID -ErrorAction SilentlyContinue) {
                Write-WrapperLog "ERROR: Another instance is running (PID: $($pidData.PID))" "ERROR"
                Write-WrapperLog "If this is incorrect, delete: $pidFile" "ERROR"
                exit 1
            }
        }
        
        # Old or invalid PID file - remove it
        Write-WrapperLog "Removing stale PID file (age: $([math]::Round($pidAge.TotalMinutes, 1)) min)" "WARNING"
        Remove-Item $pidFile -Force
    }
    catch {
        # Corrupted PID file - remove it
        Write-WrapperLog "Removing corrupted PID file" "WARNING"
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
}

# Create new PID file
$pidData = @{
    PID       = $PID
    ServerPID = $null
    Timestamp = (Get-Date).ToString("o")
} | ConvertTo-Json

$pidData | Out-File $pidFile -Force
Write-WrapperLog "Created PID file: $pidFile"

# ============================================================================
# CLEANUP EVENT HANDLER
# ============================================================================

# Register cleanup handler for PowerShell exit
$cleanupScript = {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $logDir = Join-Path $scriptRoot "Logs"
    $logFile = Join-Path $logDir "SCUMWrapper_$(Get-Date -Format 'yyyy-MM-dd').log"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    
    $pidFile = Join-Path $scriptRoot "scum_server.pid"
    if (Test-Path $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        Add-Content -Path $logFile -Value "[$timestamp] [INFO] Event handler cleaned up PID file" -ErrorAction SilentlyContinue
    }
}

$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $cleanupScript
Write-WrapperLog "Registered cleanup event handler"

# ============================================================================
# WINDOWS API FOR CTRL+C
# ============================================================================

$signature = @'
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
    Add-Type -MemberDefinition $signature -Name 'WinAPI' -Namespace 'Kernel32' -ErrorAction Stop | Out-Null
    $apiLoaded = $true
    Write-WrapperLog "Windows API loaded successfully"
}
catch {
    $apiLoaded = $false
    Write-WrapperLog "Failed to load Windows API: $_" "WARNING"
}

function Send-CtrlC {
    param([System.Diagnostics.Process]$TargetProcess)
    
    if (!$TargetProcess -or $TargetProcess.HasExited) {
        return $false
    }
    
    Write-WrapperLog "Sending Ctrl+C to PID $($TargetProcess.Id)..."
    
    if ($apiLoaded) {
        try {
            # Method 1: Use Windows API
            [Kernel32.WinAPI]::FreeConsole() | Out-Null
            
            if ([Kernel32.WinAPI]::AttachConsole($TargetProcess.Id)) {
                [Kernel32.WinAPI]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
                $result = [Kernel32.WinAPI]::GenerateConsoleCtrlEvent(0, 0)
                Start-Sleep -Milliseconds 100
                [Kernel32.WinAPI]::FreeConsole() | Out-Null
                [Kernel32.WinAPI]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) | Out-Null
                
                if ($result) {
                    Write-WrapperLog "Ctrl+C sent via API"
                    return $true
                }
            }
        }
        catch {
            Write-WrapperLog "API method failed: $_" "WARNING"
        }
    }
    
    # Method 2: CloseMainWindow fallback
    Write-WrapperLog "Trying CloseMainWindow..."
    try {
        return $TargetProcess.CloseMainWindow()
    }
    catch {
        return $false
    }
}

# ============================================================================
# START SCUM SERVER
# ============================================================================

$ExePath = Join-Path $PSScriptRoot "SCUMServer.exe"
$process = $null

if (!(Test-Path $ExePath)) {
    Write-WrapperLog "ERROR: Server executable not found: $ExePath" "ERROR"
    exit 1
}

$argString = $ScriptArgs -join " "
Write-WrapperLog "Executable: $ExePath"
Write-WrapperLog "Arguments: $argString"
Write-WrapperLog "--------------------------------------------------"

try {
    Write-WrapperLog "Starting SCUM Server..."
    
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    
    $process = [System.Diagnostics.Process]::Start($psi)
    
    if ($null -eq $process) {
        Write-WrapperLog "ERROR: Failed to start process" "ERROR"
        exit 1
    }

    Write-WrapperLog "Server started successfully" "DEBUG"
    Write-WrapperLog "SCUM Server PID: $($process.Id)" "DEBUG"
    Write-WrapperLog "Wrapper PID: $PID" "DEBUG"
    
    # Update PID file with server PID
    try {
        $pidData = Get-Content $pidFile | ConvertFrom-Json
        $pidData.ServerPID = $process.Id
        $pidData | ConvertTo-Json | Out-File $pidFile -Force
        Write-WrapperLog "PID file updated with server PID: $($process.Id)" "DEBUG"
    }
    catch {
        Write-WrapperLog "Failed to update PID file: $_" "WARNING"
    }
    
    Write-WrapperLog "State: RUNNING - Monitoring process..." "DEBUG"
    Write-WrapperLog "--------------------------------------------------"
    
    # Wait for process to exit
    while (!$process.HasExited) {
        Start-Sleep -Milliseconds 500
    }
    
    Write-WrapperLog "Process exited. Code: $($process.ExitCode)"
    exit $process.ExitCode

}
catch {
    Write-WrapperLog "ERROR: $_" "ERROR"
    exit 1
}
finally {
    # Unregister event handler
    Unregister-Event -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue
    
    # This block runs when wrapper receives Ctrl+C from AMP
    if ($null -ne $process -and !$process.HasExited) {
        Write-WrapperLog "State: SHUTDOWN_REQUESTED - Checking server uptime..." "DEBUG"
        
        try {
            $process.Refresh()
            $uptime = (Get-Date) - $process.StartTime
            $uptimeSeconds = $uptime.TotalSeconds
            
            Write-WrapperLog "Server uptime: $([math]::Round($uptime.TotalMinutes, 2)) min ($([math]::Round($uptimeSeconds, 1))s)" "DEBUG"
            
            # CRITICAL: Only abort if server is in early startup phase (< 30 seconds)
            # After 30s, server is considered "running" and needs graceful shutdown
            if ($uptimeSeconds -lt 30) {
                # Server is still starting up - immediate kill (abort)
                Write-WrapperLog "Server in startup phase (< 30s) - ABORT MODE" "WARNING"
                Write-WrapperLog "State: FORCE_KILL - Terminating PID $($process.Id)..." "DEBUG"
                $process.Kill()
                Write-WrapperLog "Process killed (startup abort)" "DEBUG"
            }
            else {
                # Server is running - ALWAYS use graceful shutdown
                Write-WrapperLog "Server is running - GRACEFUL SHUTDOWN MODE" "DEBUG"
                Write-WrapperLog "State: SENDING_SHUTDOWN_SIGNAL" "DEBUG"
                
                if (Send-CtrlC $process) {
                    Write-WrapperLog "Ctrl+C signal sent to PID $($process.Id)" "DEBUG"
                    Write-WrapperLog "State: WAITING_FOR_LOGEXIT - Monitoring log file..." "DEBUG"
                    
                    # Monitor log file for LogExit pattern
                    $logPath = Join-Path $PSScriptRoot "..\..\..\..\Saved\Logs\SCUM.log"
                    $logExitFound = $false
                    $waited = 0
                    $maxWait = 30  # 30 second failsafe as per AGENTS.MD
                    
                    while (!$process.HasExited -and $waited -lt $maxWait) {
                        Start-Sleep -Seconds 2
                        $waited += 2
                        
                        # Check for LogExit pattern in log file
                        if (Test-Path $logPath) {
                            try {
                                $lastLines = Get-Content $logPath -Tail 50 -ErrorAction SilentlyContinue
                                if ($lastLines -match "LogExit: Exiting") {
                                    $logExitFound = $true
                                    Write-WrapperLog "LogExit pattern detected! Server saved successfully." "DEBUG"
                                    break
                                }
                            }
                            catch {
                                # Log file might be locked, continue waiting
                            }
                        }
                        
                        if ($waited % 10 -eq 0) {
                            Write-WrapperLog "Still waiting for LogExit... ($waited/${maxWait}s)" "DEBUG"
                        }
                    }
                    
                    if ($process.HasExited) {
                        if ($logExitFound) {
                            Write-WrapperLog "State: SHUTDOWN_COMPLETE - Graceful shutdown confirmed (${waited}s)" "DEBUG"
                        }
                        else {
                            Write-WrapperLog "State: SHUTDOWN_COMPLETE - Process exited but LogExit not detected (${waited}s)" "WARNING"
                        }
                    }
                    else {
                        # 30 second timeout reached - FAILSAFE ACTIVATION
                        Write-WrapperLog "State: FAILSAFE_TIMEOUT - No LogExit after ${maxWait}s!" "ERROR"
                        Write-WrapperLog "Assuming server frozen/crashed - Force killing PID $($process.Id)..." "ERROR"
                        $process.Kill()
                        Write-WrapperLog "Process killed (failsafe timeout)" "WARNING"
                    }
                }
                else {
                    Write-WrapperLog "State: SIGNAL_FAILED - Ctrl+C failed, force killing..." "ERROR"
                    $process.Kill()
                    Write-WrapperLog "Process killed (signal failed)" "WARNING"
                }
            }
        }
        catch {
            Write-WrapperLog "Error during shutdown: $_" "ERROR"
            try { $process.Kill() } catch {}
        }
        
        try { $process.Dispose() } catch {}
    }
    
    # Cleanup PID file
    if (Test-Path $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        Write-WrapperLog "Cleaned up PID file"
    }
    
    Write-WrapperLog "Wrapper exiting"
    Write-WrapperLog "=================================================="
}
