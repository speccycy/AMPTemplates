# ============================================================================
# DockerWrapper.ps1 - Windows EXE Runner with Docker Container Isolation
# ============================================================================
#
# This wrapper manages the lifecycle of customer Windows executables inside
# Docker Windows containers within the CubeCoders AMP environment. It ensures
# container isolation (filesystem, network, CPU/RAM) for untrusted executables
# while maintaining AMP's standard Start/Stop/Restart/Abort interface.
#
# Key Features:
# - Docker Windows container with process isolation (no Hyper-V overhead)
# - CPU, memory, and network resource limits via Docker flags
# - External watchdog for orphan container prevention
# - Singleton container enforcement via PID file
# - Real-time console output streaming via docker logs
# - ANSI escape code stripping for clean AMP console display
# - Comprehensive dual logging (console + file) with 7-day retention
#
# Architecture:
#   AMP → DockerWrapper.ps1 → docker create/start → Container (Customer EXE)
#                            → DockerWatchdog.ps1 (monitors wrapper PID)
#
# Version: 1.0
# Requires: PowerShell 7.0+, Docker Engine with Windows container support
# ============================================================================

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    $ScriptArgs
)

# Force UTF-8 output for AMP console compatibility
$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================================================
# CONFIGURATION CONSTANTS
# ============================================================================

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

Set-Variable -Name LOG_RETENTION_DAYS -Value 7 -Option Constant
Set-Variable -Name MONITOR_POLL_INTERVAL_MS -Value 500 -Option Constant
Set-Variable -Name HEARTBEAT_INTERVAL_SECONDS -Value 30 -Option Constant
Set-Variable -Name DOCKER_STOP_TIMEOUT -Value 30 -Option Constant

# ============================================================================
# LOGGING INFRASTRUCTURE
# ============================================================================

$logDir = Join-Path $PSScriptRoot "Logs"
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$logFile = Join-Path $logDir "DockerWrapper_$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-WrapperLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

    # Console output with level prefix for AMP display
    $consolePrefix = switch ($Level) {
        "ERROR"   { "[WRAPPER-ERROR]" }
        "WARNING" { "[WRAPPER-WARNING]" }
        "DEBUG"   { "[WRAPPER-DEBUG]" }
        default   { "[WRAPPER-INFO]" }
    }
    Write-Host "$consolePrefix $Message"

    # File output with timestamp
    try {
        "[$timestamp] [$Level] $Message" | Out-File -FilePath $logFile -Append -Encoding UTF8
    } catch {}
}

function Remove-OldLogs {
    param(
        [string]$LogDirectory = $logDir,
        [string]$Filter = "DockerWrapper_*.log",
        [int]$RetentionDays = $LOG_RETENTION_DAYS
    )
    $cutoffDate = (Get-Date).AddDays(-$RetentionDays)
    try {
        Get-ChildItem -Path $LogDirectory -Filter $Filter -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoffDate } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
}

# Run log cleanup at startup
Remove-OldLogs

# ============================================================================
# LOAD CONFIGURATION FROM ENVIRONMENT VARIABLES
# ============================================================================

Write-WrapperLog "=========================================="
Write-WrapperLog "Docker Wrapper Starting"
Write-WrapperLog "=========================================="
Write-WrapperLog "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-WrapperLog "Wrapper PID: $PID"

$dockerImage     = $env:DOCKER_IMAGE
$executablePath  = $env:EXECUTABLE_PATH
$commandLineArgs = $env:COMMAND_LINE_ARGS
$cpuLimit        = $env:CPU_LIMIT
$memoryLimit     = $env:MEMORY_LIMIT
$networkMode     = $env:NETWORK_MODE
$networkAdapter  = $env:NETWORK_ADAPTER
$containerIP     = $env:CONTAINER_IP
$networkSubnet   = $env:NETWORK_SUBNET
$networkGateway  = $env:NETWORK_GATEWAY
$extraMounts     = $env:EXTRA_MOUNTS
$readyPattern    = $env:READY_PATTERN
$updateSSLCerts  = $env:UPDATE_SSL_CERTS

Write-WrapperLog "Configuration:"
Write-WrapperLog "  Docker Image:    $dockerImage"
Write-WrapperLog "  Executable:      $executablePath"
Write-WrapperLog "  Command Args:    $commandLineArgs"
Write-WrapperLog "  CPU Limit:       $cpuLimit"
Write-WrapperLog "  Memory Limit:    $memoryLimit"
Write-WrapperLog "  Network Mode:    $networkMode"
Write-WrapperLog "  Network Adapter: $networkAdapter"
Write-WrapperLog "  Container IP:    $containerIP"
Write-WrapperLog "  Network Subnet:  $networkSubnet"
Write-WrapperLog "  Network Gateway: $networkGateway"
Write-WrapperLog "  Extra Mounts:    $extraMounts"
Write-WrapperLog "  Ready Pattern:   $readyPattern"
Write-WrapperLog "  Update SSL Certs: $updateSSLCerts"
Write-WrapperLog "  Running as:      $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-WrapperLog "  Working Dir:     $(Get-Location)"

