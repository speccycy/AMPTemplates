# Palworld AMP launcher with optional ForceBindIP support.
# The wrapper remains alive with the real server process so AMP can monitor it.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ForceBindIPEnabled = $false
$ForceBindIPDelayedInjection = $false
$ForceBindIPPath = "C:\Program Files (x86)\ForceBindIP\ForceBindIP64.exe"
$ForceBindIPBindAddress = ""
$ServerArguments = [System.Collections.Generic.List[string]]::new()
$serverArgumentMarkerFound = $false

for ($index = 0; $index -lt $args.Count; $index++) {
    $argument = [string]$args[$index]

    if ($serverArgumentMarkerFound) {
        [void]$ServerArguments.Add($argument)
        continue
    }

    switch ($argument.ToLowerInvariant()) {
        "-ampforcebindipenabled" {
            $ForceBindIPEnabled = $true
            continue
        }
        "-ampforcebindipdelayedinjection" {
            $ForceBindIPDelayedInjection = $true
            continue
        }
        "-ampforcebindippath" {
            if (++$index -ge $args.Count) {
                throw "-AMPForceBindIPPath requires a value."
            }
            $ForceBindIPPath = [string]$args[$index]
            continue
        }
        "-ampforcebindipbindaddress" {
            if (++$index -ge $args.Count) {
                throw "-AMPForceBindIPBindAddress requires a value."
            }
            $ForceBindIPBindAddress = [string]$args[$index]
            continue
        }
        "palworld" {
            $serverArgumentMarkerFound = $true
            continue
        }
        default {
            throw "Unexpected wrapper argument before the Palworld marker: $argument"
        }
    }
}

if (-not $serverArgumentMarkerFound) {
    throw "The Palworld server argument marker was not supplied."
}

$instanceRoot = Split-Path -Path $PSScriptRoot -Parent
$serverExecutable = Join-Path $instanceRoot "palworld\2394010\Pal\Binaries\Win64\PalServer-Win64-Shipping-Cmd.exe"
$serverExecutable = [System.IO.Path]::GetFullPath($serverExecutable)
$serverWorkingDirectory = Split-Path -Path $serverExecutable -Parent

if (-not (Test-Path -LiteralPath $serverExecutable -PathType Leaf)) {
    throw "Palworld server executable not found: $serverExecutable"
}

function Start-NativeProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [string[]]$ArgumentList = @()
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false

    foreach ($nativeArgument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add([string]$nativeArgument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        throw "Failed to start: $FilePath"
    }

    return $process
}

function Get-PalworldProcessIds {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath
    )

    $matchingIds = [System.Collections.Generic.List[int]]::new()
    $processes = Get-CimInstance Win32_Process -Filter "Name='PalServer-Win64-Shipping-Cmd.exe'" -ErrorAction SilentlyContinue

    foreach ($candidate in $processes) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate.ExecutablePath)) {
            continue
        }

        if ([string]::Equals(
            [System.IO.Path]::GetFullPath([string]$candidate.ExecutablePath),
            $ExecutablePath,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            [void]$matchingIds.Add([int]$candidate.ProcessId)
        }
    }

    return $matchingIds.ToArray()
}

function Wait-ForForceBindIPServer {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [int[]]$ExistingProcessIds,

        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$LauncherProcess,

        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        foreach ($processId in (Get-PalworldProcessIds -ExecutablePath $ExecutablePath)) {
            if ($processId -notin $ExistingProcessIds) {
                return Get-Process -Id $processId -ErrorAction Stop
            }
        }

        if ($LauncherProcess.HasExited -and $LauncherProcess.ExitCode -ne 0) {
            throw "ForceBindIP64.exe exited with code $($LauncherProcess.ExitCode) before Palworld started."
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Timed out waiting $TimeoutSeconds seconds for ForceBindIP to start Palworld."
}

try {
    if (-not $ForceBindIPEnabled) {
        Write-Host "[PALWORLD-WRAPPER] Starting Palworld directly (ForceBindIP disabled)."
        $serverProcess = Start-NativeProcess -FilePath $serverExecutable -WorkingDirectory $serverWorkingDirectory -ArgumentList $ServerArguments.ToArray()
    }
    else {
        if ([string]::IsNullOrWhiteSpace($ForceBindIPBindAddress)) {
            throw "ForceBindIP is enabled, but no bind address or interface GUID was configured."
        }

        $ForceBindIPPath = [System.IO.Path]::GetFullPath($ForceBindIPPath)
        if (-not (Test-Path -LiteralPath $ForceBindIPPath -PathType Leaf)) {
            throw "ForceBindIP executable not found: $ForceBindIPPath"
        }

        if ([System.IO.Path]::GetFileName($ForceBindIPPath) -ine "ForceBindIP64.exe") {
            throw "Palworld is 64-bit. Configure the path to ForceBindIP64.exe."
        }

        $bindIpDll = Join-Path (Split-Path -Path $ForceBindIPPath -Parent) "BindIP.dll"
        if (-not (Test-Path -LiteralPath $bindIpDll -PathType Leaf)) {
            throw "BindIP.dll was not found beside ForceBindIP64.exe: $bindIpDll"
        }

        $existingProcessIds = @(Get-PalworldProcessIds -ExecutablePath $serverExecutable)
        $forceBindArguments = [System.Collections.Generic.List[string]]::new()

        if ($ForceBindIPDelayedInjection) {
            [void]$forceBindArguments.Add("-i")
        }

        [void]$forceBindArguments.Add($ForceBindIPBindAddress)
        [void]$forceBindArguments.Add($serverExecutable)
        foreach ($serverArgument in $ServerArguments) {
            [void]$forceBindArguments.Add($serverArgument)
        }

        Write-Host "[PALWORLD-WRAPPER] Starting Palworld through ForceBindIP64.exe."
        Write-Host "[PALWORLD-WRAPPER] Bind target: $ForceBindIPBindAddress"
        Write-Host "[PALWORLD-WRAPPER] Delayed injection: $ForceBindIPDelayedInjection"

        $launcherProcess = Start-NativeProcess -FilePath $ForceBindIPPath -WorkingDirectory $serverWorkingDirectory -ArgumentList $forceBindArguments.ToArray()
        $serverProcess = Wait-ForForceBindIPServer -ExecutablePath $serverExecutable -ExistingProcessIds $existingProcessIds -LauncherProcess $launcherProcess

        Write-Host "[PALWORLD-WRAPPER] Palworld process detected (PID $($serverProcess.Id))."
    }

    $serverProcess.WaitForExit()
    exit $serverProcess.ExitCode
}
catch {
    Write-Error "[PALWORLD-WRAPPER] $($_.Exception.Message)"
    exit 1
}
