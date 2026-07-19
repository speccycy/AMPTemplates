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

function Convert-CimDateTime {
    param($Value)

    if ($Value -is [datetime]) {
        return $Value
    }

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return [datetime]::MinValue
    }

    try {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Value)
    }
    catch {
        try {
            return [datetime]$Value
        }
        catch {
            return [datetime]::MinValue
        }
    }
}

function Get-PalworldServerProcessesByExecutable {
    param([string]$ExpectedExePath)

    $resolvedExpectedPath = try {
        (Resolve-Path -LiteralPath $ExpectedExePath -ErrorAction Stop).ProviderPath
    }
    catch {
        $ExpectedExePath
    }

    $matchedProcesses = @()

    try {
        $candidates = Get-CimInstance Win32_Process -Filter "Name = 'PalServer-Win64-Shipping-Cmd.exe'" -ErrorAction Stop
        foreach ($candidate in $candidates) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate.ExecutablePath)) {
                continue
            }

            if (![string]::Equals(
                [string]$candidate.ExecutablePath,
                $resolvedExpectedPath,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                continue
            }

            $matchedProcesses += [pscustomobject]@{
                Id           = [int]$candidate.ProcessId
                CreationDate = Convert-CimDateTime $candidate.CreationDate
            }
        }
    }
    catch {
        Write-Warning "[PALWORLD-WRAPPER] CIM process lookup failed: $_"
        $fallbackCandidates = Get-Process -Name "PalServer-Win64-Shipping-Cmd" -ErrorAction SilentlyContinue

        foreach ($candidate in $fallbackCandidates) {
            try {
                if (![string]::Equals(
                    [string]$candidate.Path,
                    $resolvedExpectedPath,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                    continue
                }

                $matchedProcesses += [pscustomobject]@{
                    Id           = [int]$candidate.Id
                    CreationDate = $candidate.StartTime
                }
            }
            catch {
                # Some process properties may be unavailable to restricted users.
            }
        }
    }

    return $matchedProcesses | Sort-Object CreationDate -Descending
}

function Wait-ForForceBindIPServer {
    param(
        [string]$ExpectedExePath,
        [int[]]$ExcludedPids,
        [datetime]$LaunchTime,
        [System.Diagnostics.Process]$LauncherProcess,
        [int]$TimeoutSeconds = 30
    )

    # @() deliberately accepts the normal case where no Palworld process
    # existed before launch. This mirrors the working SCUM wrapper.
    $excluded = @($ExcludedPids)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $reportedLauncherExit = $false

    while ((Get-Date) -lt $deadline) {
        $candidates = Get-PalworldServerProcessesByExecutable -ExpectedExePath $ExpectedExePath

        foreach ($candidate in @($candidates)) {
            if ($excluded -contains [int]$candidate.Id) {
                continue
            }

            if (
                $candidate.CreationDate -ne [datetime]::MinValue -and
                $candidate.CreationDate -lt $LaunchTime.AddSeconds(-5)
            ) {
                continue
            }

            $serverProcess = Get-Process -Id $candidate.Id -ErrorAction SilentlyContinue
            if ($serverProcess) {
                return $serverProcess
            }
        }

        if ($LauncherProcess) {
            $LauncherProcess.Refresh()
            if ($LauncherProcess.HasExited -and !$reportedLauncherExit) {
                $reportedLauncherExit = $true
                Write-Host "[PALWORLD-WRAPPER] ForceBindIP loader exited with code $($LauncherProcess.ExitCode)."

                if ($LauncherProcess.ExitCode -ne 0) {
                    throw "ForceBindIP64.exe exited with code $($LauncherProcess.ExitCode) before Palworld started."
                }
            }
        }

        Start-Sleep -Milliseconds 250
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

        $existingProcessIds = @(
            (Get-PalworldServerProcessesByExecutable -ExpectedExePath $serverExecutable) |
                ForEach-Object { [int]$_.Id }
        )
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

        $launchTime = Get-Date
        $launcherProcess = Start-NativeProcess -FilePath $ForceBindIPPath -WorkingDirectory $serverWorkingDirectory -ArgumentList $forceBindArguments.ToArray()
        $serverProcess = Wait-ForForceBindIPServer -ExpectedExePath $serverExecutable -ExcludedPids $existingProcessIds -LaunchTime $launchTime -LauncherProcess $launcherProcess

        Write-Host "[PALWORLD-WRAPPER] Palworld process detected (PID $($serverProcess.Id))."
    }

    $serverProcess.WaitForExit()
    exit $serverProcess.ExitCode
}
catch {
    Write-Error "[PALWORLD-WRAPPER] $($_.Exception.Message)"
    exit 1
}
