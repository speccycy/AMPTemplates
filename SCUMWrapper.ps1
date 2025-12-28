param(
    [Parameter(ValueFromRemainingArguments = $true)]
    $ScriptArgs
)

$ExePath = Join-Path $PSScriptRoot "SCUMServer.exe"
$p = $null

try {
    Write-Host "[Wrapper] Starting SCUM Server from: $ExePath"
    Write-Host "[Wrapper] Arguments: $ScriptArgs"

    # Start SCUM
    # Redirect output just to keep console clean, or let it flow if needed.
    # Since we use TailLogFile, we don't strictly need to see output, 
    # but having it is good for debugging. 
    # We will NOT redirect here to ensure maximum compatibility with the Console environment.
    $p = Start-Process -FilePath $ExePath -ArgumentList $ScriptArgs -PassThru -NoNewWindow
    
    if (!$p) {
        Write-Host "[Wrapper] Failed to start process."
        exit 1
    }

    Write-Host "[Wrapper] SCUM Server started. PID: $($p.Id)."
    Write-Host "[Wrapper] Waiting for process exit or Ctrl+C signal..."

    # Main Wait Loop (Blocking is fine here as we rely on Signal interruption)
    while (!$p.HasExited) {
        Start-Sleep -Milliseconds 500
    }
}
finally {
    # This block executes when:
    # 1. The loop finishes naturally (Game stopped / Crashed)
    # 2. The script is terminated by Ctrl+C (AMP Shutdown)
    
    Write-Host "[Wrapper] Finally block triggered."
    
    if ($p -and !$p.HasExited) {
        Write-Host "[Wrapper] Child process still running. Triggering Graceful Shutdown (CloseMainWindow)..."
        
        try {
            $p.CloseMainWindow() | Out-Null
        } catch {
            Write-Host "[Wrapper] Error triggering CloseMainWindow: $_"
        }
        
        # Give it time to save and exit
        $TimeoutSeconds = 60
        Write-Host "[Wrapper] Waiting up to $TimeoutSeconds seconds for exit..."
        
        # WaitForExit loop to avoid hanging indefinitely if it ignores us
        $DidExit = $p.WaitForExit($TimeoutSeconds * 1000)
        
        if (!$DidExit) {
            Write-Host "[Wrapper] Timed out. Force killing..."
            $p.Kill()
        } else {
            Write-Host "[Wrapper] Process exited gracefully."
        }
    } else {
        Write-Host "[Wrapper] Child process already exited."
    }
}
