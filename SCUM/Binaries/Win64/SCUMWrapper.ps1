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
    - Server ready detection via log monitoring (not time-based)
    - Comprehensive dual logging (console + file)
    - Automatic log rotation (7-day retention)
    - Event-based cleanup handlers for crash recovery
    - **Windows Job Objects for automatic child termination (ABORT FIX)**
    
    ABORT FIX (v3.2):
    The critical fix for orphan processes during Abort uses Windows Job Objects.
    When AMP sends OS_CLOSE (WM_EXIT) to kill the wrapper during startup:
    1. Wrapper process is terminated by Windows immediately
    2. Job Object automatically kills SCUMServer.exe child process
    3. No orphan process left running
    
    This is the ONLY reliable solution on Windows because:
    - Wrapper cannot catch WM_EXIT in time to kill child manually
    - Parent process monitoring in loop doesn't execute before wrapper dies
    - File-based signaling doesn't work (AMP doesn't create files with OS_CLOSE)
    - Ctrl+C signals don't work with PowerShell wrapper
    
    Job Objects are a Windows kernel feature that guarantees child process
    termination when parent dies, regardless of how parent is killed.

.PARAMETER ScriptArgs
    Command-line arguments to pass to SCUMServer.exe
    These are forwarded directly to the game server executable

.NOTES
    Version:        3.2 (ABORT FIX - Job Objects)
    Author:         CubeCoders AMP Template
    Purpose:        Ensure data integrity and prevent database corruption
    Requirements:   PowerShell 7.0+, Windows Server
    
    CRITICAL: This wrapper must be configured in scum.kvp with:
    - App.ExitMethod=OS_CLOSE
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
# GLOBAL VARIABLES
# ============================================================================

# Global variable to store server process (for cleanup on error)
$global:ServerProcess = $null
$global:ServerLogPath = ""

# ============================================================================
# ORPHAN PROCESS CLEANUP
# ============================================================================

<#
.SYNOPSIS
    Scans for and terminates orphaned SCUM server processes for THIS instance only

.DESCRIPTION
    Ensures singleton enforcement by checking PID file and terminating only
    the process that belongs to THIS wrapper instance. This prevents:
    - Killing processes from other AMP instances
    - Port conflicts (multiple servers binding to same ports)
    - File locking errors (database and config files)
    
    The function performs a safe cleanup:
    1. Check PID file for this instance's previous server PID
    2. If PID exists and process is running, terminate it
    3. Verify process is gone before continuing
    
    CRITICAL: Does NOT scan all SCUMServer processes - only checks PID file
    This allows multiple SCUM instances to run on the same machine.

.NOTES
    Uses Stop-Process -Force to ensure termination even if process is unresponsive
    Only terminates processes recorded in THIS instance's PID file
#>
function Stop-OrphanedSCUMProcesses {
    Write-WrapperLog "Pre-start check: Checking for orphaned process from previous run..." "DEBUG"
    
    # Check if PID file exists from previous run
    if (Test-Path $pidFile) {
        try {
            $pidData = Get-Content $pidFile | ConvertFrom-Json
            
            # Check if there's a recorded server PID
            if ($pidData.ServerPID) {
                $orphanPID = $pidData.ServerPID
                
                # Check if that specific PID is still running
                $orphanProcess = Get-Process -Id $orphanPID -ErrorAction SilentlyContinue
                
                if ($orphanProcess -and $orphanProcess.ProcessName -eq "SCUMServer") {
                    Write-WrapperLog "Pre-start check: Found orphaned process PID: $orphanPID (from previous run)" "WARNING"
                    
                    try {
                        Stop-Process -Id $orphanPID -Force -ErrorAction Stop
                        Write-WrapperLog "Pre-start check: Successfully terminated orphaned PID: $orphanPID" "DEBUG"
                        
                        # Wait for process to fully release resources
                        Write-WrapperLog "Pre-start check: Waiting for process cleanup ($ORPHAN_CLEANUP_WAIT`s)..." "DEBUG"
                        Start-Sleep -Seconds $ORPHAN_CLEANUP_WAIT
                        
                        # Verify process is gone
                        $stillRunning = Get-Process -Id $orphanPID -ErrorAction SilentlyContinue
                        if ($stillRunning) {
                            Write-WrapperLog "Pre-start check: WARNING - Process $orphanPID still running!" "ERROR"
                        }
                        else {
                            Write-WrapperLog "Pre-start check: Process terminated successfully" "DEBUG"
                        }
                    }
                    catch {
                        Write-WrapperLog "Pre-start check: Failed to terminate PID $orphanPID`: $_" "ERROR"
                    }
                }
                else {
                    Write-WrapperLog "Pre-start check: Previous server PID $orphanPID is not running - clean state" "DEBUG"
                }
            }
            else {
                Write-WrapperLog "Pre-start check: No server PID recorded in PID file - clean state" "DEBUG"
            }
        }
        catch {
            Write-WrapperLog "Pre-start check: Could not read PID file: $_" "WARNING"
        }
    }
    else {
        Write-WrapperLog "Pre-start check: No PID file found - clean state" "DEBUG"
    }
}

