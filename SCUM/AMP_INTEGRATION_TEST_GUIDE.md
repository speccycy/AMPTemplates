# SCUM AMP Integration Test Guide

**Purpose:** Verify that the SCUM wrapper integrates correctly with CubeCoders AMP in all operational scenarios.

**Prerequisites:**
- AMP instance configured with SCUM template
- SCUM server files installed via SteamCMD
- `SCUMWrapper.ps1` v3.0 deployed to `SCUM/Binaries/Win64/`
- PowerShell 5.1 or higher available
- Administrator access to AMP panel

## Test Environment Setup

### 1. Verify Template Configuration

Before testing, confirm the following in AMP:

1. Navigate to your SCUM instance
2. Go to **Configuration** → **Application Configuration**
3. Verify these settings exist in the raw KVP:
   - `App.ExitMethodWindows=CtrlC`
   - `App.ExitTimeout=35`
   - `App.ExecutableWin=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`

### 2. Enable Debug Logging

To see detailed wrapper logs in AMP console:

1. Open `SCUMWrapper.ps1` in a text editor
2. Ensure `$DebugMode = $true` (should be default)
3. Save the file

### 3. Prepare Monitoring Tools

Open these tools to monitor during tests:

1. **AMP Console:** Shows real-time wrapper and server logs
2. **Task Manager:** Shows process list (filter for "SCUM" and "powershell")
3. **File Explorer:** Navigate to `SCUM/Binaries/Win64/` to watch PID file
4. **Log Viewer:** Open `SCUM/Binaries/Win64/Logs/` to view wrapper logs

## Test Scenarios

### Test 1: Start Button (Normal Startup)

**Objective:** Verify the wrapper correctly starts the SCUM server via AMP.

**Steps:**
1. Ensure server is stopped (no SCUM processes running)
2. Click **Start** button in AMP
3. Monitor AMP console for wrapper logs

**Expected Results:**
- ✅ AMP console shows: `[WRAPPER-INFO] SCUMWrapper v3.0 starting...`
- ✅ AMP console shows: `[WRAPPER-INFO] Wrapper PID: XXXXX`
- ✅ AMP console shows: `[WRAPPER-DEBUG] Pre-start check: Found 0 existing SCUM process(es)`
- ✅ AMP console shows: `[WRAPPER-INFO] SCUM Server PID: XXXXX`
- ✅ AMP console shows: `[WRAPPER-DEBUG] State: RUNNING - Monitoring process...`
- ✅ AMP status changes to "Running" (green)
- ✅ Task Manager shows 2 processes: `powershell.exe` (wrapper) and `SCUMServer.exe`
- ✅ PID file created: `SCUM/Binaries/Win64/scum_server.pid`
- ✅ PID file contains valid JSON with wrapper PID, server PID, and timestamp

**Pass Criteria:**
- Server starts successfully
- Wrapper logs appear in AMP console
- PID file created and valid
- No error messages

**Failure Indicators:**
- Server fails to start
- No wrapper logs in console
- PID file not created
- Error: "Another wrapper instance is already running"

---

### Test 2: Stop Button (Graceful Shutdown - Normal)

**Objective:** Verify graceful shutdown works when server has been running > 30 seconds.

**Steps:**
1. Start server (Test 1)
2. Wait 60 seconds (ensure uptime > 30s)
3. Click **Stop** button in AMP
4. Monitor AMP console for shutdown sequence

**Expected Results:**
- ✅ AMP console shows: `[WRAPPER-INFO] Shutdown signal received`
- ✅ AMP console shows: `[WRAPPER-INFO] Server uptime: X.XX minutes (XX.X seconds)`
- ✅ AMP console shows: `[WRAPPER-INFO] Server is running - GRACEFUL SHUTDOWN MODE`
- ✅ AMP console shows: `[WRAPPER-INFO] Sending Ctrl+C signal to SCUM server (PID: XXXXX)`
- ✅ AMP console shows: `[WRAPPER-INFO] Monitoring log file for LogExit pattern...`
- ✅ AMP console shows: `[WRAPPER-INFO] LogExit pattern detected! Server saved successfully.`
- ✅ AMP console shows: `[WRAPPER-INFO] Graceful shutdown confirmed - exiting cleanly`
- ✅ AMP console shows: `[WRAPPER-DEBUG] Cleanup: Removing PID file`
- ✅ AMP status changes to "Stopped" (red)
- ✅ Task Manager shows 0 SCUM processes
- ✅ PID file deleted: `SCUM/Binaries/Win64/scum_server.pid` does not exist