# Validate required settings
if ([string]::IsNullOrWhiteSpace($executablePath)) {
    Write-WrapperLog "ERROR: ExecutablePath is not configured. Set it in AMP instance settings." "ERROR"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($dockerImage)) {
    $dockerImage = "mcr.microsoft.com/windows/servercore:ltsc2025"
    Write-WrapperLog "Using default Docker image: $dockerImage" "DEBUG"
}

if ([string]::IsNullOrWhiteSpace($cpuLimit))    { $cpuLimit = "1.0" }
if ([string]::IsNullOrWhiteSpace($memoryLimit)) { $memoryLimit = "512m" }
if ([string]::IsNullOrWhiteSpace($networkMode)) { $networkMode = "nat" }

# ============================================================================
# DOCKER ENGINE VERIFICATION
# ============================================================================

Write-WrapperLog "=========================================="
Write-WrapperLog "Verifying Docker Engine"
Write-WrapperLog "=========================================="

try {
    $dockerInfo = & docker info 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Try TCP fallback if named pipe access is denied
        Write-WrapperLog "Named pipe access failed, trying TCP fallback (127.0.0.1:2375)..." "WARNING"
        $env:DOCKER_HOST = "tcp://127.0.0.1:2375"
        $dockerInfo = & docker info 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-WrapperLog "ERROR: Docker Engine is not accessible via named pipe or TCP." "ERROR"
            Write-WrapperLog "Fix: Run as Admin: net localgroup docker-users /add && net localgroup docker-users `"NT AUTHORITY\NETWORK SERVICE`" /add" "ERROR"
            Write-WrapperLog "Or add to daemon.json: `"hosts`": [`"npipe://`", `"tcp://127.0.0.1:2375`"]" "ERROR"
            Write-WrapperLog "Docker info output: $($dockerInfo -join ' ')" "ERROR"
            exit 1
        }
        Write-WrapperLog "Docker Engine accessible via TCP fallback" "WARNING"
    }
    Write-WrapperLog "Docker Engine verified successfully"
    Write-WrapperLog "Docker info: $($dockerInfo | Select-String 'Server Version' | ForEach-Object { $_.ToString().Trim() })" "DEBUG"
} catch {
    Write-WrapperLog "ERROR: Failed to run 'docker info': $_" "ERROR"
    Write-WrapperLog "Ensure Docker Engine is installed and the 'docker' command is in PATH." "ERROR"
    exit 1
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Get-ContainerName {
    <#
    .SYNOPSIS
        Generates a unique Docker container name from the AMP instance working directory.
    .DESCRIPTION
        Derives an instance ID from the current working directory name and produces
        a container name in the format amp-docker-{instanceId}. The instance ID is
        sanitized to only contain valid Docker container name characters.
    .OUTPUTS
        String - Container name matching [a-zA-Z0-9][a-zA-Z0-9_.-]+
    #>
    # Working dir is typically: ...\InstanceName\windows-exe-docker\app
    # We need the instance name, which is 3 levels up from the working directory
    $workingDir = (Get-Location).Path
    $instanceId = $workingDir | Split-Path -Parent | Split-Path -Parent | Split-Path -Leaf
    # Sanitize: keep only alphanumeric, underscore, dot, hyphen
    $sanitized = $instanceId -replace '[^a-zA-Z0-9_.-]', ''
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        $sanitized = "default"
    }
    return "amp-docker-$sanitized"
}

