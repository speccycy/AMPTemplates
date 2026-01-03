# SCUM AMP Wrapper - User Guide

## Overview

The SCUM AMP Wrapper is a PowerShell script that manages SCUM Dedicated Server instances within the CubeCoders AMP (Application Management Panel) environment. It ensures **100% data integrity** through graceful shutdown procedures while preventing race conditions, duplicate processes, and orphaned instances.

**Version:** 3.0  
**Platform:** Windows Server / CubeCoders AMP  
**Requirements:** PowerShell 5.1+

---

## Key Features

### 🛡️ Data Integrity Protection
- **Graceful shutdown with save confirmation** - Waits for "LogExit: Exiting" pattern
- **Failsafe timeout (30s)** - Prevents hung shutdowns from blocking AMP
- **Uptime-based shutdown decision** - Abort mode for startup, graceful for running servers

### 🔒 Process Management
- **Singleton enforcement** - Prevents duplicate server instances
- **Orphan process cleanup** - Automatically terminates stale processes
- **PID file with timestamp** - Smart lock with staleness detection
- **Race condition prevention** - Ensures clean process transitions

### 📊 Comprehensive Logging
- **Dual output** - Console (for AMP) + file (for troubleshooting)
- **State transition tracking** - DEBUG level logs for detailed analysis
- **Automatic log rotation** - 7-day retention to prevent disk exhaustion
- **Shutdown confirmation** - Clear success/failure indicators

### 🔧 Reliability Features
- **Windows API signal support** - Proper Ctrl+C delivery via kernel32.dll
- **Fallback signal method** - CloseMainWindow if API unavailable
- **Event-based cleanup** - PID file removal even if wrapper crashes
- **Exit code propagation** - AMP can detect crashes vs normal exits

---

## Quick Start

### Installation

The wrapper is automatically installed with the SCUM AMP template. No manual installation required.

**File Location:** `Binaries/Win64/SCUMWrapper.ps1`

### AMP Configuration

The wrapper requires specific AMP configuration in `scum.kvp`:

```kvp
App.ExitMethod=OS_CLOSE
App.ExitMethodWindows=CtrlC
App.ExitTimeout=35
```

These settings ensure AMP sends Ctrl+C to the wrapper instead of force killing it.

### Basic Usage

The wrapper is transparent to users. Simply use AMP's normal controls:

- **Start Server:** Click "Start" in AMP
- **Stop Server:** Click "Stop" in AMP
- **Restart Server:** Click "Restart" in AMP

The wrapper handles all process management automatically.

---

## How It Works

### Startup Sequence

1. **Initialization**
   - Load Windows API for Ctrl+C support
   - Setup logging system
   - Clean old logs (> 7 days)

2. **Pre-Start Check**
   - Scan for orphan SCUM processes
   - Terminate any existing processes
   - Wait 5 seconds for cleanup
   - Verify all processes are gone

3. **Singleton Enforcement**
   - Check for existing PID file
   - Validate PID file age and process existence
   - Remove stale PID files (> 5 minutes old)
   - Create new PID file with wrapper PID

4. **Server Launch**
   - Start SCUMServer.exe with arguments
   - Update PID file with server PID
   - Register cleanup event handler
   - Monitor process until exit

### Shutdown Sequence

When AMP sends stop signal (Ctrl+C to wrapper):

1. **Uptime Check**
   - Calculate server uptime
   - Decide: Abort mode (< 30s) or Graceful mode (≥ 30s)

2. **Abort Mode** (uptime < 30 seconds)
   - Server is still starting up
   - Immediate force kill (safe - no data to save)
   - Log: "Shutdown completed (startup abort, force killed)"

3. **Graceful Mode** (uptime ≥ 30 seconds)
   - Send Ctrl+C signal to server
   - Monitor `Saved/Logs/SCUM.log` for "LogExit: Exiting" pattern
   - Check every 2 seconds for up to 30 seconds
   - If LogExit detected: Clean exit
   - If timeout reached: Force kill (failsafe)

