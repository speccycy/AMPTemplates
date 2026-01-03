# SCUM AMP Graceful Shutdown - Quick Validation Checklist

## Purpose

This is a condensed checklist for quickly validating the SCUM AMP Graceful Shutdown System. Use this for rapid verification before production deployment.

**For detailed procedures, see:** `MANUAL_TESTING_GUIDE.md`  
**For log verification, see:** `LOG_MESSAGE_VERIFICATION.md`

---

## Pre-Flight Checks

Before starting tests, verify:

- [ ] SCUM Dedicated Server is installed
- [ ] AMP is configured with correct `scum.kvp` settings:
  - `App.ExitMethod=OS_CLOSE`
  - `App.ExitMethodWindows=CtrlC`
  - `App.ExitTimeout=35`
- [ ] SCUMWrapper.ps1 v3.0 is in `Binaries/Win64/`
- [ ] You have administrator access

---

## Quick Test Suite (30 Minutes)

### Test 1: Normal Graceful Shutdown ⏱️ 7 min

1. Start server via AMP
2. Wait 5 minutes
3. Stop server via AMP
4. **Verify:** LogExit detected, no force kill

**Expected Log:**
```
[WRAPPER-INFO] Server is running - GRACEFUL SHUTDOWN MODE
[WRAPPER-DEBUG] LogExit pattern detected! Server saved successfully.
[WRAPPER-INFO] Shutdown completed successfully
```

✅ PASS / ❌ FAIL: _______

---

### Test 2: Startup Abort ⏱️ 1 min

1. Start server via AMP
2. Stop within 20 seconds
3. **Verify:** Immediate force kill, no graceful attempt

**Expected Log:**
```
[WRAPPER-WARN] Server in startup phase (< 30s) - ABORT MODE
[WRAPPER-DEBUG] Process killed (startup abort)
```

✅ PASS / ❌ FAIL: _______

---

### Test 3: Restart (No Race Condition) ⏱️ 7 min

1. Start server via AMP
2. Wait 5 minutes
3. Click "Restart" in AMP
4. **Verify:** Clean shutdown → Clean startup, no errors

**Expected Log:**
```
[WRAPPER-INFO] Shutdown completed successfully
[WRAPPER-INFO] Wrapper exiting
[WRAPPER-INFO] SCUM Server Graceful Shutdown Wrapper v3.0
[WRAPPER-DEBUG] Pre-start check: No existing processes found
[WRAPPER-INFO] Server started successfully
```

✅ PASS / ❌ FAIL: _______

---

### Test 4: Orphan Cleanup ⏱️ 3 min

1. Manually start `SCUMServer.exe` (not via AMP)
2. Start server via AMP
3. **Verify:** Orphan detected and killed, new server starts

**Expected Log:**
```
[WRAPPER-WARN] Pre-start check: Found 1 existing SCUM process(es)
[WRAPPER-WARN] Pre-start check: Terminating existing PID: XXXXX
[WRAPPER-DEBUG] Pre-start check: All processes terminated successfully
[WRAPPER-INFO] Server started successfully
```

✅ PASS / ❌ FAIL: _______

---

### Test 5: Duplicate Prevention ⏱️ 2 min

1. Start server via AMP
2. Try to start wrapper manually in PowerShell
3. **Verify:** Second wrapper exits with error

**Expected Log (Second Wrapper):**
```
[WRAPPER-ERROR] ERROR: Another instance is running (PID: XXXXX)
```

✅ PASS / ❌ FAIL: _______

---

### Test 6: Failsafe Timeout ⏱️ 7 min

1. Start server via AMP, wait 5 minutes
2. Rename `Saved/Logs/SCUM.log` to prevent LogExit detection
3. Stop server via AMP
4. **Verify:** Force kill after 30 seconds

**Expected Log:**
```
[WRAPPER-ERROR] State: FAILSAFE_TIMEOUT - No LogExit after 30s!
[WRAPPER-ERROR] Assuming server frozen/crashed - Force killing
[WRAPPER-WARN] Process killed (failsafe timeout)
```

✅ PASS / ❌ FAIL: _______

**Cleanup:** Restore log file after test

---

### Test 7: Log Rotation ⏱️ 2 min

1. Create fake old log files (8+ days old)
2. Start server via AMP
3. **Verify:** Old logs deleted, recent logs preserved

**PowerShell:**
```powershell
cd Binaries\Win64\Logs
$oldDate = (Get-Date).AddDays(-8)
"Test" | Out-File "SCUMWrapper_$($oldDate.ToString('yyyy-MM-dd')).log"
(Get-Item "SCUMWrapper_$($oldDate.ToString('yyyy-MM-dd')).log").LastWriteTime = $oldDate
```