function Parse-VolumeMounts {
    <#
    .SYNOPSIS
        Parses semicolon-separated volume mount specifications.
    .DESCRIPTION
        Each entry follows the format host_path:container_path:mode where mode
        is 'ro' (read-only) or 'rw' (read-write). Mode defaults to 'rw' if omitted.
    .PARAMETER MountString
        Semicolon-separated mount specs, e.g. "C:\data:C:\app\data:ro;C:\logs:C:\app\logs:rw"
    .OUTPUTS
        Array of objects with HostPath, ContainerPath, Mode properties
    #>
    param([string]$MountString)

    $mounts = @()
    if ([string]::IsNullOrWhiteSpace($MountString)) {
        return $mounts
    }

    $entries = $MountString.Split(@(';', "`n", "`r"), [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($entry in $entries) {
        $entry = $entry.Trim()
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }

        $parts = $entry.Split(':')
        # Windows paths contain drive letter colon, so we need to handle:
        # C:\host:C:\container:mode → parts = C, \host, C, \container, mode
        # We reassemble drive-letter paths
        if ($parts.Count -ge 4) {
            # Likely two Windows paths: drive1:\path1:drive2:\path2[:mode]
            $hostPath = "$($parts[0]):$($parts[1])"
            $containerPath = "$($parts[2]):$($parts[3])"
            $mode = if ($parts.Count -ge 5) { $parts[4].Trim().ToLower() } else { "rw" }
        } elseif ($parts.Count -eq 3) {
            # Unix-style or simple: path1:path2:mode
            $hostPath = $parts[0]
            $containerPath = $parts[1]
            $mode = $parts[2].Trim().ToLower()
        } elseif ($parts.Count -eq 2) {
            # path1:path2 (default rw)
            $hostPath = $parts[0]
            $containerPath = $parts[1]
            $mode = "rw"
        } else {
            Write-WrapperLog "WARNING: Invalid volume mount format: '$entry' (skipping)" "WARNING"
            continue
        }

        if ($mode -notin @("ro", "rw")) {
            Write-WrapperLog "WARNING: Invalid mount mode '$mode' in '$entry', defaulting to 'rw'" "WARNING"
            $mode = "rw"
        }

        $mounts += [PSCustomObject]@{
            HostPath      = $hostPath
            ContainerPath = $containerPath
            Mode          = $mode
        }
    }

    return $mounts
}

function Build-DockerCreateCommand {
    <#
    .SYNOPSIS
        Constructs docker create arguments from configuration.
    .DESCRIPTION
        Builds the full argument list for 'docker create' including resource limits,
        isolation mode, volume mounts, network mode, and the command to run inside
        the container. Never includes --privileged.
        When using transparent network mode, the network name is passed instead of
        'transparent' directly, and an optional static IP can be assigned.
        When UpdateSSLCerts is enabled, the container entrypoint is wrapped with
        a cmd /c command that runs certutil to update root CA certificates before
        launching the application. This fixes SSL certificate verification errors
        (e.g., discord.com, api endpoints) in Windows Server Core containers.
    .PARAMETER ContainerName
        Name for the Docker container
    .PARAMETER Image
        Docker image to use
    .PARAMETER CpuLimit
        CPU limit (--cpus value)
    .PARAMETER MemoryLimit
        Memory limit (--memory value)
    .PARAMETER NetworkName
        Docker network name to connect to (nat, none, or a custom transparent network name)
    .PARAMETER ContainerIP
        Optional static IP address for the container (transparent mode only)
    .PARAMETER ExeHostDir
        Host directory containing the customer executable (mounted into container)
    .PARAMETER ExePath
        Path to the executable inside the container
    .PARAMETER ExeArgs
        Command line arguments for the executable
    .PARAMETER ExtraMountString
        Additional volume mounts (semicolon-separated)
    .PARAMETER UpdateSSLCerts
        When "true", injects certutil root CA update before running the application
    .OUTPUTS
        Array of strings - arguments for docker create
    #>
    param(
        [string]$ContainerName,
        [string]$Image,
        [string]$CpuLimit,
        [string]$MemoryLimit,
        [string]$NetworkName,
        [string]$ContainerIP,
        [string]$ExeHostDir,
        [string]$ExePath,
        [string]$ExeArgs,
        [string]$ExtraMountString,
        [string]$UpdateSSLCerts = "false"
    )

    $args = @(
        "create"
        "--name", $ContainerName
        "--isolation=process"
        "--cpus", $CpuLimit
        "--memory", $MemoryLimit
        "--network", $NetworkName
        "--workdir", "C:\app"
    )

    # Add static IP if provided (transparent mode)
    if (![string]::IsNullOrWhiteSpace($ContainerIP)) {
        $args += "--ip", $ContainerIP
    }

    # Mount the executable directory into the container
    $args += "-v", "${ExeHostDir}:C:\app:rw"

    # Parse and add extra volume mounts
    $extraMountsList = Parse-VolumeMounts -MountString $ExtraMountString
    foreach ($mount in $extraMountsList) {
        $args += "-v", "$($mount.HostPath):$($mount.ContainerPath):$($mount.Mode)"
    }

    # Set the image
    $args += $Image

    # Container entrypoint: the customer executable
    # Clean up relative path prefixes (./ or .\)
    $cleanExePath = $ExePath -replace '^\.[\\/]', ''
    $containerExePath = "C:\app\$cleanExePath"

    $sslEnabled = ($UpdateSSLCerts -eq "true" -or $UpdateSSLCerts -eq "True" -or $UpdateSSLCerts -eq "1")

    if ($sslEnabled) {
        # Wrap with cmd /c to run certutil CA update before the application.
        # certutil -generateSSTFromWU downloads root certs from Windows Update,
        # then certutil -addstore imports them into the Trusted Root store.
        # This runs once at container start and adds ~3-5 seconds to startup.
        $certCmd = "certutil -generateSSTFromWU C:\roots.sst >nul 2>&1 & " +
                   "certutil -addstore -f Root C:\roots.sst >nul 2>&1 & " +
                   "del C:\roots.sst >nul 2>&1"

        $exeCmd = "$containerExePath"
        if (![string]::IsNullOrWhiteSpace($ExeArgs)) {
            $exeCmd += " $ExeArgs"
        }

        $args += "cmd", "/c", "$certCmd & $exeCmd"
    } else {
        $args += $containerExePath

        if (![string]::IsNullOrWhiteSpace($ExeArgs)) {
            # Split args and add individually
            $ExeArgs.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
                $args += $_
            }
        }
    }

    return $args
}

# ============================================================================
# TRANSPARENT NETWORK MANAGEMENT
# ============================================================================

<#
.SYNOPSIS
    Generates a deterministic Docker network name for transparent mode.
