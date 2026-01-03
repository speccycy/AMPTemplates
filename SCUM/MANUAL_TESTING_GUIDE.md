# SCUM AMP Graceful Shutdown - Manual Testing Guide

## Overview

This guide provides step-by-step instructions for manually testing all critical scenarios of the SCUM AMP Graceful Shutdown System. Each test validates specific requirements and ensures the wrapper behaves correctly in production environments.

**Version:** 3.0  
**Date:** January 2, 2026  
**Prerequisites:** 
- SCUM Dedicated Server installed
- CubeCoders AMP configured with scum.kvp
- PowerShell 5.1 or higher
- Administrator access to server

---

## Test Environment Setup

### 1. Verify AMP Configuration

Before running tests, ensure `scum.kvp` is configured correctly:

```kvp
App.ExitMethod=OS_CLOSE
App.ExitMethodWindows=CtrlC
App.ExitTimeout=35
```

**Why:** These settings ensure AMP sends Ctrl+C signals instead of force killing the wrapper.

### 2. Enable Verbose Logging

The wrapper automatically logs to:
- **Console:** Visible in AMP console
- **File:** `Binaries/Win64/Logs/SCUMWrapper_YYYY-MM-DD.log`

**Tip:** Keep a PowerShell window open with `Get-Content` to tail the log file:
```powershell
Get-Content "Binaries\Win64\Logs\SCUMWrapper_$(Get-Date -Format 'yyyy-MM-dd').log" -Wait -Tail 50
```

### 3. Prepare Test Checklist

Print or keep this document open to check off each test as you complete it.

---

## Test Scenarios

### Test 1: Normal Stop After 5 Minutes (Graceful Shutdown)

**Objective:** Verify graceful shutdown with LogExit detection after server has been running for sufficient time.

**Requirements Validated:** 1.1, 1.2, 1.3, 5.7, 9.2

**Steps:**

1. **Start the server via AMP:**
   - Click "Start" button in AMP console
   - Wait for server to fully initialize (status shows "Running")

2. **Wait 5 minutes:**
   - Let server run for at least 5 minutes to ensure it's past startup phase
   - Verify server is accepting connections (optional)

3. **Stop the server via AMP:**
   - Click "Stop" button in AMP console
   - Observe console output

4. **Expected Results:**
   ```
   [WRAPPER-INFO] Server uptime: 5.XX min (3XX.Xs)
   [WRAPPER-INFO] Server is running - GRACEFUL SHUTDOWN MODE
   [WRAPPER-DEBUG] Ctrl+C signal sent to PID XXXXX
   [WRAPPER-DEBUG] State: WAITING_FOR_LOGEXIT - Monitoring log file...
   [WRAPPER-DEBUG] LogExit pattern detected! Server saved successfully.
   [WRAPPER-INFO] Shutdown completed successfully in X.Xs (graceful, LogExit detected)
   ```

5. **Verification Checklist:**
   - [ ] Wrapper logged server uptime in minutes and seconds
   - [ ] "GRACEFUL SHUTDOWN MODE" message appeared
   - [ ] Ctrl+C signal was sent (logged)
   - [ ] LogExit pattern was detected within 30 seconds
   - [ ] "Shutdown completed successfully" message appeared
   - [ ] No force kill occurred
   - [ ] PID file was removed (`scum_server.pid` does not exist)
   - [ ] Server status in AMP shows "Stopped"

6. **Check SCUM.log:**
   - Open `Saved/Logs/SCUM.log`
   - Verify last lines contain: `LogExit: Exiting. Log file closed`

**Pass Criteria:** All checkboxes checked, LogExit pattern found, no errors in logs.

---

### Test 2: Quick Stop Within 30 Seconds (Startup Abort)

**Objective:** Verify immediate force kill when server is stopped during startup phase.

**Requirements Validated:** 2.1, 2.2, 2.4

**Steps:**

1. **Start the server via AMP:**
   - Click "Start" button in AMP console
   - Immediately observe console output

2. **Stop within 30 seconds:**
   - Within 10-20 seconds of starting, click "Stop" button
   - Observe console output

3. **Expected Results:**
   ```
   [WRAPPER-INFO] Server uptime: 0.XX min (XX.Xs)
   [WRAPPER-WARN] Server in startup phase (< 30s) - ABORT MODE
   [WRAPPER-DEBUG] State: FORCE_KILL - Terminating PID XXXXX...
   [WRAPPER-DEBUG] Process killed (startup abort)
   [WRAPPER-WARN] Shutdown completed (startup abort, force killed)
   ```

