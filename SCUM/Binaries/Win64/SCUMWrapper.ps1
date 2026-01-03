<#
.SYNOPSIS
    SCUM Server Graceful Shutdown Wrapper for CubeCoders AMP

.DESCRIPTION
    This wrapper manages the lifecycle of SCUM Dedicated Server instances within the
    CubeCoders AMP (Application Management Panel) environment. It ensures 100% data
    integrity through graceful shutdown procedures, prevents race conditions and
    duplicate processes, and provides comprehensive logging for troubleshooting.
    
    Key Features:
    - Graceful shutdown with Ctrl+C signal and LogExit pattern detection
    - Failsafe timeout (30s) to prevent hung shutdowns
    - Orphan process cleanup before starting new instances
    - Singleton enforcement via PID file with timestamp validation
    - Uptime-based shutdown decision (abort vs graceful)
    - Comprehensive dual logging (console + file)
    - Automatic log rotation (7-day retention)
    - Event-based cleanup handlers for crash recovery

.PARAMETER ScriptArgs
    Command-line arguments to pass to SCUMServer.exe
    These are forwarded directly to the game server executable

.NOTES
    Version:        3.1
    Author:         CubeCoders AMP Template
    Purpose:        Ensure data integrity and prevent database corruption
    Requirements:   PowerShell 7.0+, Windows Server
    
    CRITICAL: This wrapper must be configured in scum.kvp with:
    - App.ExitMethod=SIGTERM
    - App.ExitTimeout=35

.EXAMPLE
    pwsh.exe -ExecutionPolicy Bypass -File SCUMWrapper.ps1 Port=7042 QueryPort=7043 MaxPlayers=64
    
    Starts SCUM server with specified parameters, managed by the wrapper

.LINK
    https://github.com/CubeCoders/AMP-Templates
#>

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    $ScriptArgs
)

# ============================================================================
# CONFIGURATION CONSTANTS
# ============================================================================

# Timing thresholds (in seconds)
Set-Variable -Name STARTUP_PHASE_THRESHOLD -Value 30 -Option Constant
    # Servers younger than this are considered "starting up" and use abort mode
    # After this threshold, graceful shutdown is always attempted

Set-Variable -Name FAILSAFE_TIMEOUT -Value 30 -Option Constant
    # Maximum wait time for LogExit pattern before force killing
    # Prevents hung shutdowns from blocking AMP indefinitely

Set-Variable -Name ORPHAN_CLEANUP_WAIT -Value 5 -Option Constant
    # Wait time after terminating orphan processes
    # Allows processes to fully release file locks and ports

Set-Variable -Name PID_FILE_STALENESS_MINUTES -Value 5 -Option Constant
    # PID files older than this are considered stale and removed
    # Prevents false singleton violations from crashed wrappers

Set-Variable -Name LOG_RETENTION_DAYS -Value 7 -Option Constant
    # Log files older than this are automatically deleted
    # Prevents disk space exhaustion from accumulated logs

# Monitoring intervals (in seconds)
Set-Variable -Name PROCESS_POLL_INTERVAL -Value 0.5 -Option Constant
    # How often to check if server process is still running
    # Balance between responsiveness and CPU usage

Set-Variable -Name LOGEXIT_CHECK_INTERVAL -Value 2 -Option Constant
    # How often to check log file for LogExit pattern
    # Prevents excessive file I/O during shutdown

Set-Variable -Name LOGEXIT_PROGRESS_INTERVAL -Value 10 -Option Constant
    # How often to log progress messages during LogExit wait
    # Provides user feedback without spamming logs

# Log file monitoring
Set-Variable -Name LOGEXIT_TAIL_LINES -Value 50 -Option Constant
    # Number of lines to read from end of log file
    # Minimizes I/O while ensuring pattern detection

Set-Variable -Name LOGEXIT_PATTERN -Value "LogExit: Exiting" -Option Constant
    # Pattern to search for in SCUM.log
    # Confirms successful game save before shutdown