.DESCRIPTION
    Creates a network name based on the adapter name to allow reuse across
    container restarts. Multiple containers can share the same transparent
    network if they use the same adapter.
.PARAMETER AdapterName
    The Windows network adapter name (e.g., "Ethernet 2")
.OUTPUTS
    String - Docker network name like "amp-transparent-ethernet-2"
#>
function Get-TransparentNetworkName {
    param([string]$AdapterName)
    $sanitized = $AdapterName.ToLower() -replace '[^a-z0-9]', '-' -replace '-+', '-' -replace '^-|-$', ''
    return "amp-transparent-$sanitized"
}

<#
.SYNOPSIS
    Ensures a Docker transparent network exists for the specified adapter.
.DESCRIPTION
    Checks if a transparent network already exists for the given adapter.
    If not, creates one with the specified subnet/gateway (for static IP)
    or without (for DHCP). Returns the network name to use in docker create.

    When a static IP is requested, subnet and gateway are required so Docker
    knows which IP range is valid. Without them, Docker cannot assign the IP.

    When no static IP is needed, the network is created without subnet/gateway
    and the container obtains an IP via DHCP from the physical network.
.PARAMETER AdapterName
    Windows network adapter name to bind to
.PARAMETER Subnet
    Optional CIDR subnet (e.g., "192.168.1.0/24"). Required if ContainerIP is set.
.PARAMETER Gateway
    Optional gateway IP. Required if ContainerIP is set.
.OUTPUTS
    String - The Docker network name, or $null on failure
#>
function Ensure-TransparentNetwork {
    param(
        [string]$AdapterName,
        [string]$Subnet,
        [string]$Gateway
    )

    $netName = Get-TransparentNetworkName -AdapterName $AdapterName

    # Check if network already exists
    $existingDriver = & docker network inspect --format '{{.Driver}}' $netName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-WrapperLog "Transparent network '$netName' already exists (driver: $($existingDriver.Trim()))" "DEBUG"
        return $netName
    }

    # Validate adapter exists on the host
    Write-WrapperLog "Verifying network adapter '$AdapterName' exists..." "DEBUG"
    try {
        $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
        Write-WrapperLog "Adapter found: $($adapter.Name) (Status: $($adapter.Status), MAC: $($adapter.MacAddress))" "DEBUG"

        if ($adapter.Status -ne "Up") {
            Write-WrapperLog "WARNING: Adapter '$AdapterName' is not in 'Up' state (current: $($adapter.Status))" "WARNING"
        }
    } catch {
        Write-WrapperLog "ERROR: Network adapter '$AdapterName' not found on this host." "ERROR"
        Write-WrapperLog "Available adapters:" "ERROR"
        try {
            Get-NetAdapter | ForEach-Object {
                Write-WrapperLog "  - $($_.Name) (Status: $($_.Status), MAC: $($_.MacAddress))" "ERROR"
            }
        } catch {}
        return $null
    }

    # Build docker network create command
    $netArgs = @(
        "network", "create"
        "-d", "transparent"
        "-o", "com.docker.network.windowsshim.interface=$AdapterName"
    )

    # Add subnet and gateway if provided (required for static IP assignment)
    if (![string]::IsNullOrWhiteSpace($Subnet)) {
        $netArgs += "--subnet", $Subnet
    }
    if (![string]::IsNullOrWhiteSpace($Gateway)) {
        $netArgs += "--gateway", $Gateway
    }

    $netArgs += $netName

    Write-WrapperLog "Creating transparent network: docker $($netArgs -join ' ')" "DEBUG"

    $createOutput = & docker @netArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-WrapperLog "ERROR: Failed to create transparent network '$netName'" "ERROR"
        Write-WrapperLog "Docker output: $($createOutput -join ' ')" "ERROR"
        return $null
    }

    Write-WrapperLog "Transparent network '$netName' created successfully (adapter: $AdapterName)"
    return $netName
}

<#
.SYNOPSIS
    Ensures a Docker NAT network exists that is bound to a specific adapter.
.DESCRIPTION
    Creates a custom NAT network with an internal subnet (172.30.x.0/24) that
    routes outbound traffic through the specified physical adapter. All containers
    on this network share the adapter's public IP via NAT masquerading.

    This solves the multi-NIC problem: when the default route points to NIC 1
    but you want containers to use NIC 2 for outbound traffic.

    The network is reusable — multiple containers can share it.
.PARAMETER AdapterName
    Windows network adapter name to bind outbound traffic to
.OUTPUTS
    String - The Docker network name, or $null on failure
