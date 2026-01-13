# Test-AMPIntegration.ps1
# Quick verification script for SCUM AMP integration
# This script performs automated checks that can be run before manual testing

param(
    [switch]$Verbose
)

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:Warnings = 0

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = "",
        [switch]$Warning
    )
    
    if ($Warning) {
        Write-Host "⚠️  WARNING: $TestName" -ForegroundColor Yellow
        if ($Message) { Write-Host "   $Message" -ForegroundColor Yellow }
        $script:Warnings++
    }
    elseif ($Passed) {
        Write-Host "✅ PASS: $TestName" -ForegroundColor Green
        if ($Message) { Write-Host "   $Message" -ForegroundColor Gray }
        $script:TestsPassed++
    }
    else {
        Write-Host "❌ FAIL: $TestName" -ForegroundColor Red
        if ($Message) { Write-Host "   $Message" -ForegroundColor Red }
        $script:TestsFailed++
    }
}

Write-Host "`n=== SCUM AMP Integration Pre-Flight Checks ===" -ForegroundColor Cyan
Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n" -ForegroundColor Gray

# Test 1: Verify wrapper script exists
Write-Host "[1/10] Checking wrapper script..." -ForegroundColor Cyan
$wrapperPath = Join-Path $PSScriptRoot "SCUMWrapper.ps1"
if (Test-Path $wrapperPath) {
    $wrapperContent = Get-Content $wrapperPath -Raw
    if ($wrapperContent -match '\$WrapperVersion\s*=\s*"([^"]+)"') {
        $version = $matches[1]
        Write-TestResult "Wrapper script exists" $true "Version: $version"
    }
    else {
        Write-TestResult "Wrapper script exists" $true "Version: Unknown"
    }
}
else {
    Write-TestResult "Wrapper script exists" $false "Not found at: $wrapperPath"
}

# Test 2: Verify SCUM server executable exists
Write-Host "[2/10] Checking SCUM server executable..." -ForegroundColor Cyan
$serverPath = Join-Path $PSScriptRoot "SCUMServer.exe"
if (Test-Path $serverPath) {
    $serverInfo = Get-Item $serverPath
    Write-TestResult "SCUM server executable exists" $true "Size: $([math]::Round($serverInfo.Length / 1MB, 2)) MB"
}
else {
    Write-TestResult "SCUM server executable exists" $false "Not found at: $serverPath"
}

# Test 3: Verify no orphan processes
Write-Host "[3/10] Checking for orphan SCUM processes..." -ForegroundColor Cyan
$orphans = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
if ($orphans) {
    Write-TestResult "No orphan processes" $false "Found $($orphans.Count) orphan process(es): $($orphans.Id -join ', ')"
}
else {
    Write-TestResult "No orphan processes" $true
}

# Test 4: Verify no stale PID file
Write-Host "[4/10] Checking for stale PID file..." -ForegroundColor Cyan
$pidFilePath = Join-Path $PSScriptRoot "scum_server.pid"
if (Test-Path $pidFilePath) {
    try {
        $pidData = Get-Content $pidFilePath -Raw | ConvertFrom-Json
        $pidAge = (Get-Date) - [DateTime]::Parse($pidData.Timestamp)
        
        if ($pidAge.TotalMinutes -gt 5) {
            Write-TestResult "No stale PID file" $false "PID file is $([math]::Round($pidAge.TotalMinutes, 1)) minutes old (stale)"
        }
        else {
            # Check if process is actually running
            $wrapperRunning = Get-Process -Id $pidData.PID -ErrorAction SilentlyContinue
            if ($wrapperRunning) {
                Write-TestResult "No stale PID file" -Warning $true "PID file exists and wrapper is running (PID: $($pidData.PID))"
            }
            else {
                Write-TestResult "No stale PID file" $false "PID file exists but wrapper is not running (stale)"
            }
        }
    }
    catch {
        Write-TestResult "No stale PID file" $false "PID file is corrupted: $_"
    }
}
else {
    Write-TestResult "No stale PID file" $true
}

# Test 5: Verify PowerShell version
Write-Host "[5/10] Checking PowerShell version..." -ForegroundColor Cyan
$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -ge 5) {
    Write-TestResult "PowerShell version" $true "Version: $($psVersion.Major).$($psVersion.Minor)"
}
else {
    Write-TestResult "PowerShell version" $false "Version $($psVersion.Major).$($psVersion.Minor) is too old (need 5.0+)"
}