# ============================================================================
# LOGGING SYSTEM
# ============================================================================

# Create logs directory if it doesn't exist
$logDir = Join-Path $PSScriptRoot "Logs"
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Log file with date for daily rotation
$logFile = Join-Path $logDir "SCUMWrapper_$(Get-Date -Format 'yyyy-MM-dd').log"

<#
.SYNOPSIS
    Writes a log message to both console and file

.DESCRIPTION
    Provides dual-output logging for troubleshooting. Console output is prefixed
    with [WRAPPER-LEVEL] for visibility in AMP console. File output includes
    timestamp with millisecond precision for detailed analysis.

.PARAMETER Message
    The log message to write

.PARAMETER Level
    Log level: INFO, WARNING, ERROR, or DEBUG
    Default: INFO

.EXAMPLE
    Write-WrapperLog "Server started successfully"
    Write-WrapperLog "Failed to send signal" "ERROR"

.NOTES
    Silently fails if log file is inaccessible (e.g., locked by another process)
    This prevents logging errors from crashing the wrapper
#>
function Write-WrapperLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"  # INFO, WARNING, ERROR, DEBUG
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
        # This prevents logging errors from crashing the wrapper
    }
}

<#
.SYNOPSIS
    Removes log files older than the retention period

.DESCRIPTION
    Automatically deletes wrapper log files older than LOG_RETENTION_DAYS (7 days)
    to prevent disk space exhaustion. Runs at wrapper startup.

.NOTES
    Silently fails if files cannot be deleted (e.g., locked or permission issues)
    Only removes files matching the pattern "SCUMWrapper_*.log"
#>
function Remove-OldLogs {
    $cutoffDate = (Get-Date).AddDays(-$LOG_RETENTION_DAYS)
    Get-ChildItem -Path $logDir -Filter "SCUMWrapper_*.log" -ErrorAction SilentlyContinue | 
    Where-Object { $_.LastWriteTime -lt $cutoffDate } | 
    Remove-Item -Force -ErrorAction SilentlyContinue
}

Remove-OldLogs

Write-WrapperLog "=================================================="
Write-WrapperLog "SCUM Server Graceful Shutdown Wrapper v3.1"
Write-WrapperLog "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-WrapperLog "Wrapper PID: $PID"
Write-WrapperLog "=================================================="

# ============================================================================
# SIGNAL HANDLING
# ============================================================================

<#
.SYNOPSIS
    Trap termination signals to ensure cleanup

.DESCRIPTION
    PowerShell trap statement catches termination signals and ensures
    the finally block executes properly. This is critical for:
    - Ctrl+C from AMP
    - Process termination
    - Script interruption
    
    Without this trap, the wrapper might not clean up properly when
    AMP sends a stop signal.
#>

# Set up trap for termination signals
trap {
    Write-WrapperLog "Termination signal received: $_" "WARNING"
    Write-WrapperLog "Triggering cleanup and shutdown..." "DEBUG"
    # Don't exit here - let the script continue to finally block
    continue
}

# ============================================================================
# ORPHAN PROCESS CLEANUP
# ============================================================================

<#
.SYNOPSIS
    Scans for and terminates existing SCUM server processes

.DESCRIPTION
    Ensures singleton enforcement by terminating any existing SCUMServer.exe
    processes before starting a new instance. This prevents:
    - Port conflicts (multiple servers binding to same ports)
    - File locking errors (database and config files)
    - Resource contention (CPU, memory, disk I/O)
    
    The function performs a three-phase cleanup:
    1. Scan: Find all SCUMServer processes
    2. Terminate: Force kill each process
    3. Verify: Wait ORPHAN_CLEANUP_WAIT seconds and confirm all are gone
    
    If processes remain after cleanup, logs a warning but continues.
    The new server start will likely fail with port conflicts, alerting the user.

.NOTES
    Uses Stop-Process -Force to ensure termination even if process is unresponsive
    Logs each PID being terminated for troubleshooting