#>
function Ensure-NatBindNetwork {
    param(
        [string]$AdapterName
    )

    $sanitized = $AdapterName.ToLower() -replace '[^a-z0-9]', '-' -replace '-+', '-' -replace '^-|-$', ''
    $netName = "amp-nat-$sanitized"

    # Check if network already exists
    $existingDriver = & docker network inspect --format '{{.Driver}}' $netName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-WrapperLog "NAT Bind network '$netName' already exists" "DEBUG"
        return $netName
    }

    # Validate adapter exists on the host
    Write-WrapperLog "Verifying network adapter '$AdapterName' exists..." "DEBUG"
    try {
        $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
        Write-WrapperLog "Adapter found: $($adapter.Name) (Status: $($adapter.Status), MAC: $($adapter.MacAddress))" "DEBUG"

        if ($adapter.Status -ne "Up") {
            Write-WrapperLog "WARNING: Adapter '$AdapterName' is not in 'Up' state (current: $($adapter.Status))" "WARNING"
        }
    } catch {
        Write-WrapperLog "ERROR: Network adapter '$AdapterName' not found on this host." "ERROR"
        Write-WrapperLog "Available adapters:" "ERROR"
        try {
            Get-NetAdapter | ForEach-Object {
                Write-WrapperLog "  - $($_.Name) (Status: $($_.Status), MAC: $($_.MacAddress))" "ERROR"
            }
        } catch {}
        return $null
    }

    # Build docker network create command
    $netArgs = @(
        "network", "create"
        "-d", "nat"
        "--subnet", "172.30.0.0/24"
        "--gateway", "172.30.0.1"
        "-o", "com.docker.network.windowsshim.interface=$AdapterName"
        $netName
    )

    Write-WrapperLog "Creating NAT Bind network: docker $($netArgs -join ' ')" "DEBUG"

    $createOutput = & docker @netArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-WrapperLog "ERROR: Failed to create NAT Bind network '$netName'" "ERROR"
        Write-WrapperLog "Docker output: $($createOutput -join ' ')" "ERROR"
        return $null
    }

    Write-WrapperLog "NAT Bind network '$netName' created successfully (adapter: $AdapterName)"
    return $netName
}

# ============================================================================
# PID FILE MANAGEMENT
# ============================================================================

$pidFile = Join-Path $PSScriptRoot "docker_container.pid"
$flagFile = Join-Path $PSScriptRoot "container_ready.flag"

function Write-PidFile {
    <#
    .SYNOPSIS
        Writes PID file with wrapper PID, container name, container ID, and timestamp.
    .PARAMETER WrapperPid
        PID of the wrapper process
    .PARAMETER ContainerName
        Docker container name
    .PARAMETER ContainerId
        Docker container ID
    #>
    param(
        [int]$WrapperPid,
        [string]$ContainerName,
        [string]$ContainerId
    )

    $data = @{
        wrapperPid    = $WrapperPid
        containerName = $ContainerName
        containerId   = $ContainerId
        timestamp     = (Get-Date).ToString("o")
    }

    try {
        $data | ConvertTo-Json | Out-File -FilePath $pidFile -Force -Encoding UTF8
        Write-WrapperLog "PID file written: $pidFile" "DEBUG"
    } catch {
        Write-WrapperLog "WARNING: Failed to write PID file: $_" "WARNING"
    }
}

function Read-PidFile {
    <#
    .SYNOPSIS
        Reads and deserializes the PID file.
    .OUTPUTS
        PSCustomObject with wrapperPid, containerName, containerId, timestamp
        or $null if file doesn't exist or is invalid
    #>
    if (!(Test-Path $pidFile)) {
        return $null
    }

    try {
        $content = Get-Content $pidFile -Raw | ConvertFrom-Json
        return $content
    } catch {
        Write-WrapperLog "WARNING: Failed to read PID file: $_" "WARNING"
        return $null
    }
}

function Remove-PidFile {
    <#
    .SYNOPSIS
        Removes the PID file if it exists.
    #>
    if (Test-Path $pidFile) {
        try {
            Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            Write-WrapperLog "PID file removed" "DEBUG"
        } catch {
            Write-WrapperLog "WARNING: Failed to remove PID file: $_" "WARNING"
        }
    }
}

function Strip-AnsiCodes {
    <#
    .SYNOPSIS
        Strips ANSI escape codes from a string for clean AMP console display.
    .PARAMETER Text
        Input string potentially containing ANSI escape sequences
    .OUTPUTS
        String with all ANSI escape codes removed
    #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    # Match ESC[ followed by any number of params and a final letter
    return $Text -replace '\x1b\[[0-9;]*[a-zA-Z]', '' -replace '\x1b\][^\x07]*\x07', '' -replace '\x1b[^[]\S*', ''
}

# ============================================================================
# PRE-START ORPHAN CLEANUP (Task 3.1)
# ============================================================================
# Requirements: 6.1, 6.2, 6.3, 6.4
# Ensures singleton container enforcement by cleaning up orphans from
# previous runs before starting a new container.
# ============================================================================

Write-WrapperLog "=========================================="
Write-WrapperLog "Pre-Start Orphan Cleanup"
Write-WrapperLog "=========================================="

$containerName = Get-ContainerName
Write-WrapperLog "Expected container name: $containerName" "DEBUG"