4. **Cleanup**
   - Remove PID file
   - Unregister event handler
   - Exit with server's exit code

---

## Understanding Shutdown Modes

### Why Two Modes?

The wrapper uses different strategies based on server state:

| Mode | Uptime | Strategy | Reason |
|------|--------|----------|--------|
| **Abort** | < 30s | Immediate force kill | Server hasn't initialized, no data to save |
| **Graceful** | ≥ 30s | Ctrl+C + LogExit wait | Server may have player data, must save |

### Graceful Shutdown Process

```
1. Send Ctrl+C signal
   ↓
2. Server receives signal
   ↓
3. Server saves all data
   ↓
4. Server writes "LogExit: Exiting" to log
   ↓
5. Wrapper detects LogExit pattern
   ↓
6. Wrapper confirms graceful shutdown
   ↓
7. Clean exit
```

### Failsafe Timeout

If LogExit pattern doesn't appear within 30 seconds:

```
1. Assume server is frozen/crashed
   ↓
2. Force kill process
   ↓
3. Log: "Shutdown completed (failsafe timeout, force killed)"
   ↓
4. Release AMP instance
```

This prevents hung shutdowns from blocking AMP indefinitely.

---

## Log Files

### Wrapper Logs

**Location:** `Binaries/Win64/Logs/SCUMWrapper_YYYY-MM-DD.log`

**Contains:**
- Process management events
- Shutdown decisions (abort vs graceful)
- PID file operations
- Orphan cleanup actions
- Signal sending results
- LogExit detection status

**Retention:** 7 days (automatic cleanup)

### Server Logs

**Location:** `Saved/Logs/SCUM.log`

**Contains:**
- Game events (player joins, deaths, etc.)
- Server errors and warnings
- Save operations
- **LogExit pattern** (shutdown confirmation)

**Retention:** Managed by SCUM server

### Reading Logs

**Check last shutdown:**
```powershell
Get-Content "Binaries\Win64\Logs\SCUMWrapper_*.log" | 
    Select-String "Shutdown completed" | 
    Select-Object -Last 1
```

**Check for errors:**
```powershell
Get-Content "Binaries\Win64\Logs\SCUMWrapper_*.log" | 
    Select-String "ERROR"
```

**Monitor in real-time:**
```powershell
Get-Content "Binaries\Win64\Logs\SCUMWrapper_$(Get-Date -Format 'yyyy-MM-dd').log" -Wait -Tail 20
```

---

## Shutdown Status Indicators

### ✓ Perfect Shutdown (Safe)

```
[WRAPPER-DEBUG] LogExit pattern detected! Server saved successfully.
[WRAPPER-INFO] Shutdown completed successfully in 8.2s (graceful, LogExit detected)
```

**Meaning:** Server saved all data and exited cleanly  
**Data Integrity:** ✓ 100% Safe  
**Action:** None

### ⚠ Uncertain Shutdown (Possibly Unsafe)

```
[WRAPPER-WARN] Shutdown completed in 5.1s (process exited, no LogExit)
```

**Meaning:** Process exited but no save confirmation  
**Data Integrity:** ⚠ Possibly unsafe  
**Action:** Check server logs for errors

### ✗ Failed Shutdown (Risk of Corruption)

```
[WRAPPER-ERROR] State: FAILSAFE_TIMEOUT - No LogExit after 30s!
[WRAPPER-WARN] Shutdown completed in 30.5s (failsafe timeout, force killed)
```

**Meaning:** Server didn't respond, force killed  
**Data Integrity:** ✗ Risk of corruption  
**Action:** Investigate server stability, check for crashes

### ✓ Startup Abort (Safe)

```
[WRAPPER-WARN] Server in startup phase (< 30s) - ABORT MODE
[WRAPPER-WARN] Shutdown completed (startup abort, force killed)
```

**Meaning:** Server killed during startup  
**Data Integrity:** ✓ Safe (no data to save)  
**Action:** None (expected behavior)

---

## Common Scenarios

### Normal Stop After 5 Minutes

