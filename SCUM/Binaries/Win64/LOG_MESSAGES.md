# SCUM AMP Wrapper - Log Message Reference

## Quick Reference Guide

This document provides a comprehensive reference for all log messages produced by the SCUM AMP Wrapper, their meanings, and recommended actions.

---

## Log Levels

| Level | Prefix | Meaning | Action Required |
|-------|--------|---------|-----------------|
| **INFO** | `[WRAPPER-INFO]` | Normal operation | None |
| **DEBUG** | `[WRAPPER-DEBUG]` | Detailed state information | None (troubleshooting only) |
| **WARNING** | `[WRAPPER-WARN]` | Potential issue, but operation continues | Review if frequent |
| **ERROR** | `[WRAPPER-ERROR]` | Critical error, operation may fail | Investigate immediately |

---

## Initialization Phase

### Wrapper Startup

```
[WRAPPER-INFO] ==================================================
[WRAPPER-INFO] SCUM Server Graceful Shutdown Wrapper v3.0
[WRAPPER-INFO] Wrapper PID: 12345
[WRAPPER-INFO] ==================================================
```
**Meaning:** Wrapper started successfully  
**Action:** None  
**Context:** First messages in every log file

---

### Windows API Loading

```
[WRAPPER-INFO] Windows API loaded successfully
```
**Meaning:** Ctrl+C signal support enabled via Windows kernel32.dll  
**Action:** None  
**Context:** Best case - full signal support available

```
[WRAPPER-WARN] Failed to load Windows API: <error details>
[WRAPPER-WARN] Will use fallback method (CloseMainWindow)
```
**Meaning:** API loading failed, using fallback signal method  
**Action:** None (automatic fallback)  
**Context:** Less reliable but functional  
**Note:** May occur on some Windows configurations

---

### PID File Management

```
[WRAPPER-INFO] Created PID file: scum_server.pid
```
**Meaning:** Singleton enforcement active, PID file created  
**Action:** None  
**Context:** Normal startup

```
[WRAPPER-WARN] Removing stale PID file (age: X.X min)
```
**Meaning:** Old PID file found and removed  
**Action:** None (automatic cleanup)  
**Context:** Previous wrapper crashed or was killed  
**Note:** Files older than 5 minutes are considered stale

```
[WRAPPER-WARN] Removing corrupted PID file
```
**Meaning:** PID file contains invalid JSON  
**Action:** None (automatic cleanup)  
**Context:** File corruption or manual editing

```
[WRAPPER-ERROR] ERROR: Another instance is running (PID: 12345)
[WRAPPER-ERROR] If this is incorrect, delete: scum_server.pid
```
**Meaning:** Singleton violation - another wrapper is running  
**Action:** Verify process exists, delete PID file if stale  
**Context:** Prevents duplicate server instances  
**Exit Code:** 1

---

### Event Handler Registration

```
[WRAPPER-INFO] Registered cleanup event handler
```
**Meaning:** Crash recovery system enabled  
**Action:** None  
**Context:** Ensures PID file cleanup even if wrapper crashes

---

## Pre-Start Check Phase

### No Orphans (Clean Start)

```
[WRAPPER-DEBUG] Pre-start check: Scanning for existing SCUM processes...
[WRAPPER-DEBUG] Pre-start check: No existing processes found - clear to start
```
**Meaning:** No orphan processes detected  
**Action:** None  
**Context:** Ideal startup condition

---

### Orphan Detection and Cleanup

```
[WRAPPER-WARN] Pre-start check: Found 2 existing SCUM process(es)
[WRAPPER-WARN] Pre-start check: Terminating existing PID: 12345
[WRAPPER-DEBUG] Pre-start check: Successfully terminated PID: 12345
[WRAPPER-WARN] Pre-start check: Terminating existing PID: 67890
[WRAPPER-DEBUG] Pre-start check: Successfully terminated PID: 67890
```
**Meaning:** Orphan processes found and terminated  
**Action:** None (automatic cleanup)  
**Context:** Previous server didn't terminate cleanly  
**Note:** Common after crashes or manual kills

```
[WRAPPER-DEBUG] Pre-start check: Waiting for process cleanup (5s)...
```
**Meaning:** Waiting for processes to fully release resources  
**Action:** None  
**Context:** Prevents race conditions and port conflicts

```
[WRAPPER-DEBUG] Pre-start check: All processes terminated successfully
```
**Meaning:** Orphan cleanup successful, ready to start  
**Action:** None  
**Context:** Verification passed

```
[WRAPPER-ERROR] Pre-start check: WARNING - 1 process(es) still running!
```
**Meaning:** Orphan cleanup failed, processes still exist  
**Action:** Investigate stuck processes manually  
**Context:** Process may be hung or protected  
**Note:** New server start will likely fail with port conflict