# Step 1: Check for existing PID file from a previous run (Req 6.1)
$existingPid = Read-PidFile
if ($null -ne $existingPid) {
    Write-WrapperLog "Found PID file from previous run (container: $($existingPid.containerName), ID: $($existingPid.containerId))" "WARNING"

    # Step 2: Check if the referenced container still exists (Req 6.2, 6.3)
    $containerExists = $false
    $containerRunning = $false
    try {
        $inspectOutput = & docker inspect --format '{{.State.Running}}' $existingPid.containerName 2>&1
        if ($LASTEXITCODE -eq 0) {
            $containerExists = $true
            $containerRunning = ($inspectOutput.Trim() -eq "true")
            Write-WrapperLog "Previous container exists (running: $containerRunning)" "DEBUG"
        } else {
            Write-WrapperLog "Previous container no longer exists" "DEBUG"
        }
    } catch {
        Write-WrapperLog "Could not inspect previous container: $_" "DEBUG"
    }

    if ($containerExists -and $containerRunning) {
        # Container is still running — stop and remove it (Req 6.2)
        Write-WrapperLog "Stopping orphaned container: $($existingPid.containerName)" "WARNING"
        & docker stop -t $DOCKER_STOP_TIMEOUT $existingPid.containerName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-WrapperLog "docker stop failed, forcing kill..." "WARNING"
            & docker kill $existingPid.containerName 2>&1 | Out-Null
        }
        & docker rm -f $existingPid.containerName 2>&1 | Out-Null
        Write-WrapperLog "Orphaned container removed" "DEBUG"
    } elseif ($containerExists) {
        # Container exists but not running — just remove it
        Write-WrapperLog "Removing stopped orphan container: $($existingPid.containerName)" "DEBUG"
        & docker rm -f $existingPid.containerName 2>&1 | Out-Null
    }

    # Remove stale PID file (Req 6.3)
    Remove-PidFile
    Write-WrapperLog "Stale PID file cleaned up" "DEBUG"
} else {
    Write-WrapperLog "No PID file found - clean state" "DEBUG"
}

# Step 3: Verify no container with expected name already exists (Req 6.4)
$nameCheck = & docker inspect --format '{{.State.Status}}' $containerName 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-WrapperLog "Container '$containerName' already exists (status: $nameCheck) - removing..." "WARNING"
    & docker rm -f $containerName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-WrapperLog "ERROR: Failed to remove existing container '$containerName'" "ERROR"
        exit 1
    }
    Write-WrapperLog "Existing container removed" "DEBUG"
} else {
    Write-WrapperLog "No existing container with name '$containerName' - clean state" "DEBUG"
}

# Remove leftover flag file from previous run
if (Test-Path $flagFile) {
    Remove-Item $flagFile -Force -ErrorAction SilentlyContinue
    Write-WrapperLog "Removed leftover flag file" "DEBUG"
}

# ============================================================================
# CONTAINER START SEQUENCE (Task 3.3)
# ============================================================================
# Requirements: 2.4, 2.7, 2.8, 2.9, 2.10, 5.1, 11.1
# Pull image → docker create → docker start → launch log streaming →
# launch watchdog → create flag file → write PID file → output RUNNING
# ============================================================================

Write-WrapperLog "=========================================="
Write-WrapperLog "Starting Docker Container"
Write-WrapperLog "=========================================="

# Step 1: Pull image if needed (Req 11.1)
Write-WrapperLog "Checking Docker image: $dockerImage"
$imageExists = & docker image inspect $dockerImage 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-WrapperLog "Image not found locally, pulling: $dockerImage"
    Write-WrapperLog "State: STARTING - Pulling Docker image..."
    & docker pull $dockerImage 2>&1 | ForEach-Object {
        Write-WrapperLog "  [PULL] $_" "DEBUG"
    }
    if ($LASTEXITCODE -ne 0) {
        Write-WrapperLog "ERROR: Failed to pull Docker image '$dockerImage'" "ERROR"
        Write-WrapperLog "Ensure the image name is correct and Docker has network access." "ERROR"
        exit 1
    }
    Write-WrapperLog "Image pulled successfully"
} else {
    Write-WrapperLog "Image available locally" "DEBUG"
}

# Step 2: Build docker create command and create container (Req 2.4)
Write-WrapperLog "State: STARTING - Creating container..."

# Resolve the executable host directory (mount into container)
$exeHostDir = (Get-Location).Path

