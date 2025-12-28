param(
    [Parameter(ValueFromRemainingArguments = $true)]
    $ScriptArgs
)

# Shared shutdown logic
$script:ShuttingDown = $false
function Stop-ServerGracefully($proc) {
    if ($script:ShuttingDown) { return }
    $script:ShuttingDown = $true
    
    Write-Host "[Wrapper] Shutdown signal received. Sending CloseMainWindow..."
    try {
        $proc.CloseMainWindow() | Out-Null
    } catch {
        Write-Host "[Wrapper] Error closing main window: $_"
    }
    
    $proc.WaitForExit(60000)
    if (!$proc.HasExited) {
        Write-Host "[Wrapper] Timed out. Killing process..."
        $proc.Kill()
    } else {
        Write-Host "[Wrapper] Server shut down gracefully."
    }
}

# Trap Ctrl+C (SIGINT)
[Console]::TreatControlCAsInput = $false
[Console]::CancelKeyPress += { 
    $_.Cancel = $true # Prevent immediate script termination
    Write-Host "[Wrapper] Caught Ctrl+C."
    Stop-ServerGracefully $script:p 
}

$ExePath = Join-Path $PSScriptRoot "SCUMServer.exe"
Write-Host "[Wrapper] Starting SCUM Server from: $ExePath"
Write-Host "[Wrapper] Arguments: $ScriptArgs"

$StartInfo = New-Object System.Diagnostics.ProcessStartInfo
$StartInfo.FileName = $ExePath
$StartInfo.Arguments = "$ScriptArgs"
$StartInfo.UseShellExecute = $false
$StartInfo.RedirectStandardInput = $false
$StartInfo.RedirectStandardOutput = $true
$StartInfo.RedirectStandardError = $true
$StartInfo.CreateNoWindow = $false

$script:p = New-Object System.Diagnostics.Process
$script:p.StartInfo = $StartInfo

$Action = { if (![string]::IsNullOrEmpty($Event.SourceEventArgs.Data)) { [Console]::Out.WriteLine($Event.SourceEventArgs.Data) } }
$ErrorAction = { if (![string]::IsNullOrEmpty($Event.SourceEventArgs.Data)) { [Console]::Error.WriteLine($Event.SourceEventArgs.Data) } }

Register-ObjectEvent -InputObject $script:p -EventName OutputDataReceived -Action $Action | Out-Null
Register-ObjectEvent -InputObject $script:p -EventName ErrorDataReceived -Action $ErrorAction | Out-Null

if (!$script:p.Start()) { Write-Host "[Wrapper] Failed start."; exit 1 }

$script:p.BeginOutputReadLine()
$script:p.BeginErrorReadLine()
Write-Host "[Wrapper] SCUM Server started. PID: $($script:p.Id)."

# Main Loop - Read Async STDIN as fallback + Keep script alive
$Reader = [System.Console]::In
$InputTask = $Reader.ReadLineAsync()

while (!$script:p.HasExited -and !$script:ShuttingDown) {
    if ($InputTask.IsCompleted) {
        $Command = $InputTask.Result
        if ($Command -eq "stop") { Stop-ServerGracefully $script:p; break }
        $InputTask = $Reader.ReadLineAsync()
    }
    Start-Sleep -Milliseconds 250
}

if ($script:p.HasExited) {
    Write-Host "[Wrapper] Process exited code: $($script:p.ExitCode)"
    exit $script:p.ExitCode
}