```
[WRAPPER-ERROR] Pre-start check: Failed to terminate PID 12345: <error>
```
**Meaning:** Unable to kill specific process  
**Action:** Check process permissions, kill manually if needed  
**Context:** Process may be protected or system-level

---

## Server Startup Phase

### Executable Validation

```
[WRAPPER-ERROR] ERROR: Server executable not found: <path>
```
**Meaning:** SCUMServer.exe not found at expected location  
**Action:** Verify server installation, check file path  
**Context:** Critical error, cannot start server  
**Exit Code:** 1

---

### Process Launch

```
[WRAPPER-INFO] Executable: <path>\SCUMServer.exe
[WRAPPER-INFO] Arguments: Port=7042 QueryPort=7043 MaxPlayers=64
[WRAPPER-INFO] --------------------------------------------------
[WRAPPER-INFO] Starting SCUM Server...
```
**Meaning:** Server launch initiated with specified parameters  
**Action:** None  
**Context:** Normal startup sequence

```
[WRAPPER-ERROR] ERROR: Failed to start process
```
**Meaning:** Process creation failed  
**Action:** Check permissions, disk space, system resources  
**Context:** Critical error  
**Exit Code:** 1

```
[WRAPPER-INFO] Server started successfully
[WRAPPER-INFO] SCUM Server PID: 12345
[WRAPPER-DEBUG] Wrapper PID: 67890
```
**Meaning:** Server process launched successfully  
**Action:** None  
**Context:** Server is now running

```
[WRAPPER-DEBUG] PID file updated with server PID: 12345
```
**Meaning:** PID file updated with server process ID  
**Action:** None  
**Context:** Process tracking active

```
[WRAPPER-WARN] Failed to update PID file: <error>
```
**Meaning:** Unable to update PID file with server PID  
**Action:** Check file permissions  
**Context:** Non-critical, server continues running  
**Note:** May affect singleton enforcement

---

### Runtime Monitoring

```
[WRAPPER-INFO] State: RUNNING - Monitoring process...
[WRAPPER-INFO] --------------------------------------------------
```
**Meaning:** Server running normally, wrapper monitoring  
**Action:** None  
**Context:** Normal operation state

---

## Shutdown Phase

### Shutdown Initiation

```
[WRAPPER-DEBUG] State: SHUTDOWN_REQUESTED - Checking server uptime...
```
**Meaning:** AMP sent stop signal, analyzing shutdown strategy  
**Action:** None  
**Context:** Shutdown sequence started

```
[WRAPPER-INFO] Server uptime: 5.23 min (313.8s)
```
**Meaning:** Server runtime before shutdown  
**Action:** None  
**Context:** Used to determine abort vs graceful mode  
**Note:** < 30s = abort mode, ≥ 30s = graceful mode

---

### Abort Mode (< 30 seconds uptime)

```
[WRAPPER-WARN] Server in startup phase (< 30s) - ABORT MODE
[WRAPPER-DEBUG] State: FORCE_KILL - Terminating PID 12345...
[WRAPPER-DEBUG] Process killed (startup abort)
[WRAPPER-WARN] Shutdown completed (startup abort, force killed)
```
**Meaning:** Server killed immediately during startup phase  
**Action:** None  
**Context:** Safe - no player data to save  
**Data Integrity:** ✓ Safe (no data)

---

### Graceful Mode (≥ 30 seconds uptime)

```
[WRAPPER-INFO] Server is running - GRACEFUL SHUTDOWN MODE
[WRAPPER-DEBUG] State: SENDING_SHUTDOWN_SIGNAL
```
**Meaning:** Using graceful shutdown with save confirmation  
**Action:** None  
**Context:** Server has potential player data

---

### Signal Sending

```
[WRAPPER-INFO] Sending Ctrl+C to PID 12345...
[WRAPPER-INFO] Ctrl+C sent via API
[WRAPPER-DEBUG] Ctrl+C signal sent to PID 12345
```
**Meaning:** Shutdown signal delivered successfully via Windows API  
**Action:** None  
**Context:** Best case - reliable signal delivery

```
[WRAPPER-INFO] Sending Ctrl+C to PID 12345...
[WRAPPER-INFO] Trying CloseMainWindow fallback...
[WRAPPER-INFO] CloseMainWindow sent
```
**Meaning:** Shutdown signal delivered via fallback method  
**Action:** None  
**Context:** API unavailable, using alternative method

```
[WRAPPER-WARN] CloseMainWindow failed: <error>
```
**Meaning:** Fallback signal method also failed  
**Action:** None (automatic force kill)  
**Context:** Will trigger signal failed path

---

### LogExit Monitoring