# Resolve network name based on mode
$resolvedNetworkName = $networkMode
if ($networkMode -eq "transparent") {
    if ([string]::IsNullOrWhiteSpace($networkAdapter)) {
        Write-WrapperLog "ERROR: Transparent network mode requires a Network Adapter Name to be configured." "ERROR"
        Write-WrapperLog "Set the 'Network Adapter Name' in AMP instance settings (e.g., 'Ethernet 2')." "ERROR"
        Write-WrapperLog "Run 'Get-NetAdapter' in PowerShell to list available adapters." "ERROR"
        exit 1
    }

    # Validate static IP requires subnet and gateway
    if (![string]::IsNullOrWhiteSpace($containerIP)) {
        if ([string]::IsNullOrWhiteSpace($networkSubnet) -or [string]::IsNullOrWhiteSpace($networkGateway)) {
            Write-WrapperLog "ERROR: Static Container IP requires both Network Subnet and Network Gateway to be configured." "ERROR"
            exit 1
        }
    }

    $resolvedNetworkName = Ensure-TransparentNetwork `
        -AdapterName $networkAdapter `
        -Subnet $networkSubnet `
        -Gateway $networkGateway

    if ($null -eq $resolvedNetworkName) {
        Write-WrapperLog "ERROR: Failed to set up transparent network. Cannot start container." "ERROR"
        exit 1
    }

    Write-WrapperLog "Using transparent network: $resolvedNetworkName (adapter: $networkAdapter)"
    if (![string]::IsNullOrWhiteSpace($containerIP)) {
        Write-WrapperLog "Static IP: $containerIP (subnet: $networkSubnet, gateway: $networkGateway)"
    } else {
        Write-WrapperLog "IP assignment: DHCP (from physical network)"
    }
} elseif ($networkMode -eq "nat-bind") {
    if ([string]::IsNullOrWhiteSpace($networkAdapter)) {
        Write-WrapperLog "ERROR: NAT Bind mode requires a Network Adapter Name to be configured." "ERROR"
        Write-WrapperLog "Set the 'Network Adapter Name' in AMP instance settings (e.g., 'Ethernet 2')." "ERROR"
        Write-WrapperLog "Run 'Get-NetAdapter' in PowerShell to list available adapters." "ERROR"
        exit 1
    }

    $resolvedNetworkName = Ensure-NatBindNetwork -AdapterName $networkAdapter

    if ($null -eq $resolvedNetworkName) {
        Write-WrapperLog "ERROR: Failed to set up NAT Bind network. Cannot start container." "ERROR"
        exit 1
    }

    Write-WrapperLog "Using NAT Bind network: $resolvedNetworkName (outbound via adapter: $networkAdapter)"
}

$createArgs = Build-DockerCreateCommand `
    -ContainerName $containerName `
    -Image $dockerImage `
    -CpuLimit $cpuLimit `
    -MemoryLimit $memoryLimit `
    -NetworkName $resolvedNetworkName `
    -ContainerIP $containerIP `
    -ExeHostDir $exeHostDir `
    -ExePath $executablePath `
    -ExeArgs $commandLineArgs `
    -ExtraMountString $extraMounts `
    -UpdateSSLCerts $updateSSLCerts

Write-WrapperLog "Docker create command: docker $($createArgs -join ' ')" "DEBUG"

$createOutput = & docker @createArgs 2>&1
$createExitCode = $LASTEXITCODE

if ($createExitCode -ne 0) {
    Write-WrapperLog "ERROR: Failed to create Docker container (exit code: $createExitCode)" "ERROR"
    Write-WrapperLog "Docker output: $($createOutput -join ' ')" "ERROR"
    exit 1
}

$containerId = ($createOutput | Select-Object -Last 1).Trim()
Write-WrapperLog "Container created: $containerName (ID: $containerId)"

# Step 3: Start the container (Req 2.7)
Write-WrapperLog "Starting container..."
$startOutput = & docker start $containerName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-WrapperLog "ERROR: Failed to start container (exit code: $LASTEXITCODE)" "ERROR"
    Write-WrapperLog "Docker output: $($startOutput -join ' ')" "ERROR"
    & docker rm -f $containerName 2>&1 | Out-Null
    exit 1
}
Write-WrapperLog "Container started successfully"

# Log container IP address (useful for transparent mode)
if ($networkMode -eq "transparent") {
    try {
        $containerIpInfo = & docker inspect --format "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" $containerName 2>&1
        if ($LASTEXITCODE -eq 0 -and ![string]::IsNullOrWhiteSpace($containerIpInfo.Trim())) {
            Write-WrapperLog "Container IP address: $($containerIpInfo.Trim())"
        }
    } catch {}
}

# Step 4: Launch log streaming job (Req 2.7 - docker logs --follow)
Write-WrapperLog "Starting log stream..." "DEBUG"
$logJob = Start-Job -ScriptBlock {
    param($name)
    & docker logs --follow --timestamps $name 2>&1
} -ArgumentList $containerName

# Step 5: Launch watchdog process (Req 5.1)
$watchdogScript = Join-Path $PSScriptRoot "DockerWatchdog.ps1"
$wrapperPid = $PID

if (Test-Path $watchdogScript) {
    try {
        $wdArgs = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogScript`" " +
                  "-WrapperPID $wrapperPid " +
                  "-ContainerName `"$containerName`" " +
                  "-ContainerID `"$containerId`" " +
                  "-ScriptRoot `"$PSScriptRoot`""

        $wdPsi = New-Object System.Diagnostics.ProcessStartInfo
        $wdPsi.FileName = "C:\Program Files\PowerShell\7\pwsh.exe"
        $wdPsi.Arguments = $wdArgs
        $wdPsi.UseShellExecute = $false
        $wdPsi.CreateNoWindow = $true

        $wdProcess = [System.Diagnostics.Process]::Start($wdPsi)
        Write-WrapperLog "Watchdog started (PID: $($wdProcess.Id))" "DEBUG"
    } catch {
        Write-WrapperLog "WARNING: Failed to start watchdog: $_" "WARNING"
        Write-WrapperLog "Container will run without orphan protection." "WARNING"
    }
} else {
    Write-WrapperLog "WARNING: Watchdog script not found: $watchdogScript" "WARNING"
    Write-WrapperLog "Container will run without orphan protection." "WARNING"
}

