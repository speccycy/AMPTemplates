param(
    [Parameter(ValueFromRemainingArguments = $true)]
    $ScriptArgs
)

# PowerShell wrapper for SCUM Server to enable graceful shutdown via Ctrl+C
# This script sends proper console control events to allow database saving

# Add Windows API signatures for sending Ctrl+C
$signature = @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleCtrlHandler(IntPtr HandlerRoutine, bool Add);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AttachConsole(uint dwProcessId);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FreeConsole();

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AllocConsole();
'@

try {
    Add-Type -MemberDefinition $signature -Name 'ConsoleControl' -Namespace 'Win32' -ErrorAction Stop
    Write-Host "[Wrapper] Console control API loaded."
}
catch {
    Write-Host "[Wrapper] Warning: Could not load console control API. Fallback methods will be used."
}

$ExePath = Join-Path $PSScriptRoot "SCUMServer.exe"
$process = $null
$isShuttingDown = $false

# Graceful shutdown function
function Send-GracefulShutdown {
    param($proc)
    
    if ($isShuttingDown) {
        Write-Host "[Wrapper] Already shutting down..."
        return
    }
    
    $script:isShuttingDown = $true
    Write-Host "[Wrapper] Initiating graceful shutdown..."
    
    if (($null -eq $proc) -or $proc.HasExited) {
        Write-Host "[Wrapper] Process already exited."
        return
    }

    # Method 1: Try using GenerateConsoleCtrlEvent if API is loaded
    $hasConsoleControlAPI = $false
    try {
        $hasConsoleControlAPI = ($null -ne ([System.Management.Automation.PSTypeName]'Win32.ConsoleControl').Type)
    }
    catch {
        $hasConsoleControlAPI = $false
    }
    
    if ($hasConsoleControlAPI) {
        Write-Host "[Wrapper] Attempting Ctrl+C via GenerateConsoleCtrlEvent..."
        
        try {
            # Detach from our console
            [Win32.ConsoleControl]::FreeConsole() | Out-Null
            
            # Attach to child process console
            if ([Win32.ConsoleControl]::AttachConsole($proc.Id)) {
                Write-Host "[Wrapper] Attached to process console."
                
                # Disable Ctrl+C handling in this script so we don't terminate ourselves
                [Win32.ConsoleControl]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
                
                # Send Ctrl+C event (CTRL_C_EVENT = 0)
                $result = [Win32.ConsoleControl]::GenerateConsoleCtrlEvent(0, 0)
                
                if ($result) {
                    Write-Host "[Wrapper] Ctrl+C signal sent successfully."
                }
                else {
                    Write-Host "[Wrapper] Failed to send Ctrl+C signal."
                }
                
                Start-Sleep -Milliseconds 500
                
                # Detach and restore our console
                [Win32.ConsoleControl]::FreeConsole() | Out-Null
                [Win32.ConsoleControl]::AllocConsole() | Out-Null
                [Win32.ConsoleControl]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) | Out-Null
            }
            else {
                Write-Host "[Wrapper] Could not attach to process console."
            }
        }
        catch {
            Write-Host "[Wrapper] Error sending Ctrl+C: $_"
        }
    }
    
    # Method 2: Fallback to CloseMainWindow (less reliable for console apps)
    if (!$proc.HasExited) {
        Write-Host "[Wrapper] Trying CloseMainWindow as fallback..."
        try {
            $proc.CloseMainWindow() | Out-Null
        }
        catch {
            Write-Host "[Wrapper] CloseMainWindow failed: $_"
        }
    }
    
    # Wait for graceful exit
    $TimeoutSeconds = 60
    Write-Host "[Wrapper] Waiting up to $TimeoutSeconds seconds for graceful exit..."
    
    $waited = 0
    $checkInterval = 2
    while (!$proc.HasExited -and $waited -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $checkInterval
        $waited += $checkInterval
        if ($waited % 10 -eq 0) {
            Write-Host "[Wrapper] Still waiting... ($waited/$TimeoutSeconds seconds)"
        }
    }
    
    if ($proc.HasExited) {
        Write-Host "[Wrapper] Process exited gracefully after $waited seconds."
        Write-Host "[Wrapper] Exit code: $($proc.ExitCode)"
    }
    else {
        Write-Host "[Wrapper] Timeout reached. Forcefully terminating..."
        try {
            $proc.Kill()
            $proc.WaitForExit(5000)
            Write-Host "[Wrapper] Process forcefully terminated."
        }
        catch {
            Write-Host "[Wrapper] Error during force kill: $_"
        }
    }
}

# Set up Ctrl+C handler for the wrapper itself
[Console]::TreatControlCAsInput = $false
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Write-Host "[Wrapper] PowerShell exiting event triggered."
    if (($null -ne $process) -and (!$process.HasExited)) {
        Send-GracefulShutdown $process
    }
}

try {
    Write-Host "[Wrapper] =================================================="
    Write-Host "[Wrapper] SCUM Server Graceful Shutdown Wrapper v1.0"
    Write-Host "[Wrapper] =================================================="
    Write-Host "[Wrapper] Executable: $ExePath"
    Write-Host "[Wrapper] Arguments: $ScriptArgs"
    Write-Host "[Wrapper] --------------------------------------------------"

    if (!(Test-Path $ExePath)) {
        Write-Host "[Wrapper] ERROR: Server executable not found at: $ExePath"
        exit 1
    }

    # Start SCUM Server
    # Use -NoNewWindow to keep it in the same console for signal sending
    Write-Host "[Wrapper] Starting SCUM Server..."
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = $ScriptArgs -join " "
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    
    $process = [System.Diagnostics.Process]::Start($psi)
    
    if ($null -eq $process) {
        Write-Host "[Wrapper] ERROR: Failed to start process."
        exit 1
    }

    Write-Host "[Wrapper] Server started successfully. PID: $($process.Id)"
    Write-Host "[Wrapper] Monitoring process... (Press Ctrl+C to shutdown gracefully)"
    Write-Host "[Wrapper] --------------------------------------------------"

    # Main wait loop
    while (!$process.HasExited) {
        Start-Sleep -Milliseconds 500
    }
    
    Write-Host "[Wrapper] Process exited naturally. Exit code: $($process.ExitCode)"

}
catch {
    Write-Host "[Wrapper] ERROR: $_"
    Write-Host "[Wrapper] Stack trace: $($_.ScriptStackTrace)"
    exit 1
    
}
finally {
    # This runs on Ctrl+C, script termination, or natural exit
    if (($null -ne $process) -and (!$process.HasExited) -and (!$isShuttingDown)) {
        Write-Host "[Wrapper] Finally block triggered - initiating shutdown..."
        Send-GracefulShutdown $process
    }
    
    if ($null -ne $process) {
        $process.Dispose()
    }
    
    Write-Host "[Wrapper] Wrapper script exiting."
}