```
[WRAPPER-DEBUG] State: WAITING_FOR_LOGEXIT - Monitoring log file...
```
**Meaning:** Monitoring SCUM.log for save confirmation  
**Action:** None  
**Context:** Waiting for "LogExit: Exiting" pattern

```
[WRAPPER-DEBUG] Still waiting for LogExit... (10s/30s)
[WRAPPER-DEBUG] Still waiting for LogExit... (20s/30s)
```
**Meaning:** Progress updates during wait  
**Action:** None  
**Context:** Logged every 10 seconds  
**Note:** Normal for large saves

```
[WRAPPER-DEBUG] LogExit pattern detected! Server saved successfully.
```
**Meaning:** ✓ Save confirmation received  
**Action:** None  
**Context:** Best case - data integrity confirmed  
**Data Integrity:** ✓ 100% Safe

---

### Shutdown Completion - Success Cases

```
[WRAPPER-DEBUG] State: SHUTDOWN_COMPLETE - Graceful shutdown confirmed (8s)
[WRAPPER-INFO] Shutdown completed successfully in 8.2s (graceful, LogExit detected)
```
**Meaning:** ✓ Perfect shutdown with save confirmation  
**Action:** None  
**Context:** Ideal shutdown  
**Data Integrity:** ✓ 100% Safe  
**Typical Time:** 5-15 seconds

---

### Shutdown Completion - Warning Cases

```
[WRAPPER-WARN] State: SHUTDOWN_COMPLETE - Process exited but LogExit not detected (5s)
[WRAPPER-WARN] Shutdown completed in 5.1s (process exited, no LogExit)
```
**Meaning:** ⚠ Process exited but no save confirmation  
**Action:** Check server logs for errors  
**Context:** Uncertain data integrity  
**Data Integrity:** ⚠ Possibly unsafe  
**Possible Causes:**
- Server crashed during shutdown
- Save completed but log not written
- Log file locked/inaccessible

---

### Shutdown Completion - Error Cases

```
[WRAPPER-ERROR] State: FAILSAFE_TIMEOUT - No LogExit after 30s!
[WRAPPER-ERROR] Assuming server frozen/crashed - Force killing PID 12345...
[WRAPPER-WARN] Process killed (failsafe timeout)
[WRAPPER-WARN] Shutdown completed in 30.5s (failsafe timeout, force killed)
```
**Meaning:** ✗ Server didn't respond within timeout  
**Action:** Investigate server stability, check for crashes  
**Context:** Failsafe activated to prevent hung shutdown  
**Data Integrity:** ✗ Risk of corruption  
**Possible Causes:**
- Server frozen/deadlocked
- Extremely large save (> 30s)
- Disk I/O bottleneck
- Server crash during save

```
[WRAPPER-ERROR] State: SIGNAL_FAILED - Ctrl+C failed, force killing...
[WRAPPER-WARN] Process killed (signal failed)
[WRAPPER-WARN] Shutdown completed (signal failed, force killed)
```
**Meaning:** ✗ Unable to send shutdown signal  
**Action:** Check Windows API status, verify process state  
**Context:** Signal delivery failed  
**Data Integrity:** ✗ Risk of corruption  
**Possible Causes:**
- Process already exiting
- Process in unresponsive state
- Windows API failure

---

### Shutdown Errors

```
[WRAPPER-ERROR] Error during shutdown: <error details>
```
**Meaning:** Unexpected error during shutdown sequence  
**Action:** Review error details, check system logs  
**Context:** Wrapper will attempt force kill as last resort

---

## Cleanup Phase

### PID File Cleanup

```
[WRAPPER-INFO] Cleaned up PID file
```
**Meaning:** PID file removed successfully  
**Action:** None  
**Context:** Normal cleanup

```
[INFO] Event handler cleaned up PID file
```
**Meaning:** Crash recovery handler removed PID file  
**Action:** None  
**Context:** Wrapper crashed or was killed  
**Note:** Different format (no WRAPPER prefix) because it runs in event handler

---

### Wrapper Exit

```
[WRAPPER-INFO] Wrapper exiting
[WRAPPER-INFO] ==================================================
```
**Meaning:** Wrapper terminating normally  
**Action:** None  
**Context:** End of log session

```
[WRAPPER-INFO] Process exited. Code: 0
```
**Meaning:** Server exited with code 0 (normal exit)  
**Action:** None  
**Context:** Clean server shutdown

```
[WRAPPER-INFO] Process exited. Code: 1
```
**Meaning:** Server exited with error code  
**Action:** Check server logs for error details  
**Context:** Server crash or error

---

## Error Messages

### Critical Errors (Exit Code 1)

```
[WRAPPER-ERROR] ERROR: Server executable not found: <path>
```
**Cause:** SCUMServer.exe missing  
**Solution:** Verify server installation