# Step 6: Create flag file (Req 2.9)
try {
    "" | Out-File -FilePath $flagFile -Force -Encoding UTF8
    Write-WrapperLog "Flag file created: $flagFile" "DEBUG"
} catch {
    Write-WrapperLog "WARNING: Failed to create flag file: $_" "WARNING"
}

# Step 7: Write PID file (Req 2.10)
Write-PidFile -WrapperPid $wrapperPid -ContainerName $containerName -ContainerId $containerId

# Step 8: Output RUNNING state to trigger AMP ready detection (Req 2.8)
Write-WrapperLog "=========================================="
Write-WrapperLog "Container Running Successfully"
Write-WrapperLog "=========================================="
Write-WrapperLog "State: RUNNING - Monitoring process..."

# ============================================================================
# MONITORING LOOP (Task 3.4)
# ============================================================================
# Requirements: 9.1, 9.2, 9.3, 11.4
# Watch for container exit, pipe log output to AMP console with ANSI
# stripping, heartbeat logging, cleanup on natural exit.
# ============================================================================

$lastHeartbeat = Get-Date
$wrapperExitCode = 0

try {
    while ($true) {
        # Check container status via docker inspect
        $statusOutput = & docker inspect --format '{{.State.Running}}' $containerName 2>&1
        if ($LASTEXITCODE -ne 0 -or $statusOutput.Trim() -ne "true") {
            # Container has exited
            Write-WrapperLog "Container has stopped" "DEBUG"
            break
        }

        # Pipe log output from the background job to AMP console (Req 9.1, 9.3)
        if ($null -ne $logJob) {
            $jobOutput = Receive-Job -Job $logJob -ErrorAction SilentlyContinue
            if ($jobOutput) {
                foreach ($line in $jobOutput) {
                    $cleanLine = Strip-AnsiCodes -Text "$line"
                    if (![string]::IsNullOrWhiteSpace($cleanLine)) {
                        Write-Host $cleanLine
                    }
                }
            }
        }

        # Heartbeat logging
        $now = Get-Date
        if (($now - $lastHeartbeat).TotalSeconds -ge $HEARTBEAT_INTERVAL_SECONDS) {
            $lastHeartbeat = $now
            Write-WrapperLog "Heartbeat: Container '$containerName' alive" "DEBUG"
        }

        Start-Sleep -Milliseconds $MONITOR_POLL_INTERVAL_MS
    }

    # Container exited — get exit code (Req 9.2)
    $exitCodeOutput = & docker inspect --format '{{.State.ExitCode}}' $containerName 2>&1
    if ($LASTEXITCODE -eq 0) {
        $rawExitCode = [long]$exitCodeOutput.Trim()
        # Clamp to valid process exit code range (0-255 for cross-platform compat)
        if ($rawExitCode -gt [int]::MaxValue -or $rawExitCode -lt [int]::MinValue) {
            Write-WrapperLog "Container exit code $rawExitCode exceeds Int32 range, using 1" "WARNING"
            $wrapperExitCode = 1
        } else {
            $wrapperExitCode = [int]$rawExitCode
        }
        Write-WrapperLog "Container exit code: $wrapperExitCode"
    } else {
        Write-WrapperLog "Could not retrieve container exit code" "WARNING"
    }

    # Drain remaining log output
    if ($null -ne $logJob) {
        Start-Sleep -Milliseconds 500
        $remaining = Receive-Job -Job $logJob -ErrorAction SilentlyContinue
        if ($remaining) {
            foreach ($line in $remaining) {
                $cleanLine = Strip-AnsiCodes -Text "$line"
                if (![string]::IsNullOrWhiteSpace($cleanLine)) {
                    Write-Host $cleanLine
                }
            }
        }
    }

} finally {
    # Cleanup on exit (natural or wrapper killed) (Req 11.4)
    Write-WrapperLog "Wrapper finalizing - cleaning up..." "DEBUG"

    # Stop and remove the log streaming job
    if ($null -ne $logJob) {
        try {
            Stop-Job -Job $logJob -ErrorAction SilentlyContinue
            Remove-Job -Job $logJob -Force -ErrorAction SilentlyContinue
        } catch {}
    }

    # Remove the container (Req 11.4)
    try {
        & docker rm -f $containerName 2>&1 | Out-Null
        Write-WrapperLog "Container removed: $containerName" "DEBUG"
    } catch {
        Write-WrapperLog "WARNING: Failed to remove container: $_" "WARNING"
    }

    # Remove PID file and flag file
    Remove-PidFile
    if (Test-Path $flagFile) {
        Remove-Item $flagFile -Force -ErrorAction SilentlyContinue
        Write-WrapperLog "Flag file removed" "DEBUG"
    }

    Write-WrapperLog "State: STOPPED - Wrapper exiting (code: $wrapperExitCode)"
    Write-WrapperLog "=========================================="
}

exit $wrapperExitCode