**Timing:**
- Shutdown should complete in 5-15 seconds (typical)
- Maximum 35 seconds (if failsafe activates)

**Pass Criteria:**
- LogExit pattern detected
- Clean shutdown (no force kill)
- PID file removed
- No orphan processes

**Failure Indicators:**
- Failsafe timeout activates (indicates server not responding)
- Force kill occurs (indicates Ctrl+C failed)
- PID file remains after shutdown
- Orphan processes in Task Manager

---

### Test 3: Stop Button (Startup Abort)

**Objective:** Verify immediate force kill when stopping during startup phase (< 30 seconds).

**Steps:**
1. Start server (Test 1)
2. **Immediately** click **Stop** button (within 10 seconds)
3. Monitor AMP console for abort sequence

**Expected Results:**
- ✅ AMP console shows: `[WRAPPER-INFO] Shutdown signal received`
- ✅ AMP console shows: `[WRAPPER-INFO] Server uptime: 0.XX minutes (XX.X seconds)`
- ✅ AMP console shows: `[WRAPPER-INFO] Server in startup phase (< 30s) - ABORT MODE`
- ✅ AMP console shows: `[WRAPPER-INFO] Force killing process (PID: XXXXX)`
- ✅ AMP console shows: `[WRAPPER-INFO] Process killed (startup abort)`
- ✅ AMP console shows: `[WRAPPER-DEBUG] Cleanup: Removing PID file`
- ✅ AMP status changes to "Stopped" (red)
- ✅ Task Manager shows 0 SCUM processes
- ✅ PID file deleted

**Timing:**
- Shutdown should complete in < 2 seconds

**Pass Criteria:**
- Abort mode activated (no graceful attempt)
- Immediate force kill
- PID file removed
- No orphan processes

**Failure Indicators:**
- Graceful shutdown attempted (should not happen)
- LogExit monitoring occurs (should not happen)
- Shutdown takes > 5 seconds

---

### Test 4: Restart Button

**Objective:** Verify graceful shutdown followed by automatic restart.

**Steps:**
1. Start server (Test 1)
2. Wait 60 seconds
3. Click **Restart** button in AMP
4. Monitor AMP console for shutdown and restart sequence

**Expected Results:**

**Shutdown Phase:**
- ✅ Same as Test 2 (graceful shutdown)

**Restart Phase:**
- ✅ AMP console shows: `[WRAPPER-INFO] SCUMWrapper v3.0 starting...` (new instance)
- ✅ AMP console shows: `[WRAPPER-DEBUG] Pre-start check: Found 0 existing SCUM process(es)`
- ✅ New server starts successfully
- ✅ New PID file created with new PIDs
- ✅ AMP status returns to "Running" (green)

**Timing:**
- Shutdown: 5-15 seconds (graceful)
- Restart: 10-30 seconds (server startup)
- Total: 15-45 seconds

**Pass Criteria:**
- Clean shutdown of old instance
- No overlap between old and new processes
- New instance starts successfully
- No "Another wrapper instance is already running" error

**Failure Indicators:**
- Duplicate processes (old + new running simultaneously)
- New instance fails to start
- Singleton violation error
- Port conflict errors

---

### Test 5: Update and Restart

**Objective:** Verify graceful shutdown before SteamCMD update, then restart.

**Steps:**
1. Start server (Test 1)
2. Wait 60 seconds
3. Click **Update** button in AMP
4. Monitor AMP console for shutdown, update, and restart sequence

**Expected Results:**

**Shutdown Phase:**
- ✅ Same as Test 2 (graceful shutdown)
- ✅ All SCUM processes terminated before update starts

**Update Phase:**
- ✅ AMP console shows: `Updating SCUM via SteamCMD...`
- ✅ SteamCMD runs without file locking errors
- ✅ Update completes successfully

**Restart Phase:**
- ✅ Same as Test 4 restart phase
- ✅ New server starts with updated files

**Pass Criteria:**
- Clean shutdown before update
- No file locking errors during update
- Update completes successfully
- Server restarts with new version

**Failure Indicators:**
- File locking errors: "File is in use by another process"
- Update fails due to running processes
- Server fails to start after update

---

### Test 6: Failsafe Timeout (Simulated Frozen Server)