✅ PASS / ❌ FAIL: _______

---

### Test 8: Exit Code Check ⏱️ 1 min

1. Start server via AMP
2. Wait 5 minutes
3. Stop server via AMP
4. **Verify:** Wrapper exits with code 0 (check AMP logs)

✅ PASS / ❌ FAIL: _______

---

## Log Message Spot Check (10 Minutes)

Open today's log file: `Binaries/Win64/Logs/SCUMWrapper_YYYY-MM-DD.log`

Verify these key messages are present:

- [ ] `SCUM Server Graceful Shutdown Wrapper v3.0`
- [ ] `Wrapper PID: XXXXX`
- [ ] `SCUM Server PID: XXXXX`
- [ ] `Created PID file:`
- [ ] `State: RUNNING`
- [ ] `State: SHUTDOWN_REQUESTED`
- [ ] `Server uptime: X.XX min (XXX.Xs)`
- [ ] `Server is running - GRACEFUL SHUTDOWN MODE`
- [ ] `Ctrl+C signal sent to PID XXXXX`
- [ ] `LogExit pattern detected! Server saved successfully.`
- [ ] `Shutdown completed successfully`
- [ ] `Cleaned up PID file`
- [ ] `Wrapper exiting`

**Automated Check:**
```powershell
$logFile = "Binaries\Win64\Logs\SCUMWrapper_$(Get-Date -Format 'yyyy-MM-dd').log"
$patterns = @(
    "SCUM Server Graceful Shutdown Wrapper v3.0",
    "Wrapper PID:",
    "SCUM Server PID:",
    "State: RUNNING",
    "Server uptime:",
    "GRACEFUL SHUTDOWN MODE",
    "LogExit pattern detected"
)
foreach ($p in $patterns) {
    $found = Select-String -Path $logFile -Pattern $p -Quiet
    Write-Host "$p : $(if($found){'✓'}else{'✗'})"
}
```

---

## Pass Criteria

### Minimum Requirements (Must Pass All)

- ✅ Test 1: Graceful shutdown works
- ✅ Test 2: Startup abort works
- ✅ Test 3: Restart has no race conditions
- ✅ Test 4: Orphan cleanup works
- ✅ Test 5: Duplicate prevention works

### Recommended (Should Pass)

- ✅ Test 6: Failsafe timeout works
- ✅ Test 7: Log rotation works
- ✅ Test 8: Exit codes correct

### Log Messages (Should Pass)

- ✅ All key log messages present
- ✅ Format is correct (timestamp, level, message)
- ✅ Console and file match

---

## Quick Troubleshooting

**Problem:** "Another instance is running" but no wrapper running  
**Fix:** Delete `Binaries/Win64/scum_server.pid`

**Problem:** Failsafe always triggers  
**Fix:** Check `Saved/Logs/SCUM.log` exists and is being written

**Problem:** Orphans not detected  
**Fix:** Verify process name is exactly "SCUMServer" in Task Manager

**Problem:** Graceful shutdown not working  
**Fix:** Verify `scum.kvp` has `App.ExitMethodWindows=CtrlC`

---

## Results Summary

**Date:** _______________  
**Tester:** _______________  
**Environment:** _______________

**Tests Passed:** _____ / 8  
**Log Messages Verified:** _____ / 13  

**Overall Status:** ✅ PASS / ❌ FAIL / ⚠️ PARTIAL

**Notes:**
_________________________________________________________________
_________________________________________________________________
_________________________________________________________________

**Recommendation:**
- [ ] ✅ Ready for production deployment
- [ ] ⚠️ Minor issues found, proceed with caution
- [ ] ❌ Issues found, do not deploy

---

## Next Steps

### If All Tests Pass ✅

1. Document test results
2. Proceed to Task 18 (Final Checkpoint)
3. Obtain user approval for production deployment
4. Deploy to production AMP instance

### If Tests Fail ❌

1. Document failures in detail
2. Review `TROUBLESHOOTING.md`
3. Check wrapper logs for errors
4. Fix issues and re-test
5. Do not proceed to production

### For Detailed Analysis

- See `MANUAL_TESTING_GUIDE.md` for complete procedures
- See `LOG_MESSAGE_VERIFICATION.md` for detailed log analysis
- See `TROUBLESHOOTING.md` for issue resolution

---

**Quick Validation Complete!**

Total Time: ~40 minutes  
Confidence Level: High if all tests pass  
Production Ready: Yes if all minimum requirements pass