# Test 6: Verify log directory exists
Write-Host "[6/10] Checking log directory..." -ForegroundColor Cyan
$logDir = Join-Path $PSScriptRoot "Logs"
if (Test-Path $logDir) {
    $logFiles = Get-ChildItem $logDir -Filter "SCUMWrapper_*.log" -ErrorAction SilentlyContinue
    Write-TestResult "Log directory exists" $true "Found $($logFiles.Count) log file(s)"
}
else {
    Write-TestResult "Log directory exists" $false "Directory not found: $logDir"
}

# Test 7: Verify SCUM log file path
Write-Host "[7/10] Checking SCUM log file path..." -ForegroundColor Cyan
$scumLogPath = Join-Path $PSScriptRoot "../../../../Saved/Logs/SCUM.log"
$scumLogDir = Split-Path $scumLogPath -Parent
if (Test-Path $scumLogDir) {
    if (Test-Path $scumLogPath) {
        $logInfo = Get-Item $scumLogPath
        Write-TestResult "SCUM log file path" $true "Last modified: $($logInfo.LastWriteTime)"
    }
    else {
        Write-TestResult "SCUM log file path" -Warning $true "Directory exists but log file not found (normal if server never ran)"
    }
}
else {
    Write-TestResult "SCUM log file path" $false "Log directory not found: $scumLogDir"
}

# Test 8: Verify AMP template configuration
Write-Host "[8/10] Checking AMP template configuration..." -ForegroundColor Cyan
$kvpPath = Join-Path $PSScriptRoot "../../../../../../scum.kvp"
if (Test-Path $kvpPath) {
    $kvpContent = Get-Content $kvpPath -Raw
    
    $checks = @{
        "App.ExitMethodWindows=CtrlC" = $kvpContent -match "App\.ExitMethodWindows=CtrlC"
        "App.ExitTimeout=35" = $kvpContent -match "App\.ExitTimeout=35"
        "SCUMWrapper.ps1 invocation" = $kvpContent -match "SCUMWrapper\.ps1"
    }
    
    $allPassed = $true
    foreach ($check in $checks.GetEnumerator()) {
        if (-not $check.Value) {
            $allPassed = $false
            if ($Verbose) {
                Write-Host "   Missing: $($check.Key)" -ForegroundColor Red
            }
        }
    }
    
    if ($allPassed) {
        Write-TestResult "AMP template configuration" $true "All required settings present"
    }
    else {
        Write-TestResult "AMP template configuration" $false "Missing required settings (use -Verbose for details)"
    }
}
else {
    Write-TestResult "AMP template configuration" -Warning $true "scum.kvp not found (may be in different location)"
}

# Test 9: Verify Windows API availability
Write-Host "[9/10] Checking Windows API availability..." -ForegroundColor Cyan
try {
    $apiTest = Add-Type -MemberDefinition @"
        [DllImport("kernel32.dll")]
        public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
"@ -Name "TestAPI" -Namespace "Win32" -PassThru -ErrorAction Stop
    Write-TestResult "Windows API availability" $true "kernel32.dll accessible"
}
catch {
    Write-TestResult "Windows API availability" $false "Cannot load Windows API: $_"
}

# Test 10: Verify execution policy
Write-Host "[10/10] Checking PowerShell execution policy..." -ForegroundColor Cyan
$execPolicy = Get-ExecutionPolicy
if ($execPolicy -eq "Restricted") {
    Write-TestResult "Execution policy" $false "Policy is Restricted (wrapper cannot run)"
}
elseif ($execPolicy -eq "AllSigned") {
    Write-TestResult "Execution policy" -Warning $true "Policy is AllSigned (wrapper must be signed)"
}
else {
    Write-TestResult "Execution policy" $true "Policy: $execPolicy"
}

# Summary
Write-Host "`n=== Test Summary ===" -ForegroundColor Cyan
Write-Host "Passed:   $script:TestsPassed" -ForegroundColor Green
Write-Host "Failed:   $script:TestsFailed" -ForegroundColor Red
Write-Host "Warnings: $script:Warnings" -ForegroundColor Yellow

if ($script:TestsFailed -eq 0) {
    Write-Host "`n✅ All critical checks passed! Ready for AMP integration testing." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "`n❌ Some checks failed. Please fix issues before testing." -ForegroundColor Red
    exit 1
}