4. **Verification Checklist:**
   - [ ] Wrapper logged uptime < 30 seconds
   - [ ] "ABORT MODE" message appeared
   - [ ] Process was force killed immediately
   - [ ] No Ctrl+C signal was sent
   - [ ] No LogExit monitoring occurred
   - [ ] Shutdown completed in < 1 second
   - [ ] PID file was removed
   - [ ] Server status in AMP shows "Stopped"

**Pass Criteria:** All checkboxes checked, no graceful shutdown attempt, immediate termination.

---

### Test 3: Scheduled Restart (Graceful → New Instance)

**Objective:** Verify graceful shutdown followed by automatic restart without race conditions.

**Requirements Validated:** 1.1, 1.2, 1.3, 3.1, 3.2, 3.3, 6.1, 6.2

**Steps:**

1. **Start the server via AMP:**
   - Click "Start" button
   - Wait for server to fully initialize (5+ minutes)

2. **Schedule a restart:**
   - In AMP, click "Restart" button
   - Observe console output carefully

3. **Expected Results (Shutdown Phase):**
   ```
   [WRAPPER-INFO] Server is running - GRACEFUL SHUTDOWN MODE
   [WRAPPER-DEBUG] Ctrl+C signal sent to PID XXXXX
   [WRAPPER-DEBUG] LogExit pattern detected! Server saved successfully.
   [WRAPPER-INFO] Shutdown completed successfully in X.Xs (graceful, LogExit detected)
   [WRAPPER-INFO] Cleaned up PID file
   [WRAPPER-INFO] Wrapper exiting
   ```

4. **Expected Results (Startup Phase):**
   ```
   [WRAPPER-INFO] SCUM Server Graceful Shutdown Wrapper v3.0
   [WRAPPER-DEBUG] Pre-start check: Scanning for existing SCUM processes...
   [WRAPPER-DEBUG] Pre-start check: No existing processes found - clear to start
   [WRAPPER-INFO] Created PID file: ...
   [WRAPPER-INFO] Server started successfully
   [WRAPPER-INFO] SCUM Server PID: XXXXX
   ```

5. **Verification Checklist:**
   - [ ] Old instance shut down gracefully with LogExit
   - [ ] PID file was cleaned up
   - [ ] Pre-start check found no orphan processes
   - [ ] New instance started successfully
   - [ ] New PID file was created
   - [ ] No "port already in use" errors
   - [ ] No file locking errors
   - [ ] Server status in AMP shows "Running" after restart

**Pass Criteria:** Clean shutdown → Clean startup with no race conditions or errors.

---

### Test 4: Orphan Process Recovery

**Objective:** Verify wrapper detects and terminates orphan processes before starting new instance.

**Requirements Validated:** 3.1, 3.2, 3.3, 3.4, 3.5

**Steps:**

1. **Create an orphan process:**
   - Manually start `SCUMServer.exe` directly (not via AMP)
   - Or start via AMP, then kill the wrapper process (not the server)
   - Verify `SCUMServer.exe` is running in Task Manager

2. **Start server via AMP:**
   - Click "Start" button in AMP console
   - Observe console output

3. **Expected Results:**
   ```
   [WRAPPER-DEBUG] Pre-start check: Scanning for existing SCUM processes...
   [WRAPPER-WARN] Pre-start check: Found 1 existing SCUM process(es)
   [WRAPPER-WARN] Pre-start check: Terminating existing PID: XXXXX
   [WRAPPER-DEBUG] Pre-start check: Successfully terminated PID: XXXXX
   [WRAPPER-DEBUG] Pre-start check: Waiting for process cleanup (5s)...
   [WRAPPER-DEBUG] Pre-start check: All processes terminated successfully
   [WRAPPER-INFO] Server started successfully
   ```

4. **Verification Checklist:**
   - [ ] Wrapper detected existing SCUM process(es)
   - [ ] Each orphan PID was logged
   - [ ] Wrapper terminated all orphan processes
   - [ ] Wrapper waited 5 seconds for cleanup
   - [ ] Wrapper verified all processes were gone
   - [ ] New server instance started successfully
   - [ ] No port conflicts occurred

5. **Test Variation - Multiple Orphans:**
   - Start 2-3 `SCUMServer.exe` instances manually
   - Verify wrapper terminates all of them

**Pass Criteria:** All orphan processes terminated, new instance starts cleanly.

---

### Test 5: Duplicate Wrapper Prevention

**Objective:** Verify singleton enforcement prevents multiple wrapper instances.

**Requirements Validated:** 4.2, 4.3

**Steps:**

1. **Start first wrapper instance:**
   - Start server via AMP
   - Verify server is running
   - Note the wrapper PID from logs

2. **Attempt to start second wrapper:**
   - Open PowerShell as Administrator
   - Navigate to `Binaries/Win64/`
   - Run: `.\SCUMWrapper.ps1 Port=7042`

