param(
    [Parameter(ValueFromRemainingArguments = $true)]
    $ScriptArgs
)

# SCUM Server Graceful Shutdown Wrapper v2.0
# Handles AMP's OS_CLOSE signal and forwards graceful shutdown to SCUM

Write-Host "[Wrapper] =================================================="
Write-Host "[Wrapper] SCUM Server Graceful Shutdown Wrapper v2.0"
Write-Host "[Wrapper] =================================================="

$ExePath = Join-Path $PSScriptRoot "SCUMServer.exe"
$process = $null

# Add Windows API for sending Ctrl+C
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
}
catch {
    $apiLoaded = $false
}

function Send-CtrlC {
    param([System.Diagnostics.Process]$TargetProcess)
    
    if (!$TargetProcess -or $TargetProcess.HasExited) {
        return $false
    }
    
    Write-Host "[Wrapper] Sending Ctrl+C to PID $($TargetProcess.Id)..."
    
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
                    Write-Host "[Wrapper] Ctrl+C sent via API"
                    return $true
                }
            }
        }
        catch {
            Write-Host "[Wrapper] API method failed: $_"
        }
    }
    
    # Method 2: CloseMainWindow fallback
    Write-Host "[Wrapper] Trying CloseMainWindow..."
    try {
        return $TargetProcess.CloseMainWindow()
    }
    catch {
        return $false
    }
}

if (!(Test-Path $ExePath)) {
    Write-Host "[Wrapper] ERROR: Server executable not found: $ExePath"
    exit 1
}

$argString = $ScriptArgs -join " "
Write-Host "[Wrapper] Executable: $ExePath"
Write-Host "[Wrapper] Arguments: $argString"
Write-Host "[Wrapper] --------------------------------------------------"

try {
    Write-Host "[Wrapper] Starting SCUM Server..."
    
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    
    $process = [System.Diagnostics.Process]::Start($psi)
    
    if ($null -eq $process) {
        Write-Host "[Wrapper] ERROR: Failed to start process"
        exit 1
    }

    Write-Host "[Wrapper] Server started. PID: $($process.Id)"
    Write-Host "[Wrapper] Monitoring process..."
    Write-Host "[Wrapper] --------------------------------------------------"
    
    # Wait for process to exit
    while (!$process.HasExited) {
        Start-Sleep -Milliseconds 500
    }
    
    Write-Host "[Wrapper] Process exited. Code: $($process.ExitCode)"
    exit $process.ExitCode

}
catch {
    Write-Host "[Wrapper] ERROR: $_"
    exit 1
    
}
finally {
    # This block runs when PowerShell wrapper is terminated by AMP (OS_CLOSE)
    if ($null -ne $process -and !$process.HasExited) {
        Write-Host "[Wrapper] Wrapper terminating - sending shutdown signal to SCUM..."
        
        if (Send-CtrlC $process) {
            Write-Host "[Wrapper] Signal sent. Waiting up to 60s for graceful exit..."
            
            $waited = 0
            while (!$process.HasExited -and $waited -lt 60) {
                Start-Sleep -Seconds 2
                $waited += 2
                if ($waited % 10 -eq 0) {
                    Write-Host "[Wrapper] Still waiting... ($waited/60s)"
                }
            }
            
            if ($process.HasExited) {
                Write-Host "[Wrapper] Server shutdown gracefully after $waited seconds"
            }
            else {
                Write-Host "[Wrapper] Timeout! Force killing..."
                try { $process.Kill() } catch {}
            }
        }
        else {
            Write-Host "[Wrapper] Failed to send signal, force killing..."
            try { $process.Kill() } catch {}
        }
        
        try { $process.Dispose() } catch {}
    }
    
    Write-Host "[Wrapper] Wrapper exiting"
    Write-Host "[Wrapper] =================================================="
}