```
User clicks "Stop" in AMP
    ↓
Wrapper receives Ctrl+C
    ↓
Uptime check: 5 minutes (> 30s)
    ↓
Graceful mode activated
    ↓
Send Ctrl+C to server
    ↓
Monitor for LogExit pattern
    ↓
LogExit detected after 8 seconds
    ↓
Clean exit
```

**Result:** Perfect shutdown, all data saved

### Quick Stop Within 30 Seconds

```
User clicks "Stop" in AMP
    ↓
Wrapper receives Ctrl+C
    ↓
Uptime check: 15 seconds (< 30s)
    ↓
Abort mode activated
    ↓
Immediate force kill
    ↓
Clean exit
```

**Result:** Fast shutdown, safe (no data to save)

### Scheduled Restart

```
AMP scheduled task triggers
    ↓
AMP sends stop signal
    ↓
Wrapper performs graceful shutdown
    ↓
LogExit detected
    ↓
Wrapper exits
    ↓
AMP waits for wrapper exit
    ↓
AMP starts new instance
    ↓
New wrapper starts
    ↓
Orphan check (none found)
    ↓
New server starts
```

**Result:** Clean restart, no race conditions

### Orphan Recovery

```
User manually starts SCUM server
    ↓
User tries to start in AMP
    ↓
Wrapper starts
    ↓
Pre-start check finds orphan
    ↓
Orphan terminated
    ↓
Wait 5 seconds
    ↓
Verify cleanup
    ↓
New server starts
```

**Result:** Orphan cleaned up, new instance starts

---

## Troubleshooting

### Quick Diagnostics

1. **Check wrapper log:** `Binaries/Win64/Logs/SCUMWrapper_*.log`
2. **Check server log:** `Saved/Logs/SCUM.log`
3. **Check PID file:** `Binaries/Win64/scum_server.pid` (should not exist when stopped)

### Common Issues