**Objective:** Verify failsafe force kill activates when server doesn't respond to Ctrl+C.

**Steps:**
1. Start server (Test 1)
2. Wait 60 seconds
3. **Manually lock the SCUM log file:**
   - Open `SCUM/Saved/Logs/SCUM.log` in Notepad (keeps file locked)
   - Or use PowerShell: `$file = [System.IO.File]::Open("SCUM.log", "Open", "Read", "None")`
4. Click **Stop** button in AMP
5. Monitor AMP console for failsafe activation

**Expected Results:**
- ✅ AMP console shows: `[WRAPPER-INFO] Server is running - GRACEFUL SHUTDOWN MODE`
- ✅ AMP console shows: `[WRAPPER-INFO] Sending Ctrl+C signal to SCUM server`
- ✅ AMP console shows: `[WRAPPER-INFO] Monitoring log file for LogExit pattern...`
- ✅ AMP console shows: `[WRAPPER-INFO] Still waiting for LogExit... (10s elapsed)`
- ✅ AMP console shows: `[WRAPPER-INFO] Still waiting for LogExit... (20s elapsed)`
- ✅ AMP console shows: `[WRAPPER-WARNING] FAILSAFE_TIMEOUT - No LogExit after 30s!`
- ✅ AMP console shows: `[WRAPPER-WARNING] Force killing server process (PID: XXXXX)`
- ✅ AMP console shows: `[WRAPPER-INFO] Process killed (failsafe timeout)`
- ✅ Server process terminated
- ✅ PID file removed

**Timing:**
- Should wait exactly 30 seconds before force kill
- Total shutdown time: ~31 seconds

**Pass Criteria:**
- Failsafe activates after 30 seconds
- Force kill occurs
- PID file removed
- No orphan processes

**Failure Indicators:**
- Failsafe never activates (hangs forever)
- Force kill fails (process remains)
- Wrapper crashes or exits with error

---

### Test 7: Duplicate Prevention (Singleton Enforcement)

**Objective:** Verify that only one wrapper instance can run at a time.

**Steps:**
1. Start server via AMP (Test 1)
2. Open PowerShell as Administrator
3. Navigate to `SCUM/Binaries/Win64/`
4. Manually run: `.\SCUMWrapper.ps1 SCUM -Port=7042 -QueryPort=7043 -MaxPlayers=64 -log`
5. Check exit code: `$LASTEXITCODE`

**Expected Results:**
- ✅ Second wrapper logs: `[WRAPPER-ERROR] Another wrapper instance is already running (PID: XXXXX)`
- ✅ Second wrapper logs: `[WRAPPER-ERROR] PID file age: X seconds (threshold: 300s)`
- ✅ Second wrapper exits immediately
- ✅ Exit code: `1`
- ✅ First wrapper continues running (unaffected)
- ✅ Only one server process in Task Manager

**Pass Criteria:**
- Second wrapper exits with error code 1
- Singleton violation logged
- First instance unaffected

**Failure Indicators:**
- Second wrapper starts successfully (duplicate processes)
- Port conflict errors
- Both wrappers crash

---

### Test 8: Orphan Process Recovery

**Objective:** Verify wrapper detects and terminates orphan SCUM processes before starting.

**Steps:**
1. Ensure server is stopped via AMP
2. Manually start SCUM server:
   - Open PowerShell as Administrator
   - Navigate to `SCUM/Binaries/Win64/`
   - Run: `Start-Process -FilePath ".\SCUMServer.exe" -ArgumentList "SCUM -Port=7042 -QueryPort=7043 -MaxPlayers=64 -log"`
3. Verify orphan process in Task Manager (SCUMServer.exe running)
4. Click **Start** button in AMP
5. Monitor AMP console for orphan cleanup

**Expected Results:**
- ✅ AMP console shows: `[WRAPPER-DEBUG] Pre-start check: Found 1 existing SCUM process(es)`
- ✅ AMP console shows: `[WRAPPER-INFO] Terminating existing SCUM process (PID: XXXXX)`
- ✅ AMP console shows: `[WRAPPER-INFO] Waiting 5 seconds for process cleanup...`
- ✅ AMP console shows: `[WRAPPER-DEBUG] Post-cleanup check: Found 0 SCUM process(es)`
- ✅ New server starts successfully
- ✅ Only one server process in Task Manager (new instance)