```
[WRAPPER-ERROR] ERROR: Failed to start process
```
**Cause:** Process creation failed  
**Solution:** Check permissions, resources, disk space

```
[WRAPPER-ERROR] ERROR: Another instance is running (PID: 12345)
```
**Cause:** Singleton violation  
**Solution:** Verify process exists, delete stale PID file if needed

```
[WRAPPER-ERROR] ERROR: <unexpected error>
```
**Cause:** Unhandled exception  
**Solution:** Review error details, check system logs

---

## Log Analysis Tips

### Identifying Shutdown Type

Look for these patterns:

**✓ Perfect Shutdown:**
```
Server uptime: X.XX min (XXXs)
Server is running - GRACEFUL SHUTDOWN MODE
Ctrl+C signal sent to PID X
LogExit pattern detected! Server saved successfully.
Shutdown completed successfully in X.Xs (graceful, LogExit detected)
```

**⚠ Uncertain Shutdown:**
```
Server uptime: X.XX min (XXXs)
Server is running - GRACEFUL SHUTDOWN MODE
Ctrl+C signal sent to PID X
Shutdown completed in X.Xs (process exited, no LogExit)
```

**✗ Failed Shutdown:**
```
Server uptime: X.XX min (XXXs)
Server is running - GRACEFUL SHUTDOWN MODE
Ctrl+C signal sent to PID X
State: FAILSAFE_TIMEOUT - No LogExit after 30s!
Shutdown completed in 30.Xs (failsafe timeout, force killed)
```

**✓ Startup Abort:**
```
Server uptime: X.XX min (XXXs)
Server in startup phase (< 30s) - ABORT MODE
Shutdown completed (startup abort, force killed)
```

---

### Tracking Shutdown Performance

Extract shutdown times:
```powershell
Get-Content "Logs\SCUMWrapper_*.log" | 
    Select-String "Shutdown completed" | 
    Select-Object -Last 10
```

Analyze patterns:
- **< 10s:** Excellent
- **10-20s:** Good
- **20-25s:** Acceptable
- **25-30s:** Slow (investigate)
- **30s+:** Failsafe timeout (problem)

---

### Finding Errors

```powershell
# All errors
Get-Content "Logs\SCUMWrapper_*.log" | Select-String "ERROR"

# All warnings
Get-Content "Logs\SCUMWrapper_*.log" | Select-String "WARN"

# Failed shutdowns
Get-Content "Logs\SCUMWrapper_*.log" | Select-String "failsafe|signal failed"

# Orphan cleanups
Get-Content "Logs\SCUMWrapper_*.log" | Select-String "orphan|existing SCUM"
```

---

## State Transition Diagram

```
INITIALIZING
    ↓
PRE_START_CHECK (orphan cleanup)
    ↓
STARTING (launch SCUMServer.exe)
    ↓
RUNNING (monitor process)
    ↓
SHUTDOWN_REQUESTED (AMP sends Ctrl+C)
    ↓
    ├─→ ABORT_MODE (uptime < 30s)
    │       ↓
    │   FORCE_KILL
    │       ↓
    │   CLEANUP
    │
    └─→ GRACEFUL_MODE (uptime ≥ 30s)
            ↓
        SENDING_SHUTDOWN_SIGNAL
            ↓
            ├─→ SIGNAL_FAILED
            │       ↓
            │   FORCE_KILL
            │
            └─→ WAITING_FOR_LOGEXIT
                    ↓
                    ├─→ LOGEXIT_DETECTED
                    │       ↓
                    │   SHUTDOWN_COMPLETE
                    │
                    ├─→ PROCESS_EXITED (no LogExit)
                    │       ↓
                    │   SHUTDOWN_COMPLETE (warning)
                    │
                    └─→ FAILSAFE_TIMEOUT (30s)
                            ↓
                        FORCE_KILL
                            ↓
                        SHUTDOWN_COMPLETE (error)
```

---

## Log File Locations

| Log Type | Location | Purpose |
|----------|----------|---------|
| Wrapper Logs | `Binaries/Win64/Logs/SCUMWrapper_YYYY-MM-DD.log` | Process management, shutdown decisions |
| Server Logs | `Saved/Logs/SCUM.log` | Game events, LogExit pattern |
| PID File | `Binaries/Win64/scum_server.pid` | Singleton enforcement |

---

## Log Retention

- **Wrapper logs:** Automatically deleted after 7 days
- **Server logs:** Managed by SCUM server (not wrapper)
- **PID file:** Deleted on wrapper exit (or by event handler)

---

## Getting More Information

For detailed troubleshooting, see: `TROUBLESHOOTING.md`

For wrapper configuration, see: `SCUMWrapper.ps1` (inline documentation)