# Run orphan cleanup before starting
Stop-OrphanedSCUMProcesses

# Clean up any leftover files from previous run
$stopSignalFile = Join-Path $PSScriptRoot "scum_stop.signal"
if (Test-Path $stopSignalFile) {
    Remove-Item $stopSignalFile -Force -ErrorAction SilentlyContinue
    Write-WrapperLog "Removed leftover stop signal file (scum_stop.signal)" "DEBUG"
}

$serverReadyFlagFile = Join-Path $PSScriptRoot "server_ready.flag"
if (Test-Path $serverReadyFlagFile) {
    Remove-Item $serverReadyFlagFile -Force -ErrorAction SilentlyContinue
    Write-WrapperLog "Removed leftover server ready flag file" "DEBUG"
}

# CRITICAL: Check if AMP already sent abort signal BEFORE we started
# This can happen if there's a delay between orphan cleanup and new start
$ampExitFile = Join-Path $PSScriptRoot "app_exit.lck"
if (Test-Path $ampExitFile) {
    Write-WrapperLog "ABORT signal detected BEFORE server start (app_exit.lck exists)" "WARNING"
    Write-WrapperLog "AMP already requested abort - exiting without starting server" "WARNING"
    Remove-Item $ampExitFile -Force -ErrorAction SilentlyContinue
    
    # Clean up PID file
    if (Test-Path $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    
    Write-WrapperLog "Wrapper exiting (pre-start abort)" "DEBUG"
    Write-WrapperLog "==================================================" "DEBUG"
    exit 0
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
        
        Write-WrapperLog "Found existing PID file (age: $([math]::Round($pidAge.TotalMinutes, 1)) min, Wrapper PID: $($pidData.PID), Server PID: $($pidData.ServerPID))" "DEBUG"
        
        # Check if wrapper process is still running
        $wrapperRunning = $false
        try {
            $wrapperProcess = Get-Process -Id $pidData.PID -ErrorAction Stop
            $wrapperRunning = $true
            Write-WrapperLog "Wrapper process PID $($pidData.PID) is still running" "DEBUG"
        }
        catch {
            Write-WrapperLog "Wrapper process PID $($pidData.PID) is not running" "DEBUG"
        }
        
        # Check if server process is still running
        $serverRunning = $false
        if ($pidData.ServerPID) {
            try {
                $serverProcess = Get-Process -Id $pidData.ServerPID -ErrorAction Stop
                if ($serverProcess.ProcessName -eq "SCUMServer") {
                    $serverRunning = $true
                    Write-WrapperLog "Server process PID $($pidData.ServerPID) is still running" "WARNING"
                }
            }
            catch {
                Write-WrapperLog "Server process PID $($pidData.ServerPID) is not running" "DEBUG"
            }
        }
        
        # Decision logic:
        # 1. If wrapper is running AND file is recent (< 5 min) → Another instance is running (ERROR)
        # 2. If server is running → Orphan server detected, terminate it
        # 3. If neither running → Stale file, remove it
        
        if ($wrapperRunning -and $pidAge.TotalMinutes -lt $PID_FILE_STALENESS_MINUTES) {
            # Another wrapper instance is actively running
            Write-WrapperLog "ERROR: Another wrapper instance is running (PID: $($pidData.PID))" "ERROR"
            Write-WrapperLog "If this is incorrect, delete: $pidFile" "ERROR"
            exit 1
        }
        elseif ($serverRunning) {
            # Orphan server detected - wrapper died but server still running
            Write-WrapperLog "Orphan server detected (PID: $($pidData.ServerPID)) - terminating..." "WARNING"
            try {
                Stop-Process -Id $pidData.ServerPID -Force -ErrorAction Stop
                Write-WrapperLog "Orphan server PID $($pidData.ServerPID) terminated" "DEBUG"
                
                # Wait for process to fully release resources
                Start-Sleep -Seconds $ORPHAN_CLEANUP_WAIT
                
                # Verify termination
                $stillRunning = Get-Process -Id $pidData.ServerPID -ErrorAction SilentlyContinue
                if ($stillRunning) {
                    Write-WrapperLog "WARNING: Orphan server PID $($pidData.ServerPID) still running!" "ERROR"
                }
            }
            catch {
                Write-WrapperLog "Failed to terminate orphan server PID $($pidData.ServerPID): $_" "ERROR"
            }
            
            # Remove stale PID file
            Remove-Item $pidFile -Force
            Write-WrapperLog "Removed PID file after orphan cleanup" "DEBUG"
        }
        else {
            # Stale PID file - both wrapper and server are gone
            Write-WrapperLog "Removing stale PID file (age: $([math]::Round($pidAge.TotalMinutes, 1)) min)" "DEBUG"
            Remove-Item $pidFile -Force
        }
    }
    catch {
        # Corrupted PID file (invalid JSON) - remove it
        Write-WrapperLog "Removing corrupted PID file: $_" "WARNING"
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
}
else {
    Write-WrapperLog "No existing PID file found - clean state" "DEBUG"
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
# WINDOWS API FOR CTRL+C SIGNAL AND JOB OBJECTS
# ============================================================================

<#
.SYNOPSIS
    Loads Windows kernel32.dll functions for sending Ctrl+C signals and Job Objects

.DESCRIPTION
    Defines P/Invoke signatures for Windows API functions needed to:
    1. Send proper Ctrl+C signals to the SCUM server process
    2. Create Job Objects to ensure child process dies with parent
    
    Ctrl+C API Functions:
    - GenerateConsoleCtrlEvent: Sends Ctrl+C (code 0) or Ctrl+Break (code 1)
    - AttachConsole: Attaches wrapper to target process console
    - FreeConsole: Detaches from console
    - SetConsoleCtrlHandler: Disables Ctrl+C handling in wrapper (prevents self-kill)
    
    Job Object API Functions (CRITICAL FOR ABORT FIX):
    - CreateJobObject: Creates a job object to group processes
    - AssignProcessToJobObject: Assigns child process to job
    - SetInformationJobObject: Configures job to kill children when parent dies
    
    Job Objects ensure that when AMP kills the wrapper (via OS_CLOSE/WM_EXIT),
    the SCUMServer.exe child process is automatically terminated by Windows.
    This solves the orphan process problem during Abort.

.NOTES
    Requires PowerShell 5.1+ for Add-Type cmdlet
    API loading failure is non-fatal - fallback method is used
#>

$signature = @'
// Ctrl+C Signal APIs
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AttachConsole(uint dwProcessId);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FreeConsole();

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleCtrlHandler(IntPtr HandlerRoutine, bool Add);

// Job Object APIs (for automatic child process termination)
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(IntPtr hObject);

// Job Object structures
[StructLayout(LayoutKind.Sequential)]
public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
{
    public long PerProcessUserTimeLimit;
    public long PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass;
    public uint SchedulingClass;
}

[StructLayout(LayoutKind.Sequential)]
public struct IO_COUNTERS
{
    public ulong ReadOperationCount;
    public ulong WriteOperationCount;
    public ulong OtherOperationCount;
    public ulong ReadTransferCount;
    public ulong WriteTransferCount;
    public ulong OtherTransferCount;
}

[StructLayout(LayoutKind.Sequential)]
public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
{
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
}

// Constants
public const int JobObjectExtendedLimitInformation = 9;
public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
'@

try {
    Add-Type -MemberDefinition $signature -Name 'WinAPI' -Namespace 'Kernel32' -ErrorAction Stop | Out-Null
    $apiLoaded = $true
    Write-WrapperLog "Windows API loaded successfully (Ctrl+C + Job Objects)"
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
    Starts the SCUM dedicated server process with Job Object protection

.DESCRIPTION
    Launches SCUMServer.exe with provided command-line arguments and assigns
    it to a Windows Job Object. The Job Object ensures that when the wrapper
    process is killed by AMP (via OS_CLOSE/WM_EXIT during Abort), Windows
    automatically terminates the child SCUMServer.exe process.
    
    This solves the orphan process problem:
    - User clicks "Abort" during startup
    - AMP sends WM_EXIT to wrapper process
    - Wrapper is killed before it can react
    - Job Object ensures child dies with parent
    - No orphan SCUMServer.exe left running
    
    Process Configuration:
    - UseShellExecute = false: Direct process creation (no cmd.exe wrapper)
    - CreateNoWindow = false: Allows console window for debugging
    
    The wrapper monitors the process with PROCESS_POLL_INTERVAL (500ms) polling
    to detect when the server exits. This balances responsiveness with CPU usage.

.NOTES
    Exit code propagation: Wrapper exits with same code as server process
    This allows AMP to detect crashes vs normal shutdowns
    
    Job Object handle is intentionally NOT closed - it must remain open for
    the lifetime of the wrapper. When wrapper exits, Windows closes the handle
    and terminates all processes in the job.
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
    
    # Flag to track server ready state (not just process started)
    # This is set to true when wrapper outputs "State: RUNNING" which triggers AMP's AppReadyRegex
    # Used to distinguish between ABORT (before ready) and GRACEFUL STOP (after ready)
    $script:serverReady = $false
    Write-WrapperLog "Server ready flag initialized: false" "DEBUG"
    
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

    # CRITICAL: Store process in global variable for trap handler
    $global:ServerProcess = $process
    
    # Calculate and store SCUM log path for trap handler
    $serverRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $global:ServerLogPath = Join-Path $serverRoot "Saved\Logs\SCUM.log"

    Write-WrapperLog "Server started successfully"
    Write-WrapperLog "SCUM Server PID: $($process.Id)"
    Write-WrapperLog "Wrapper PID: $PID" "DEBUG"
    Write-WrapperLog "SCUM Log Path: $global:ServerLogPath" "DEBUG"
    
    # ========================================================================
    # CRITICAL: START EXTERNAL WATCHDOG (ORPHAN PREVENTION)
    # ========================================================================
    
    <#
    .DESCRIPTION
        The watchdog is a separate PowerShell process that monitors the wrapper.
        If the wrapper dies (killed by AMP during Abort), the watchdog immediately
        kills the SCUMServer.exe process.
        
        This solves the fundamental problem:
        - AMP sends WM_EXIT to wrapper
        - Wrapper dies before trap can execute
        - Watchdog survives and kills server
        
        The watchdog runs completely independently and will continue even if
        the wrapper is force-killed.
    #>
    
    Write-WrapperLog "=================================================="
    Write-WrapperLog "STARTING EXTERNAL WATCHDOG (Orphan Prevention)"
    Write-WrapperLog "=================================================="
    
    try {
        $watchdogScript = Join-Path $PSScriptRoot "SCUMWatchdog.ps1"
        
        Write-WrapperLog "Step 1: Locating watchdog script..." "DEBUG"
        Write-WrapperLog "  - Script path: $watchdogScript" "DEBUG"
        
        if (!(Test-Path $watchdogScript)) {
            Write-WrapperLog "  ✗ ERROR: Watchdog script not found!" "ERROR"
            Write-WrapperLog "  Expected location: $watchdogScript" "ERROR"
            Write-WrapperLog "  ORPHAN PREVENTION WILL NOT WORK!" "ERROR"
            Write-WrapperLog "  Server may become orphaned if wrapper is killed during startup" "ERROR"
        }
        else {
            Write-WrapperLog "  ✓ Watchdog script found" "DEBUG"
            
            Write-WrapperLog "Step 2: Preparing watchdog arguments..." "DEBUG"
            # Start watchdog as a separate process (hidden window)
            $watchdogArgs = @(
                "-ExecutionPolicy", "Bypass",
                "-File", "`"$watchdogScript`"",
                "-WrapperPID", $PID,
                "-ServerPID", $process.Id,
                "-PIDFile", "`"scum_server.pid`"",
                "-SCUMLogPath", "`"$global:ServerLogPath`""
            )
            
            Write-WrapperLog "  - Wrapper PID: $PID" "DEBUG"
            Write-WrapperLog "  - Server PID: $($process.Id)" "DEBUG"
            Write-WrapperLog "  - PID File: scum_server.pid" "DEBUG"
            Write-WrapperLog "  - SCUM Log Path: $global:ServerLogPath" "DEBUG"
            
            Write-WrapperLog "Step 3: Starting watchdog process..." "DEBUG"
            $watchdogPsi = New-Object System.Diagnostics.ProcessStartInfo
            $watchdogPsi.FileName = "pwsh.exe"
            $watchdogPsi.Arguments = $watchdogArgs -join " "
            $watchdogPsi.UseShellExecute = $false
            $watchdogPsi.CreateNoWindow = $true  # Run hidden
            $watchdogPsi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            
            $watchdogStartTime = Get-Date
            $watchdogProcess = [System.Diagnostics.Process]::Start($watchdogPsi)
            $watchdogStartDuration = ((Get-Date) - $watchdogStartTime).TotalMilliseconds
            
            if ($null -ne $watchdogProcess) {
                Write-WrapperLog "  ✓ Watchdog started successfully" "DEBUG"
                Write-WrapperLog "  - Watchdog PID: $($watchdogProcess.Id)" "DEBUG"
                Write-WrapperLog "  - Start duration: $([math]::Round($watchdogStartDuration, 0))ms" "DEBUG"
                Write-WrapperLog "  - Process name: $($watchdogProcess.ProcessName)" "DEBUG"
                
                # Give watchdog time to initialize
                Write-WrapperLog "Step 4: Waiting for watchdog initialization..." "DEBUG"
                Start-Sleep -Milliseconds 500
                
                # Verify watchdog is still running
                try {
                    $watchdogProcess.Refresh()
                    if (!$watchdogProcess.HasExited) {
                        Write-WrapperLog "  ✓ Watchdog confirmed running" "DEBUG"
                        Write-WrapperLog "=================================================="
                        Write-WrapperLog "ORPHAN PREVENTION ACTIVE" "DEBUG"
                        Write-WrapperLog "  Watchdog will kill server if wrapper dies unexpectedly"
                        Write-WrapperLog "  This protects against Abort button during startup"
                        Write-WrapperLog "=================================================="
                    }
                    else {
                        Write-WrapperLog "  ✗ WARNING: Watchdog exited immediately!" "ERROR"
                        Write-WrapperLog "  Exit code: $($watchdogProcess.ExitCode)" "ERROR"
                        Write-WrapperLog "  Check watchdog log for errors" "ERROR"
                    }
                }
                catch {
                    Write-WrapperLog "  ✗ WARNING: Could not verify watchdog status: $_" "WARNING"
                }
            }
            else {
                Write-WrapperLog "  ✗ ERROR: Failed to start watchdog process" "ERROR"
                Write-WrapperLog "  ORPHAN PREVENTION WILL NOT WORK!" "ERROR"
            }
        }
    }
    catch {
        Write-WrapperLog "✗ EXCEPTION while starting watchdog: $_" "ERROR"
        Write-WrapperLog "Stack trace: $($_.ScriptStackTrace)" "ERROR"
        Write-WrapperLog "ORPHAN PREVENTION WILL NOT WORK!" "ERROR"
    }
    
    Write-WrapperLog "=================================================="
    
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
    
    Write-WrapperLog "State: STARTING - Waiting for server to be ready..."
    Write-WrapperLog "--------------------------------------------------"
    
    # ========================================================================
    # SIMPLIFIED APPROACH: Use AMP's existing detection
    # ========================================================================
    # Instead of trying to read SCUM.log ourselves, we rely on the fact that
    # AMP's Console.AppReadyRegex already detects "LogSCUM: Global Stats"
    # from the server's console output.
    #
    # We just need to wait a reasonable amount of time for the server to
    # reach that state, then create the flag and output our ready pattern.
    #
    # This is simpler and more reliable than trying to read log files.
    # ========================================================================
    
    $maxWaitTime = 120 # 2 minutes (SCUM usually takes 30-60 seconds)
    $startTime = Get-Date
    $serverReady = $false
    
    Write-WrapperLog "Waiting for server to reach ready state (max ${maxWaitTime}s)..." "DEBUG"
    Write-WrapperLog "Monitoring server process health..." "DEBUG"
    
    $checkCount = 0
    while (((Get-Date) - $startTime).TotalSeconds -lt $maxWaitTime) {
        $checkCount++
        
        # Check if server process is still alive
        if ($process.HasExited) {
            Write-WrapperLog "Server process died during startup!" "ERROR"
            Write-WrapperLog "Exit code: $($process.ExitCode)" "ERROR"
            break
        }
        
        # Check server memory usage as a proxy for "ready" state
        # SCUM server typically uses 8-10 GB when fully loaded
        try {
            $process.Refresh()
            $memoryMB = [math]::Round($process.WorkingSet64 / 1MB, 0)
            
            if ($checkCount % 10 -eq 0) {
                $elapsed = ((Get-Date) - $startTime).TotalSeconds
                Write-WrapperLog "Check #${checkCount} (${elapsed}s): Server memory: ${memoryMB} MB" "DEBUG"
            }
            
            # If server is using > 8 GB, it's probably ready
            if ($memoryMB -gt 8000) {
                $elapsed = ((Get-Date) - $startTime).TotalSeconds
                Write-WrapperLog "✓ Server appears READY (memory: ${memoryMB} MB after $([math]::Round($elapsed, 1))s)"
                $serverReady = $true
                break
            }
        }
        catch {
            Write-WrapperLog "Error checking server status (check #${checkCount}): $_" "WARNING"
        }
        
        Start-Sleep -Seconds 2
    }
    
    # If we didn't detect ready state by memory, assume it's ready after timeout
    if (-not $serverReady -and -not $process.HasExited) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        Write-WrapperLog "Timeout reached (${elapsed}s). Assuming server is ready..." "WARNING"
        $serverReady = $true
    }
    
    # Create flag file if server is ready
    $serverReadyFlagFile = Join-Path $PSScriptRoot "server_ready.flag"
    if ($serverReady) {
        try {
            "READY" | Out-File $serverReadyFlagFile -Force -ErrorAction Stop
            Write-WrapperLog "✓ Server ready flag created: $serverReadyFlagFile" "DEBUG"
            Write-WrapperLog "  From this point, Stop = Graceful Shutdown" "DEBUG"
        }
        catch {
            Write-WrapperLog "Failed to create server ready flag: $_" "WARNING"
        }
    }
    else {
        Write-WrapperLog "Server did not reach ready state (process died)" "ERROR"
        Write-WrapperLog "Flag NOT created - watchdog will FORCE KILL if wrapper dies" "WARNING"
    }
    
    # ========================================================================
    # NOW OUTPUT THE AMP READY PATTERN
    # ========================================================================
    # This line triggers AMP's Console.AppReadyRegex:
    #   ^\[WRAPPER-DEBUG\] State: RUNNING - Monitoring process\.\.\.
    # 
    # After this line, AMP will:
    #   - Change state from "Starting" to "Started"
    #   - Show "Stop" button instead of "Abort"
    #   - Consider the server as fully started
    # ========================================================================
    Write-WrapperLog "State: RUNNING - Monitoring process..."
    Write-WrapperLog "--------------------------------------------------"
    
    # Monitor process until it exits
    $lastHeartbeat = Get-Date
    
    while (!$process.HasExited) {
        Start-Sleep -Milliseconds ($PROCESS_POLL_INTERVAL * 1000)
        
        # HEARTBEAT: Output log every 5 seconds to let AMP know we're alive
        $now = Get-Date
        if (($now - $lastHeartbeat).TotalSeconds -ge 5) {
            $lastHeartbeat = $now
            Write-WrapperLog "Heartbeat: Wrapper alive, monitoring server PID $($process.Id)" "DEBUG"
        }
    }
    
    # Process exited normally
    Write-WrapperLog "Process exited. Code: $($process.ExitCode)"
    exit $process.ExitCode

}
catch {
    Write-WrapperLog "ERROR: $_" "ERROR"
    
    # Cleanup on error
    $pidFile = Join-Path $PSScriptRoot "scum_server.pid"
    if (Test-Path $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    
    # Unregister event handler
    Unregister-Event -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue
    
    exit 1
}