3. **Expected Results (Second Wrapper):**
   ```
   [WRAPPER-ERROR] ERROR: Another instance is running (PID: XXXXX)
   [WRAPPER-ERROR] If this is incorrect, delete: ...\scum_server.pid
   ```

4. **Verification Checklist:**
   - [ ] Second wrapper detected existing PID file
   - [ ] Second wrapper verified first wrapper is still running
   - [ ] Second wrapper exited with error code 1
   - [ ] Second wrapper did NOT start a new server
   - [ ] First wrapper continued running normally
   - [ ] Only one `SCUMServer.exe` process exists

5. **Test Variation - Stale PID File:**
   - Stop the server via AMP
   - Manually create a fake PID file with old timestamp (> 5 min)
   - Start server via AMP
   - Verify wrapper removes stale PID file and starts normally

**Pass Criteria:** Second wrapper exits with error, first wrapper unaffected.

---

### Test 6: Failsafe Timeout (Force Kill After 30s)

**Objective:** Verify failsafe timeout force kills server if LogExit doesn't appear.

**Requirements Validated:** 1.4, 1.5

**Steps:**

1. **Simulate frozen server:**
   - Start server via AMP
   - Wait for server to fully initialize (5+ minutes)
   - **Before stopping:** Rename or delete `Saved/Logs/SCUM.log` to prevent LogExit detection
     ```powershell
     Rename-Item "Saved\Logs\SCUM.log" "SCUM.log.backup"
     ```

2. **Stop the server via AMP:**
   - Click "Stop" button
   - Observe console output
   - Wait for 30+ seconds

3. **Expected Results:**
   ```
   [WRAPPER-INFO] Server is running - GRACEFUL SHUTDOWN MODE
   [WRAPPER-DEBUG] Ctrl+C signal sent to PID XXXXX
   [WRAPPER-DEBUG] State: WAITING_FOR_LOGEXIT - Monitoring log file...
   [WRAPPER-DEBUG] Still waiting for LogExit... (10/30s)
   [WRAPPER-DEBUG] Still waiting for LogExit... (20/30s)
   [WRAPPER-ERROR] State: FAILSAFE_TIMEOUT - No LogExit after 30s!
   [WRAPPER-ERROR] Assuming server frozen/crashed - Force killing PID XXXXX...
   [WRAPPER-WARN] Process killed (failsafe timeout)
   [WRAPPER-WARN] Shutdown completed in 30.Xs (failsafe timeout, force killed)
   ```

4. **Verification Checklist:**
   - [ ] Wrapper sent Ctrl+C signal
   - [ ] Wrapper monitored log file for 30 seconds
   - [ ] Progress messages appeared every 10 seconds
   - [ ] "FAILSAFE_TIMEOUT" error appeared after 30s
   - [ ] Wrapper force killed the process
   - [ ] Shutdown completed with "failsafe timeout" reason
   - [ ] PID file was cleaned up

5. **Cleanup:**
   - Restore the log file: `Rename-Item "SCUM.log.backup" "SCUM.log"`

**Pass Criteria:** Failsafe activated after 30s, process force killed, proper logging.

---

### Test 7: Log File Rotation (7-Day Retention)

**Objective:** Verify automatic deletion of log files older than 7 days.

**Requirements Validated:** 5.9

**Steps:**

1. **Create old log files:**
   ```powershell
   cd Binaries\Win64\Logs
   
   # Create log files with old dates
   $oldDate1 = (Get-Date).AddDays(-8)
   $oldDate2 = (Get-Date).AddDays(-10)
   $recentDate = (Get-Date).AddDays(-3)
   
   "Test log 1" | Out-File "SCUMWrapper_$($oldDate1.ToString('yyyy-MM-dd')).log"
   "Test log 2" | Out-File "SCUMWrapper_$($oldDate2.ToString('yyyy-MM-dd')).log"
   "Test log 3" | Out-File "SCUMWrapper_$($recentDate.ToString('yyyy-MM-dd')).log"
   
   # Set file timestamps to match
   (Get-Item "SCUMWrapper_$($oldDate1.ToString('yyyy-MM-dd')).log").LastWriteTime = $oldDate1
   (Get-Item "SCUMWrapper_$($oldDate2.ToString('yyyy-MM-dd')).log").LastWriteTime = $oldDate2
   (Get-Item "SCUMWrapper_$($recentDate.ToString('yyyy-MM-dd')).log").LastWriteTime = $recentDate
   ```

2. **Start the wrapper:**
   - Start server via AMP
   - Wrapper runs log rotation on startup

3. **Verify log cleanup:**
   ```powershell
   Get-ChildItem Binaries\Win64\Logs\SCUMWrapper_*.log | Select-Object Name, LastWriteTime
   ```