**Pass Criteria:**
- Orphan process detected
- Orphan process terminated
- 5-second wait occurs
- New instance starts successfully

**Failure Indicators:**
- Orphan not detected
- Orphan not terminated (duplicate processes)
- Port conflict errors
- New instance fails to start

---

### Test 9: Stale PID File Cleanup

**Objective:** Verify wrapper removes stale PID files from crashed instances.

**Steps:**
1. Ensure server is stopped via AMP
2. Manually create a stale PID file:
   ```powershell
   $pidData = @{
       PID = 99999
       ServerPID = 88888
       Timestamp = (Get-Date).AddHours(-1).ToString("o")
   }
   $pidData | ConvertTo-Json | Set-Content "SCUM/Binaries/Win64/scum_server.pid"
   ```
3. Click **Start** button in AMP
4. Monitor AMP console for stale file cleanup

**Expected Results:**
- ✅ AMP console shows: `[WRAPPER-INFO] Found existing PID file`
- ✅ AMP console shows: `[WRAPPER-INFO] PID file is stale (process 99999 not running or file too old)`
- ✅ AMP console shows: `[WRAPPER-INFO] Removing stale PID file`
- ✅ New server starts successfully
- ✅ New PID file created with current PIDs

**Pass Criteria:**
- Stale PID file detected
- Stale PID file removed
- New instance starts successfully

**Failure Indicators:**
- Singleton violation error (stale file not removed)
- Wrapper exits with error code 1
- New instance fails to start

---

## Test Results Summary

| Test # | Scenario | Status | Notes |
|--------|----------|--------|-------|
| 1 | Start Button | ⏳ | |
| 2 | Stop Button (Graceful) | ⏳ | |
| 3 | Stop Button (Abort) | ⏳ | |
| 4 | Restart Button | ⏳ | |
| 5 | Update and Restart | ⏳ | |
| 6 | Failsafe Timeout | ⏳ | |
| 7 | Duplicate Prevention | ⏳ | |
| 8 | Orphan Recovery | ⏳ | |
| 9 | Stale PID File | ⏳ | |

**Legend:**
- ⏳ Pending
- ✅ Passed
- ❌ Failed
- ⚠️ Partial Pass

## Common Issues and Troubleshooting

### Issue: "Another wrapper instance is already running"

**Cause:** PID file exists from previous run

**Solution:**
1. Check if wrapper/server is actually running (Task Manager)
2. If not running, manually delete `scum_server.pid`
3. If running, stop via AMP first

### Issue: Failsafe timeout always activates

**Cause:** LogExit pattern not appearing in log file

**Solution:**
1. Check SCUM server version (pattern may have changed)
2. Verify log file path: `SCUM/Saved/Logs/SCUM.log`
3. Check wrapper log for file access errors
4. Update LogExit pattern in wrapper if needed

### Issue: Orphan processes after shutdown

**Cause:** Force kill failed or process respawned

**Solution:**
1. Manually kill orphan processes via Task Manager
2. Check wrapper logs for errors during shutdown
3. Verify `App.ExitTimeout` is sufficient (35+ seconds)

### Issue: Port conflict on restart

**Cause:** Old process not fully terminated before new one starts

**Solution:**
1. Increase `App.ExitTimeout` to 40 seconds
2. Check for orphan processes before restart
3. Verify graceful shutdown is working (LogExit detected)

## Validation Checklist

After completing all tests, verify:

- [ ] All 9 test scenarios passed
- [ ] No orphan processes remain after any test
- [ ] PID file always cleaned up correctly
- [ ] Graceful shutdown works consistently
- [ ] Failsafe activates when needed
- [ ] Singleton enforcement prevents duplicates
- [ ] Orphan cleanup works reliably
- [ ] Restart cycles work without issues
- [ ] Updates complete without file locking errors

## Sign-Off

**Tester Name:** ___________________________  
**Date:** ___________________________  
**AMP Version:** ___________________________  
**Wrapper Version:** ___________________________  
**Overall Result:** ⏳ Pending / ✅ Passed / ❌ Failed  

**Notes:**
_____________________________________________
_____________________________________________
_____________________________________________

## Next Steps

1. Complete all test scenarios
2. Document any failures in detail
3. Fix any identified issues
4. Re-test failed scenarios
5. Update `AMP_CONFIGURATION_VERIFICATION.md` with results
6. Mark Task 15.2 as complete