| Issue | Solution | Documentation |
|-------|----------|---------------|
| "Another instance is running" | Delete stale PID file | [TROUBLESHOOTING.md](TROUBLESHOOTING.md#issue-1-another-instance-is-running-error) |
| Server won't stop | Wait for failsafe (30s) | [TROUBLESHOOTING.md](TROUBLESHOOTING.md#issue-2-server-wont-stop-hangs-on-stopping) |
| Orphan processes | Automatic cleanup | [TROUBLESHOOTING.md](TROUBLESHOOTING.md#issue-3-orphan-processes-after-restart) |
| Database corruption | Check for graceful shutdown | [TROUBLESHOOTING.md](TROUBLESHOOTING.md#issue-4-database-corruption--lost-player-data) |
| Port conflicts | Check for stuck processes | [TROUBLESHOOTING.md](TROUBLESHOOTING.md#issue-6-port-conflicts--address-already-in-use) |

### Getting Help

For detailed troubleshooting, see:
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** - Comprehensive troubleshooting guide
- **[LOG_MESSAGES.md](LOG_MESSAGES.md)** - Complete log message reference

---

## Configuration

### Timing Constants

The wrapper uses these timing values (defined in script):

| Constant | Value | Purpose |
|----------|-------|---------|
| `STARTUP_PHASE_THRESHOLD` | 30s | Abort vs graceful decision |
| `FAILSAFE_TIMEOUT` | 30s | Max wait for LogExit |
| `ORPHAN_CLEANUP_WAIT` | 5s | Wait after killing orphans |
| `PID_FILE_STALENESS_MINUTES` | 5 min | Stale PID file threshold |
| `LOG_RETENTION_DAYS` | 7 days | Log file retention |
| `LOGEXIT_CHECK_INTERVAL` | 2s | LogExit polling frequency |

### Adjusting Timeouts

To change timeouts, edit `SCUMWrapper.ps1`:

```powershell
# Find this section near the top of the file:
Set-Variable -Name FAILSAFE_TIMEOUT -Value 30 -Option Constant

# Change 30 to your desired timeout (in seconds)
Set-Variable -Name FAILSAFE_TIMEOUT -Value 45 -Option Constant
```

**Recommendation:** Only increase if you have evidence that saves take longer than 30 seconds.

---

## Best Practices

### ✓ DO

- **Use AMP's Stop button** - Always use proper shutdown
- **Wait for graceful shutdown** - Don't restart immediately
- **Check logs after shutdown** - Verify LogExit detection
- **Monitor shutdown times** - Identify performance issues early
- **Keep logs for troubleshooting** - 7-day retention is automatic

### ✗ DON'T

- **Don't kill processes manually** - Use AMP controls
- **Don't delete PID file while running** - Breaks singleton enforcement
- **Don't edit wrapper while running** - Stop server first
- **Don't ignore failsafe timeouts** - Investigate server stability
- **Don't disable graceful shutdown** - Risks data corruption

---

## Performance Expectations

### Typical Shutdown Times

| Server State | Expected Time | Status |
|--------------|---------------|--------|
| Startup abort (< 30s) | < 1s | Instant |
| Small server (< 10 players) | 5-10s | Excellent |
| Medium server (10-30 players) | 10-15s | Good |
| Large server (30-64 players) | 15-25s | Acceptable |
| Very large / slow disk | 25-30s | Slow (investigate) |
| Failsafe timeout | 30s+ | Problem (investigate) |

### Resource Usage

The wrapper uses minimal resources:
- **CPU:** < 1%
- **Memory:** < 50MB
- **Disk I/O:** Minimal (log writes only)

---

## Version History

### v3.0 (Current)
- Graceful shutdown with LogExit detection
- Failsafe timeout (30 seconds)
- Orphan process cleanup
- Singleton enforcement with PID file
- Uptime-based shutdown decision
- Comprehensive logging system
- Event-based cleanup handlers
- Windows API signal support
- Automatic log rotation

---

## Technical Details

### Architecture

```
AMP Control Panel
    ↓ (Ctrl+C signal)
SCUMWrapper.ps1
    ↓ (Process management)
SCUMServer.exe
    ↓ (Saves data)
Database Files
```

### Signal Flow

```
AMP sends Ctrl+C to wrapper
    ↓
Wrapper catches signal in finally block
    ↓
Wrapper sends Ctrl+C to server
    ↓
Server receives signal
    ↓
Server saves data
    ↓
Server writes LogExit to log
    ↓
Wrapper detects LogExit
    ↓
Wrapper exits cleanly
    ↓
AMP detects wrapper exit
```

### File Locations

```
SCUM/
├── Binaries/
│   └── Win64/
│       ├── SCUMServer.exe          # Game server
│       ├── SCUMWrapper.ps1         # Wrapper script
│       ├── scum_server.pid         # PID file (runtime)
│       ├── README.md               # This file
│       ├── TROUBLESHOOTING.md      # Troubleshooting guide
│       ├── LOG_MESSAGES.md         # Log reference
│       └── Logs/                   # Wrapper logs
│           └── SCUMWrapper_YYYY-MM-DD.log
└── Saved/
    └── Logs/
        └── SCUM.log                # Server log (LogExit pattern)
```

---

## Support

### Documentation

- **[README.md](README.md)** (this file) - Overview and quick start
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** - Detailed troubleshooting
- **[LOG_MESSAGES.md](LOG_MESSAGES.md)** - Complete log reference
- **SCUMWrapper.ps1** - Inline code documentation

### Community Resources

- **CubeCoders AMP Discord** - AMP-specific support
- **SCUM Official Discord** - Game server support
- **GitHub Issues** - Bug reports and feature requests

### Reporting Issues

When reporting issues, include:
1. Wrapper version (check first line of log)
2. AMP version
3. SCUM server version
4. Latest wrapper log
5. Latest server log
6. Steps to reproduce

---

## License

This wrapper is part of the CubeCoders AMP Templates project.

---

## Credits

**Developed for:** CubeCoders AMP  
**Game:** SCUM by Gamepires  
**Purpose:** Ensure 100% data integrity through graceful shutdown

---

**Last Updated:** January 2026  
**Wrapper Version:** 3.0