4. **Expected Results:**
   - Old log files (8+ days) are deleted
   - Recent log files (< 7 days) are preserved
   - Current day's log file exists

5. **Verification Checklist:**
   - [ ] Log files older than 7 days were deleted
   - [ ] Log files newer than 7 days were preserved
   - [ ] Current log file was created/updated
   - [ ] No errors during log rotation

**Pass Criteria:** Old logs deleted, recent logs preserved, no errors.

---

### Test 8: Exit Code Propagation

**Objective:** Verify wrapper exits with same code as server process.

**Requirements Validated:** 8.1, 8.2, 8.3

**Steps:**

1. **Test normal exit (code 0):**
   - Start server via AMP
   - Wait 5+ minutes
   - Stop server via AMP (graceful shutdown)
   - Check wrapper exit code in AMP logs

2. **Test crash simulation:**
   - Start server via AMP
   - Wait 5+ minutes
   - Manually kill `SCUMServer.exe` via Task Manager
   - Check wrapper exit code

3. **Expected Results:**
   - Normal shutdown: Wrapper exits with code 0
   - Crash: Wrapper exits with server's exit code (non-zero)
   - Pre-start error: Wrapper exits with code 1

4. **Verification Checklist:**
   - [ ] Normal shutdown: Exit code 0
   - [ ] Server crash: Exit code matches server's code
   - [ ] Singleton violation: Exit code 1
   - [ ] Missing executable: Exit code 1

**Pass Criteria:** Exit codes propagate correctly to AMP.

---

## Test Results Summary

### Test Execution Checklist

Mark each test as you complete it:

- [ ] **Test 1:** Normal Stop After 5 Minutes (Graceful Shutdown)
- [ ] **Test 2:** Quick Stop Within 30 Seconds (Startup Abort)
- [ ] **Test 3:** Scheduled Restart (Graceful → New Instance)
- [ ] **Test 4:** Orphan Process Recovery
- [ ] **Test 5:** Duplicate Wrapper Prevention
- [ ] **Test 6:** Failsafe Timeout (Force Kill After 30s)
- [ ] **Test 7:** Log File Rotation (7-Day Retention)
- [ ] **Test 8:** Exit Code Propagation

### Overall Pass Criteria

All tests must pass with:
- ✅ No unexpected errors in logs
- ✅ All expected log messages present
- ✅ Correct behavior in all scenarios
- ✅ No data corruption or file locking issues
- ✅ Clean PID file management
- ✅ Proper exit code propagation

---

## Troubleshooting

### Common Issues

**Issue:** "Another instance is running" error when no wrapper is running
- **Cause:** Stale PID file from crashed wrapper
- **Fix:** Delete `Binaries/Win64/scum_server.pid` manually

**Issue:** Failsafe timeout always triggers
- **Cause:** SCUM.log path incorrect or log file not being written
- **Fix:** Verify log file exists at `Saved/Logs/SCUM.log`

**Issue:** Orphan processes not detected
- **Cause:** Process name mismatch
- **Fix:** Verify process is named exactly "SCUMServer" in Task Manager

**Issue:** Graceful shutdown not working
- **Cause:** AMP configuration incorrect
- **Fix:** Verify `scum.kvp` has `App.ExitMethodWindows=CtrlC`

### Log Analysis

**Key log patterns to look for:**

✅ **Successful graceful shutdown:**
```
Server is running - GRACEFUL SHUTDOWN MODE
Ctrl+C signal sent to PID XXXXX
LogExit pattern detected! Server saved successfully.
Shutdown completed successfully
```

❌ **Failsafe timeout (server frozen):**
```
FAILSAFE_TIMEOUT - No LogExit after 30s!
Assuming server frozen/crashed - Force killing
Process killed (failsafe timeout)
```

⚠️ **Startup abort (quick stop):**
```
Server in startup phase (< 30s) - ABORT MODE
Process killed (startup abort)
```

---

## Conclusion

After completing all tests, you should have confidence that:

1. ✅ Graceful shutdown works reliably with LogExit detection
2. ✅ Startup abort prevents wasted time on incomplete startups
3. ✅ Orphan cleanup prevents race conditions and port conflicts
4. ✅ Singleton enforcement prevents duplicate instances
5. ✅ Failsafe timeout prevents hung shutdowns
6. ✅ Log rotation prevents disk space exhaustion
7. ✅ Exit codes propagate correctly to AMP
8. ✅ All log messages are present and accurate

**Next Steps:**
- Document any failures or unexpected behavior
- Review logs for any warnings or errors
- Proceed to production deployment if all tests pass

**Support:**
- Review `TROUBLESHOOTING.md` for detailed error resolution
- Review `LOG_MESSAGES.md` for log message reference
- Check AMP forums for community support