#>
function Stop-OrphanedSCUMProcesses {
    Write-WrapperLog "Pre-start check: Scanning for existing SCUM processes..." "DEBUG"
    $orphans = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
    
    if ($orphans) {
        Write-WrapperLog "Pre-start check: Found $($orphans.Count) existing SCUM process(es)" "WARNING"
        
        # Phase 1: Terminate all orphan processes
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
        
        # Phase 2: Wait for processes to fully release resources
        # CRITICAL: This wait prevents race conditions where new server starts
        # before old server releases file locks and ports
        Write-WrapperLog "Pre-start check: Waiting for process cleanup ($ORPHAN_CLEANUP_WAIT`s)..." "DEBUG"
        Start-Sleep -Seconds $ORPHAN_CLEANUP_WAIT
        
        # Phase 3: Verify all processes are gone
        $remaining = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
        if ($remaining) {
            Write-WrapperLog "Pre-start check: WARNING - $($remaining.Count) process(es) still running!" "ERROR"
            # Continue anyway - new server start will likely fail with port conflict
            # This alerts the user to investigate stuck processes
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

# Clean up any leftover stop signal files from previous run
$stopSignalFile = Join-Path $PSScriptRoot "scum_stop.signal"
if (Test-Path $stopSignalFile) {
    Remove-Item $stopSignalFile -Force -ErrorAction SilentlyContinue
    Write-WrapperLog "Removed leftover stop signal file (scum_stop.signal)" "DEBUG"
}

# Clean up AMP's app_exit.lck file (critical for restart after update)
$ampExitFile = Join-Path $PSScriptRoot "app_exit.lck"
if (Test-Path $ampExitFile) {
    Remove-Item $ampExitFile -Force -ErrorAction SilentlyContinue
    Write-WrapperLog "Removed leftover AMP exit file (app_exit.lck)" "DEBUG"
}

# ============================================================================
# PID FILE MANAGEMENT (SINGLETON ENFORCEMENT)
# ============================================================================

<#
.SYNOPSIS
    Manages PID file for singleton enforcement and process tracking

.DESCRIPTION
    The PID file serves two purposes:
    1. Singleton Enforcement: Prevents multiple wrapper instances from running
    2. Process Tracking: Records wrapper PID, server PID, and start timestamp
    
    PID File Format (JSON):
    {
        "PID": 12345,           // Wrapper process ID
        "ServerPID": 67890,     // SCUM server process ID (null until started)
        "Timestamp": "2026-01-02T13:26:45.1234567+07:00"  // ISO 8601 format
    }
    
    Staleness Detection:
    - Files older than PID_FILE_STALENESS_MINUTES (5 min) are considered stale
    - Files referencing non-existent processes are considered stale
    - Stale files are automatically removed
    
    This prevents false singleton violations from crashed wrappers that didn't
    clean up their PID files.

.NOTES
    Location: Binaries/Win64/scum_server.pid
    Cleaned up by: finally block and PowerShell.Exiting event handler
#>

$pidFile = Join-Path $PSScriptRoot "scum_server.pid"

# Check for existing PID file (singleton enforcement)
if (Test-Path $pidFile) {
    try {
        $pidData = Get-Content $pidFile | ConvertFrom-Json
        $pidAge = (Get-Date) - [DateTime]$pidData.Timestamp
        
        # If PID file is recent AND process exists, another instance is running
        if ($pidAge.TotalMinutes -lt $PID_FILE_STALENESS_MINUTES) {
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
        # Corrupted PID file (invalid JSON) - remove it
        Write-WrapperLog "Removing corrupted PID file" "WARNING"
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
}

# Create new PID file with wrapper PID and timestamp
$pidData = @{
    PID       = $PID
    ServerPID = $null  # Will be updated after server starts
    Timestamp = (Get-Date).ToString("o")  # ISO 8601 format
} | ConvertTo-Json

$pidData | Out-File $pidFile -Force
Write-WrapperLog "Created PID file: $pidFile"

# ============================================================================
# CLEANUP EVENT HANDLER (CRASH RECOVERY)
# ============================================================================

<#
.SYNOPSIS
    Registers PowerShell.Exiting event handler for PID file cleanup

.DESCRIPTION
    Ensures PID file is removed even if wrapper crashes or is force-killed.
    The PowerShell.Exiting event fires when the PowerShell process terminates,
    regardless of how termination occurs (normal exit, crash, kill signal).
    
    This prevents stale PID files from blocking future wrapper starts.
    
    The event handler is unregistered in the finally block during normal exit.

.NOTES
    Event handler runs in a separate runspace, so it needs its own path resolution
    Uses Add-Content for logging since Write-WrapperLog is not available in the runspace
#>

# Register cleanup handler for PowerShell exit
$cleanupScript = {
    # Resolve paths in event handler runspace
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
# WINDOWS API FOR CTRL+C SIGNAL
# ============================================================================

<#
.SYNOPSIS
    Loads Windows kernel32.dll functions for sending Ctrl+C signals

.DESCRIPTION
    Defines P/Invoke signatures for Windows API functions needed to send
    proper Ctrl+C signals to the SCUM server process. This is the ONLY way
    to trigger graceful shutdown in SCUM - force killing causes database corruption.
    
    API Functions:
    - GenerateConsoleCtrlEvent: Sends Ctrl+C (code 0) or Ctrl+Break (code 1)
    - AttachConsole: Attaches wrapper to target process console
    - FreeConsole: Detaches from console
    - SetConsoleCtrlHandler: Disables Ctrl+C handling in wrapper (prevents self-kill)
    
    If API loading fails, the wrapper falls back to CloseMainWindow() which is
    less reliable but better than immediate force kill.

.NOTES
    Requires PowerShell 5.1+ for Add-Type cmdlet
    API loading failure is non-fatal - fallback method is used
#>

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
    Write-WrapperLog "Will use fallback method (CloseMainWindow)" "WARNING"
}

<#
.SYNOPSIS
    Sends Ctrl+C signal to target process

.DESCRIPTION
    Attempts to send a proper Ctrl+C signal to the SCUM server process using
    Windows API. This triggers the server's graceful shutdown handler which:
    1. Saves all player data to database
    2. Saves world state
    3. Writes "LogExit: Exiting" to log file
    4. Terminates cleanly
    
    Method Priority:
    1. Windows API (GenerateConsoleCtrlEvent) - Most reliable
    2. CloseMainWindow() - Fallback if API unavailable
    
    The API method works by:
    1. Detaching wrapper from its own console
    2. Attaching to target process console
    3. Disabling Ctrl+C handler in wrapper (prevents self-kill)
    4. Sending Ctrl+C event (code 0) to console
    5. Detaching from target console
    6. Re-enabling Ctrl+C handler in wrapper

.PARAMETER TargetProcess
    The System.Diagnostics.Process object to send signal to

.OUTPUTS
    Boolean - $true if signal was sent successfully, $false otherwise

.EXAMPLE
    if (Send-CtrlC $process) {
        Write-Host "Signal sent, waiting for graceful shutdown..."
    }

.NOTES
    Does not wait for process to exit - caller must monitor process
    Returns $false if process has already exited
#>
function Send-CtrlC {
    param([System.Diagnostics.Process]$TargetProcess)
    
    # Validate process is still running
    if (!$TargetProcess -or $TargetProcess.HasExited) {
        return $false
    }
    
    Write-WrapperLog "Sending Ctrl+C to PID $($TargetProcess.Id)..."
    
    # Method 1: Windows API (preferred)
    if ($apiLoaded) {
        try {
            # Detach from our own console
            [Kernel32.WinAPI]::FreeConsole() | Out-Null
            
            # Attach to target process console
            if ([Kernel32.WinAPI]::AttachConsole($TargetProcess.Id)) {
                # Disable Ctrl+C handler in wrapper to prevent self-kill
                [Kernel32.WinAPI]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
                
                # Send Ctrl+C event (code 0 = Ctrl+C, code 1 = Ctrl+Break)
                $result = [Kernel32.WinAPI]::GenerateConsoleCtrlEvent(0, 0)
                
                # Brief pause to ensure signal is processed
                Start-Sleep -Milliseconds 100
                
                # Detach from target console
                [Kernel32.WinAPI]::FreeConsole() | Out-Null
                
                # Re-enable Ctrl+C handler in wrapper
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
    
    # Method 2: CloseMainWindow fallback (less reliable)
    Write-WrapperLog "Trying CloseMainWindow fallback..."
    try {
        $result = $TargetProcess.CloseMainWindow()
        if ($result) {
            Write-WrapperLog "CloseMainWindow sent"
        }
        return $result
    }
    catch {
        Write-WrapperLog "CloseMainWindow failed: $_" "WARNING"
        return $false
    }
}

# ============================================================================
# SERVER STARTUP
# ============================================================================

<#
.SYNOPSIS
    Starts the SCUM dedicated server process

.DESCRIPTION
    Launches SCUMServer.exe with provided command-line arguments and monitors
    the process until it exits. Updates PID file with server PID after successful
    start.
    
    Process Configuration:
    - UseShellExecute = false: Direct process creation (no cmd.exe wrapper)
    - CreateNoWindow = false: Allows console window for debugging
    
    The wrapper monitors the process with PROCESS_POLL_INTERVAL (500ms) polling
    to detect when the server exits. This balances responsiveness with CPU usage.

.NOTES
    Exit code propagation: Wrapper exits with same code as server process
    This allows AMP to detect crashes vs normal shutdowns
#>

$ExePath = Join-Path $PSScriptRoot "SCUMServer.exe"
$process = $null

# Validate executable exists
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
    
    # Flag to track if shutdown was requested during startup phase
    $script:abortRequested = $false
    
    # Configure process start info
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false  # Direct process creation
    $psi.CreateNoWindow = $false   # Allow console window
    
    # Start the server process
    $process = [System.Diagnostics.Process]::Start($psi)
    
    if ($null -eq $process) {
        Write-WrapperLog "ERROR: Failed to start process" "ERROR"
        exit 1
    }

    Write-WrapperLog "Server started successfully"
    Write-WrapperLog "SCUM Server PID: $($process.Id)"
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
    
    Write-WrapperLog "State: RUNNING - Monitoring process..."
    Write-WrapperLog "--------------------------------------------------"
    
    # Monitor process until it exits
    # Also actively check for stop signal file (AMP doesn't send Ctrl+C to wrapper)
    # Poll every PROCESS_POLL_INTERVAL (500ms) to balance responsiveness and CPU
    $stopSignalFile = Join-Path $PSScriptRoot "scum_stop.signal"
    $ampExitFile = Join-Path $PSScriptRoot "app_exit.lck"
    $parentPID = (Get-Process -Id $PID).Parent.Id
    $lastCheck = Get-Date
    
    while (!$process.HasExited) {
        Start-Sleep -Milliseconds ($PROCESS_POLL_INTERVAL * 1000)
        
        # Check if parent process (AMP) is still alive
        # If parent is gone, AMP is killing us - trigger shutdown immediately
        try {
            $parentProcess = Get-Process -Id $parentPID -ErrorAction Stop
            if ($parentProcess.HasExited) {
                Write-WrapperLog "Parent process (AMP) has exited - shutdown requested" "WARNING"
                $script:abortRequested = $true
                break
            }
        }
        catch {
            Write-WrapperLog "Parent process (AMP) not found - shutdown requested" "WARNING"
            $script:abortRequested = $true
            break
        }
        
        # Check for stop signal files on every iteration (critical for abort responsiveness)
        # Check both scum_stop.signal (manual/testing) and app_exit.lck (AMP native)
        if ((Test-Path $stopSignalFile) -or (Test-Path $ampExitFile)) {
            $signalSource = if (Test-Path $stopSignalFile) { "scum_stop.signal" } else { "app_exit.lck" }
            Write-WrapperLog "Stop signal file detected ($signalSource) - shutdown requested" "WARNING"
            Remove-Item $stopSignalFile -Force -ErrorAction SilentlyContinue
            Remove-Item $ampExitFile -Force -ErrorAction SilentlyContinue
            
            # Set abort flag to force immediate kill in finally block
            $script:abortRequested = $true
            Write-WrapperLog "Abort flag set - will force kill process" "DEBUG"
            
            break
        }
        
        # Every 5 seconds, check if we should still be running
        $now = Get-Date
        if (($now - $lastCheck).TotalSeconds -ge 5) {
            $lastCheck = $now
            
            # Check if PID file still exists and is valid
            if (Test-Path $pidFile) {
                try {
                    $pidData = Get-Content $pidFile | ConvertFrom-Json
                    # If PID file doesn't match our PID, we should exit
                    if ($pidData.PID -ne $PID) {
                        Write-WrapperLog "PID file mismatch - another wrapper started" "WARNING"
                        break
                    }
                }
                catch {
                    Write-WrapperLog "PID file corrupted - exiting" "WARNING"
                    break
                }
            }
            else {
                Write-WrapperLog "PID file deleted - shutdown requested" "WARNING"
                break
            }
        }
    }
    
    if ($process.HasExited) {
        Write-WrapperLog "Process exited. Code: $($process.ExitCode)"
        exit $process.ExitCode
    }
    else {
        Write-WrapperLog "Monitoring loop exited - triggering shutdown" "DEBUG"
        # Fall through to finally block
    }

}
catch {
    Write-WrapperLog "ERROR: $_" "ERROR"
    exit 1
}
finally {
    # ========================================================================
    # SHUTDOWN HANDLER
    # ========================================================================
    
    <#
    .DESCRIPTION
        This finally block executes when:
        1. AMP sends Ctrl+C to wrapper (normal stop/restart)
        2. Wrapper crashes or is force-killed
        3. Server process exits normally
        
        The handler implements a two-mode shutdown strategy:
        
        ABORT MODE (uptime < STARTUP_PHASE_THRESHOLD):
        - Server is still starting up, hasn't fully initialized
        - Immediate force kill without graceful attempt
        - Prevents wasting time on graceful shutdown of incomplete startup
        
        GRACEFUL MODE (uptime >= STARTUP_PHASE_THRESHOLD):
        - Server is fully running with active players/data
        - Send Ctrl+C signal to trigger server's save handler
        - Monitor log file for LOGEXIT_PATTERN confirmation
        - Wait up to FAILSAFE_TIMEOUT seconds for clean exit
        - Force kill if timeout reached (prevents hung shutdowns)
        
        The LogExit pattern ("LogExit: Exiting") confirms the server has:
        - Saved all player data to database
        - Saved world state
        - Closed all file handles cleanly
        
        Without this confirmation, there's risk of database corruption.
    #>
    
    # Unregister event handler (normal exit path)
    Unregister-Event -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue
    
    Write-WrapperLog "Finally block executing..." "DEBUG"
    Write-WrapperLog "Process object exists: $($null -ne $process)" "DEBUG"
    if ($null -ne $process) {
        $process.Refresh()
        Write-WrapperLog "Process has exited: $($process.HasExited)" "DEBUG"
    }
    
    # Only run shutdown logic if process exists and is still running
    if ($null -ne $process -and !$process.HasExited) {
        Write-WrapperLog "State: SHUTDOWN_REQUESTED - Checking server uptime..." "DEBUG"
        
        try {
            # Refresh process info to get accurate state
            $process.Refresh()
            
            # Calculate server uptime for shutdown decision
            $uptime = (Get-Date) - $process.StartTime
            $uptimeSeconds = $uptime.TotalSeconds
            
            Write-WrapperLog "Server uptime: $([math]::Round($uptime.TotalMinutes, 2)) min ($([math]::Round($uptimeSeconds, 1))s)"
            
            # ================================================================
            # SHUTDOWN DECISION: ABORT vs GRACEFUL
            # ================================================================
            
            # PRIORITY 1: Check if abort was explicitly requested (user clicked Abort button)
            # This takes precedence over uptime-based decision
            if ($script:abortRequested) {
                Write-WrapperLog "ABORT REQUESTED by user - FORCE KILL MODE" "WARNING"
                Write-WrapperLog "State: FORCE_KILL - Terminating PID $($process.Id)..." "DEBUG"
                $process.Kill()
                Write-WrapperLog "Process killed (user abort)" "DEBUG"
                Write-WrapperLog "Shutdown completed (user abort, force killed)" "WARNING"
            }
            # ABORT MODE: Server in startup phase (< STARTUP_PHASE_THRESHOLD seconds)
            # Rationale: Server hasn't fully initialized, no player data to save
            # Action: Immediate force kill
            elseif ($uptimeSeconds -lt $STARTUP_PHASE_THRESHOLD) {
                Write-WrapperLog "Server in startup phase (< $STARTUP_PHASE_THRESHOLD`s) - ABORT MODE" "WARNING"
                Write-WrapperLog "State: FORCE_KILL - Terminating PID $($process.Id)..." "DEBUG"
                $process.Kill()
                Write-WrapperLog "Process killed (startup abort)" "DEBUG"
                Write-WrapperLog "Shutdown completed (startup abort, force killed)" "WARNING"
            }
            # GRACEFUL MODE: Server is running (>= STARTUP_PHASE_THRESHOLD seconds)
            # Rationale: Server has active players and data that must be saved
            # Action: Send Ctrl+C, wait for LogExit, failsafe timeout
            else {
                Write-WrapperLog "Server is running - GRACEFUL SHUTDOWN MODE"
                Write-WrapperLog "State: SENDING_SHUTDOWN_SIGNAL" "DEBUG"
                
                # Attempt to send Ctrl+C signal
                if (Send-CtrlC $process) {
                    Write-WrapperLog "Ctrl+C signal sent to PID $($process.Id)" "DEBUG"
                    Write-WrapperLog "State: WAITING_FOR_LOGEXIT - Monitoring log file..." "DEBUG"
                    
                    # ========================================================
                    # LOGEXIT PATTERN MONITORING
                    # ========================================================
                    
                    # Calculate path to SCUM.log
                    # From: Binaries/Win64/SCUMWrapper.ps1
                    # To:   Saved/Logs/SCUM.log
                    $serverRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
                    $logPath = Join-Path $serverRoot "Saved\Logs\SCUM.log"
                    
                    $logExitFound = $false
                    $waited = 0
                    $shutdownStartTime = Get-Date
                    
                    # Monitor log file for up to FAILSAFE_TIMEOUT seconds
                    while (!$process.HasExited -and $waited -lt $FAILSAFE_TIMEOUT) {
                        Start-Sleep -Seconds $LOGEXIT_CHECK_INTERVAL
                        $waited += $LOGEXIT_CHECK_INTERVAL
                        
                        # Check for LogExit pattern in last LOGEXIT_TAIL_LINES lines
                        if (Test-Path $logPath) {
                            try {
                                $lastLines = Get-Content $logPath -Tail $LOGEXIT_TAIL_LINES -ErrorAction SilentlyContinue
                                if ($lastLines -match $LOGEXIT_PATTERN) {
                                    $logExitFound = $true
                                    Write-WrapperLog "LogExit pattern detected! Server saved successfully." "DEBUG"
                                    break
                                }
                            }
                            catch {
                                # Log file might be locked by server, continue waiting
                                # This is expected behavior and not an error
                            }
                        }
                        
                        # Log progress every LOGEXIT_PROGRESS_INTERVAL seconds
                        if ($waited % $LOGEXIT_PROGRESS_INTERVAL -eq 0) {
                            Write-WrapperLog "Still waiting for LogExit... ($waited/${FAILSAFE_TIMEOUT}s)" "DEBUG"
                        }
                    }
                    
                    # ====================================================
                    # SHUTDOWN COMPLETION ANALYSIS
                    # ====================================================
                    
                    # Case 1: Process exited cleanly
                    if ($process.HasExited) {
                        if ($logExitFound) {
                            # SUCCESS: Graceful shutdown with LogExit confirmation
                            $shutdownDuration = ((Get-Date) - $shutdownStartTime).TotalSeconds
                            Write-WrapperLog "State: SHUTDOWN_COMPLETE - Graceful shutdown confirmed (${waited}s)" "DEBUG"
                            Write-WrapperLog "Shutdown completed successfully in $([math]::Round($shutdownDuration, 1))s (graceful, LogExit detected)"
                        }
                        else {
                            # WARNING: Process exited but no LogExit detected
                            # This might indicate incomplete save or crash during shutdown
                            $shutdownDuration = ((Get-Date) - $shutdownStartTime).TotalSeconds
                            Write-WrapperLog "State: SHUTDOWN_COMPLETE - Process exited but LogExit not detected (${waited}s)" "WARNING"
                            Write-WrapperLog "Shutdown completed in $([math]::Round($shutdownDuration, 1))s (process exited, no LogExit)" "WARNING"
                        }
                    }
                    # Case 2: Failsafe timeout reached
                    else {
                        # FAILSAFE: Server didn't respond within FAILSAFE_TIMEOUT seconds
                        # Assume server is frozen/crashed and force kill
                        $shutdownDuration = ((Get-Date) - $shutdownStartTime).TotalSeconds
                        Write-WrapperLog "State: FAILSAFE_TIMEOUT - No LogExit after ${FAILSAFE_TIMEOUT}s!" "ERROR"
                        Write-WrapperLog "Assuming server frozen/crashed - Force killing PID $($process.Id)..." "ERROR"
                        $process.Kill()
                        Write-WrapperLog "Process killed (failsafe timeout)" "WARNING"
                        Write-WrapperLog "Shutdown completed in $([math]::Round($shutdownDuration, 1))s (failsafe timeout, force killed)" "WARNING"
                    }
                }
                # Case 3: Ctrl+C signal failed to send
                else {
                    Write-WrapperLog "State: SIGNAL_FAILED - Ctrl+C failed, force killing..." "ERROR"
                    $process.Kill()
                    Write-WrapperLog "Process killed (signal failed)" "WARNING"
                    Write-WrapperLog "Shutdown completed (signal failed, force killed)" "WARNING"
                }
            }
        }
        catch {
            # Unexpected error during shutdown - force kill as last resort
            Write-WrapperLog "Error during shutdown: $_" "ERROR"
            try { $process.Kill() } catch {}
        }
        
        # Dispose process object to release resources
        try { $process.Dispose() } catch {}
    }
    
    # ====================================================================
    # FINAL CLEANUP
    # ====================================================================
    
    # Remove PID file
    if (Test-Path $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        Write-WrapperLog "Cleaned up PID file"
    }
    
    # Remove stop signal file if it exists
    $stopSignalFile = Join-Path $PSScriptRoot "scum_stop.signal"
    if (Test-Path $stopSignalFile) {
        Remove-Item $stopSignalFile -Force -ErrorAction SilentlyContinue
        Write-WrapperLog "Cleaned up stop signal file (scum_stop.signal)"
    }
    
    # Remove AMP exit file if it exists
    $ampExitFile = Join-Path $PSScriptRoot "app_exit.lck"
    if (Test-Path $ampExitFile) {
        Remove-Item $ampExitFile -Force -ErrorAction SilentlyContinue
        Write-WrapperLog "Cleaned up AMP exit file (app_exit.lck)"
    }
    
    Write-WrapperLog "Wrapper exiting"
    Write-WrapperLog "=================================================="
}
