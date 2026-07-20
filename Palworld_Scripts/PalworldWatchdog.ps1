param(
    [Parameter(Mandatory)]
    [int]$WrapperPID,

    [Parameter(Mandatory)]
    [string]$ServerExePath,

    [int]$GracefulShutdownTimeoutSeconds = 30,
    [int]$ServerDiscoveryTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$logDirectory = Join-Path $PSScriptRoot "Logs"
[void](New-Item -ItemType Directory -Path $logDirectory -Force)
$logFile = Join-Path $logDirectory "PalworldWatchdog_$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-WatchdogLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -LiteralPath $logFile -Value "[$timestamp] $Message" -ErrorAction SilentlyContinue
}

function Get-PalworldProcessByExecutable {
    param([string]$ExpectedExePath)

    $resolvedExpectedPath = try {
        (Resolve-Path -LiteralPath $ExpectedExePath -ErrorAction Stop).ProviderPath
    }
    catch {
        $ExpectedExePath
    }

    try {
        $candidates = Get-CimInstance Win32_Process -Filter "Name = 'PalServer-Win64-Shipping-Cmd.exe'" -ErrorAction Stop
        foreach ($candidate in $candidates) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate.ExecutablePath)) {
                continue
            }

            if ([string]::Equals(
                [string]$candidate.ExecutablePath,
                $resolvedExpectedPath,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                return Get-Process -Id ([int]$candidate.ProcessId) -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        $candidates = Get-Process -Name "PalServer-Win64-Shipping-Cmd" -ErrorAction SilentlyContinue
        foreach ($candidate in $candidates) {
            try {
                if ([string]::Equals(
                    [string]$candidate.Path,
                    $resolvedExpectedPath,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                    return $candidate
                }
            }
            catch {
                # Process properties can be inaccessible under restricted accounts.
            }
        }
    }

    return $null
}

function Wait-PalworldProcessByExecutable {
    param(
        [string]$ExpectedExePath,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $process = Get-PalworldProcessByExecutable -ExpectedExePath $ExpectedExePath
        if ($process) {
            return $process
        }

        Start-Sleep -Milliseconds 250
    }

    return $null
}

function Send-PalworldCtrlC {
    param([int]$ProcessId)

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
        if (-not ("Kernel32.PalworldWatchdogWinAPI" -as [type])) {
            Add-Type -MemberDefinition $signature -Name "PalworldWatchdogWinAPI" -Namespace "Kernel32" -ErrorAction Stop | Out-Null
        }

        [Kernel32.PalworldWatchdogWinAPI]::FreeConsole() | Out-Null
        if (-not [Kernel32.PalworldWatchdogWinAPI]::AttachConsole([uint32]$ProcessId)) {
            return $false
        }

        [Kernel32.PalworldWatchdogWinAPI]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
        $sent = [Kernel32.PalworldWatchdogWinAPI]::GenerateConsoleCtrlEvent(0, 0)
        Start-Sleep -Milliseconds 100
        [Kernel32.PalworldWatchdogWinAPI]::FreeConsole() | Out-Null
        [Kernel32.PalworldWatchdogWinAPI]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) | Out-Null
        return $sent
    }
    catch {
        Write-WatchdogLog "Ctrl+C failed: $($_.Exception.Message)"
        return $false
    }
}

Write-WatchdogLog "Watchdog started. Wrapper PID: $WrapperPID; server path: $ServerExePath"

try {
    $wrapper = Get-Process -Id $WrapperPID -ErrorAction Stop
}
catch {
    Write-WatchdogLog "Wrapper was not running at watchdog startup; exiting."
    exit 1
}

$server = $null

while ($true) {
    Start-Sleep -Milliseconds 250

    $wrapper = Get-Process -Id $WrapperPID -ErrorAction SilentlyContinue
    if (-not $wrapper) {
        Write-WatchdogLog "Wrapper exited; beginning orphan cleanup."
        break
    }

    if (-not $server) {
        $server = Get-PalworldProcessByExecutable -ExpectedExePath $ServerExePath
        if ($server) {
            Write-WatchdogLog "Discovered Palworld PID $($server.Id)."
        }
        continue
    }

    $server.Refresh()
    if ($server.HasExited) {
        Write-WatchdogLog "Palworld exited while wrapper was alive; watchdog exiting."
        exit 0
    }
}

Start-Sleep -Milliseconds 500

if (-not $server -or $server.HasExited) {
    $server = Wait-PalworldProcessByExecutable -ExpectedExePath $ServerExePath -TimeoutSeconds $ServerDiscoveryTimeoutSeconds
}

if (-not $server) {
    Write-WatchdogLog "No Palworld process found for this instance path."
    exit 0
}

$server.Refresh()
if ($server.HasExited) {
    Write-WatchdogLog "Palworld had already exited."
    exit 0
}

Write-WatchdogLog "Orphan Palworld PID $($server.Id) detected. Attempting Ctrl+C."
$ctrlCSent = Send-PalworldCtrlC -ProcessId $server.Id

if ($ctrlCSent) {
    $deadline = (Get-Date).AddSeconds($GracefulShutdownTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $server.Refresh()
        if ($server.HasExited) {
            Write-WatchdogLog "Palworld exited cleanly after Ctrl+C."
            exit 0
        }

        Start-Sleep -Milliseconds 500
    }
}

$server.Refresh()
if (-not $server.HasExited) {
    Write-WatchdogLog "Palworld did not stop gracefully; force killing PID $($server.Id)."
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
}

exit 0
