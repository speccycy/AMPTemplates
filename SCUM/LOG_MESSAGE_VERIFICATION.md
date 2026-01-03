# SCUM AMP Graceful Shutdown - Log Message Verification

## Overview

This document provides a comprehensive checklist for verifying that all required log messages are present and correctly formatted in the SCUMWrapper.ps1 implementation. Each log message is mapped to its corresponding requirement for traceability.

**Version:** 3.0  
**Date:** January 2, 2026  
**Purpose:** Validate Requirements 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8

---

## Log Message Categories

### 1. PID Tracking Logs (Requirement 5.3, 5.4)

These logs track process identifiers for troubleshooting and monitoring.

#### 1.1 Wrapper PID Logging

**Requirement:** 5.3 - WHEN the Wrapper starts, THEN the Wrapper SHALL log the wrapper PID and version number

**Expected Log Messages:**
```
[WRAPPER-INFO] ==================================================
[WRAPPER-INFO] SCUM Server Graceful Shutdown Wrapper v3.0
[WRAPPER-INFO] Wrapper PID: 12345
[WRAPPER-INFO] ==================================================
```

**Verification:**
- [ ] Version number is logged (v3.0)
- [ ] Wrapper PID is logged
- [ ] Message appears at wrapper startup
- [ ] Format includes separator lines for visibility

**Code Location:** Lines 195-199 in SCUMWrapper.ps1

---

#### 1.2 Server PID Logging

**Requirement:** 5.4 - WHEN the SCUM_Server starts, THEN the Wrapper SHALL log the server PID

**Expected Log Messages:**
```
[WRAPPER-INFO] Server started successfully
[WRAPPER-INFO] SCUM Server PID: 67890
[WRAPPER-DEBUG] Wrapper PID: 12345
```

**Verification:**
- [ ] Server PID is logged after successful start
- [ ] "Server started successfully" message appears
- [ ] Wrapper PID is also logged for reference (DEBUG level)
- [ ] PID file is updated with server PID

**Code Location:** Lines 577-580 in SCUMWrapper.ps1

---

#### 1.3 PID File Management Logging

**Expected Log Messages:**
```
[WRAPPER-INFO] Created PID file: C:\...\scum_server.pid
[WRAPPER-DEBUG] PID file updated with server PID: 67890
[WRAPPER-INFO] Cleaned up PID file
```

**Verification:**
- [ ] PID file creation is logged with full path
- [ ] PID file update is logged after server start
- [ ] PID file cleanup is logged on exit
- [ ] Stale PID file removal is logged if applicable

**Code Location:** Lines 327, 585, 779 in SCUMWrapper.ps1

---

### 2. State Transition Logs (Requirement 5.5)

These logs track the wrapper's state machine transitions for debugging.

#### 2.1 State Transition Messages

**Requirement:** 5.5 - WHEN state transitions occur, THEN the Wrapper SHALL log the new state with DEBUG level

**Expected Log Messages:**
```
[WRAPPER-DEBUG] State: RUNNING - Monitoring process...
[WRAPPER-DEBUG] State: SHUTDOWN_REQUESTED - Checking server uptime...
[WRAPPER-DEBUG] State: SENDING_SHUTDOWN_SIGNAL
[WRAPPER-DEBUG] State: WAITING_FOR_LOGEXIT - Monitoring log file...
[WRAPPER-DEBUG] State: FORCE_KILL - Terminating PID 67890...
[WRAPPER-DEBUG] State: FAILSAFE_TIMEOUT - No LogExit after 30s!
[WRAPPER-DEBUG] State: SIGNAL_FAILED - Ctrl+C failed, force killing...
[WRAPPER-DEBUG] State: SHUTDOWN_COMPLETE - Graceful shutdown confirmed (10s)
[WRAPPER-DEBUG] State: SHUTDOWN_COMPLETE - Process exited but LogExit not detected (15s)
```

**Verification:**
- [ ] All state transitions are logged with "State:" prefix
- [ ] All state messages use DEBUG level
- [ ] States are logged in correct sequence
- [ ] Each state includes relevant context (PID, duration, etc.)

**Code Location:** Lines 593, 632, 645, 649, 665, 751, 765, 711, 719 in SCUMWrapper.ps1

---

### 3. Process Check Logs (Requirement 5.6)

These logs track orphan process detection and cleanup.

#### 3.1 Pre-Start Check Logging

**Requirement:** 5.6 - WHEN the Wrapper detects existing processes, THEN the Wrapper SHALL log each PID being terminated

**Expected Log Messages (No Orphans):**
```
[WRAPPER-DEBUG] Pre-start check: Scanning for existing SCUM processes...
[WRAPPER-DEBUG] Pre-start check: No existing processes found - clear to start
```

**Expected Log Messages (Orphans Found):**
```
[WRAPPER-DEBUG] Pre-start check: Scanning for existing SCUM processes...
[WRAPPER-WARN] Pre-start check: Found 2 existing SCUM process(es)
[WRAPPER-WARN] Pre-start check: Terminating existing PID: 11111
[WRAPPER-DEBUG] Pre-start check: Successfully terminated PID: 11111
[WRAPPER-WARN] Pre-start check: Terminating existing PID: 22222
[WRAPPER-DEBUG] Pre-start check: Successfully terminated PID: 22222
[WRAPPER-DEBUG] Pre-start check: Waiting for process cleanup (5s)...
[WRAPPER-DEBUG] Pre-start check: All processes terminated successfully
```

**Expected Log Messages (Cleanup Failure):**
```
[WRAPPER-ERROR] Pre-start check: WARNING - 1 process(es) still running!
```

**Verification:**
- [ ] Scanning message appears at startup
- [ ] Each orphan PID is logged individually
- [ ] Termination attempts are logged for each PID
- [ ] Success/failure is logged for each termination
- [ ] 5-second wait is logged
- [ ] Final verification result is logged
- [ ] Warning appears if processes remain after cleanup

**Code Location:** Lines 207-248 in SCUMWrapper.ps1

---

### 4. Shutdown Decision Logs (Requirement 5.7)

These logs explain why a particular shutdown mode was chosen.

#### 4.1 Uptime Logging

**Requirement:** 5.7 - WHEN graceful shutdown is attempted, THEN the Wrapper SHALL log the server uptime in both minutes and seconds

**Expected Log Messages:**
```
[WRAPPER-INFO] Server uptime: 5.23 min (314.0s)
```

**Verification:**
- [ ] Uptime is logged in minutes with 2 decimal places
- [ ] Uptime is logged in seconds with 1 decimal place
- [ ] Format is: "X.XX min (XXX.Xs)"
- [ ] Message appears before shutdown decision

**Code Location:** Line 641 in SCUMWrapper.ps1

---

#### 4.2 Shutdown Mode Decision Logging

**Expected Log Messages (Abort Mode):**
```
[WRAPPER-WARN] Server in startup phase (< 30s) - ABORT MODE
[WRAPPER-DEBUG] State: FORCE_KILL - Terminating PID 67890...
[WRAPPER-DEBUG] Process killed (startup abort)
[WRAPPER-WARN] Shutdown completed (startup abort, force killed)
```

**Expected Log Messages (Graceful Mode):**
```
[WRAPPER-INFO] Server is running - GRACEFUL SHUTDOWN MODE
[WRAPPER-DEBUG] State: SENDING_SHUTDOWN_SIGNAL
[WRAPPER-DEBUG] Ctrl+C signal sent to PID 67890
[WRAPPER-DEBUG] State: WAITING_FOR_LOGEXIT - Monitoring log file...
```

**Verification:**
- [ ] Shutdown mode is clearly stated (ABORT or GRACEFUL)
- [ ] Abort mode includes threshold (< 30s)
- [ ] Graceful mode confirms signal was sent
- [ ] Mode decision is based on uptime calculation

**Code Location:** Lines 653-656, 660-663 in SCUMWrapper.ps1

---

### 5. LogExit Detection Logs (Requirement 1.3, 9.2)

These logs track the monitoring process for graceful shutdown confirmation.

#### 5.1 LogExit Monitoring Messages

**Expected Log Messages (Success):**
```
[WRAPPER-DEBUG] State: WAITING_FOR_LOGEXIT - Monitoring log file...
[WRAPPER-DEBUG] LogExit pattern detected! Server saved successfully.
[WRAPPER-DEBUG] State: SHUTDOWN_COMPLETE - Graceful shutdown confirmed (10s)
[WRAPPER-INFO] Shutdown completed successfully in 10.5s (graceful, LogExit detected)
```

**Expected Log Messages (Progress Updates):**
```
[WRAPPER-DEBUG] Still waiting for LogExit... (10/30s)
[WRAPPER-DEBUG] Still waiting for LogExit... (20/30s)
```

**Expected Log Messages (Timeout):**
```
[WRAPPER-ERROR] State: FAILSAFE_TIMEOUT - No LogExit after 30s!
[WRAPPER-ERROR] Assuming server frozen/crashed - Force killing PID 67890...
[WRAPPER-WARN] Process killed (failsafe timeout)
[WRAPPER-WARN] Shutdown completed in 30.2s (failsafe timeout, force killed)
```

**Expected Log Messages (Process Exited Without LogExit):**
```
[WRAPPER-WARN] State: SHUTDOWN_COMPLETE - Process exited but LogExit not detected (8s)
[WRAPPER-WARN] Shutdown completed in 8.3s (process exited, no LogExit)
```

**Verification:**
- [ ] Monitoring start is logged
- [ ] Progress messages appear every 10 seconds
- [ ] LogExit detection is logged when pattern found
- [ ] Timeout is logged after 30 seconds if pattern not found
- [ ] Process exit without LogExit is logged as warning
- [ ] Shutdown duration is included in completion message
- [ ] Shutdown reason is clearly stated

**Code Location:** Lines 649, 683, 695, 711-714, 719-722, 751-756 in SCUMWrapper.ps1

---

### 6. Exit Logging (Requirement 5.8)

These logs document the final cleanup and exit process.

#### 6.1 Exit Reason and Cleanup Logging

**Requirement:** 5.8 - WHEN the Wrapper exits, THEN the Wrapper SHALL log the exit reason and cleanup actions

**Expected Log Messages (Normal Exit):**
```
[WRAPPER-INFO] Process exited. Code: 0
[WRAPPER-INFO] Cleaned up PID file
[WRAPPER-INFO] Wrapper exiting
[WRAPPER-INFO] ==================================================
```

**Expected Log Messages (Graceful Shutdown):**
```
[WRAPPER-INFO] Shutdown completed successfully in 10.5s (graceful, LogExit detected)
[WRAPPER-INFO] Cleaned up PID file
[WRAPPER-INFO] Wrapper exiting
[WRAPPER-INFO] ==================================================
```

**Expected Log Messages (Forced Shutdown):**
```
[WRAPPER-WARN] Shutdown completed in 30.2s (failsafe timeout, force killed)
[WRAPPER-INFO] Cleaned up PID file
[WRAPPER-INFO] Wrapper exiting
[WRAPPER-INFO] ==================================================
```

**Verification:**
- [ ] Exit reason is logged (normal, graceful, forced, etc.)
- [ ] PID file cleanup is logged
- [ ] "Wrapper exiting" message appears
- [ ] Final separator line appears
- [ ] Exit code is logged if process exited normally

**Code Location:** Lines 598, 779, 782-783 in SCUMWrapper.ps1

---

### 7. Error and Warning Logs

These logs document exceptional conditions and errors.

#### 7.1 Singleton Violation

**Expected Log Messages:**
```
[WRAPPER-ERROR] ERROR: Another instance is running (PID: 12345)
[WRAPPER-ERROR] If this is incorrect, delete: C:\...\scum_server.pid
```

**Verification:**
- [ ] Error clearly states another instance is running
- [ ] PID of existing instance is logged
- [ ] Path to PID file is provided for manual cleanup
- [ ] Wrapper exits with code 1

**Code Location:** Lines 303-305 in SCUMWrapper.ps1

---

#### 7.2 Stale PID File Removal

**Expected Log Messages:**
```
[WRAPPER-WARN] Removing stale PID file (age: 8.5 min)
```

**Verification:**
- [ ] Warning level is used (not error)
- [ ] Age of PID file is logged in minutes
- [ ] File is removed automatically

**Code Location:** Line 311 in SCUMWrapper.ps1

---

#### 7.3 Corrupted PID File

**Expected Log Messages:**
```
[WRAPPER-WARN] Removing corrupted PID file
```

**Verification:**
- [ ] Warning level is used
- [ ] File is removed automatically
- [ ] Wrapper continues normally

**Code Location:** Line 316 in SCUMWrapper.ps1

---

#### 7.4 Executable Not Found

**Expected Log Messages:**
```
[WRAPPER-ERROR] ERROR: Server executable not found: C:\...\SCUMServer.exe
```

**Verification:**
- [ ] Error clearly states executable not found
- [ ] Full path to expected executable is logged
- [ ] Wrapper exits with code 1

**Code Location:** Lines 540-541 in SCUMWrapper.ps1

---

#### 7.5 Process Start Failure

**Expected Log Messages:**
```
[WRAPPER-ERROR] ERROR: Failed to start process
```

**Verification:**
- [ ] Error is logged if process start returns null
- [ ] Wrapper exits with code 1

**Code Location:** Lines 558-559 in SCUMWrapper.ps1

---

#### 7.6 Ctrl+C Signal Failure

**Expected Log Messages:**
```
[WRAPPER-WARN] API method failed: <error details>
[WRAPPER-INFO] Trying CloseMainWindow fallback...
[WRAPPER-DEBUG] CloseMainWindow sent
```

**Or if both methods fail:**
```
[WRAPPER-WARN] CloseMainWindow failed: <error details>
[WRAPPER-DEBUG] State: SIGNAL_FAILED - Ctrl+C failed, force killing...
[WRAPPER-WARN] Process killed (signal failed)
[WRAPPER-WARN] Shutdown completed (signal failed, force killed)
```

**Verification:**
- [ ] API failure is logged as warning
- [ ] Fallback method is attempted
- [ ] Fallback result is logged
- [ ] If both fail, force kill is logged with reason

**Code Location:** Lines 502, 505, 509, 513, 765-768 in SCUMWrapper.ps1

---

#### 7.7 Windows API Load Failure

**Expected Log Messages:**
```
[WRAPPER-WARN] Failed to load Windows API: <error details>
[WRAPPER-WARN] Will use fallback method (CloseMainWindow)
```

**Verification:**
- [ ] API load failure is logged as warning (not error)
- [ ] Fallback method is announced
- [ ] Wrapper continues normally

**Code Location:** Lines 437-438 in SCUMWrapper.ps1

---

### 8. Dual Logging Verification (Requirement 5.1, 5.2)

#### 8.1 Console Output Format

**Requirement:** 5.1 - WHEN any wrapper operation occurs, THEN the Wrapper SHALL write log entries to both console and log file

**Console Format:**
```
[WRAPPER-INFO] Message text
[WRAPPER-WARN] Warning text
[WRAPPER-ERROR] Error text
[WRAPPER-DEBUG] Debug text
```

**Verification:**
- [ ] All messages appear in AMP console
- [ ] Level prefix is present: [WRAPPER-INFO], [WRAPPER-WARN], [WRAPPER-ERROR], [WRAPPER-DEBUG]
- [ ] Messages are readable and not truncated
- [ ] No duplicate messages

---

#### 8.2 Log File Format

**Requirement:** 5.2 - WHEN a log entry is created, THEN the Wrapper SHALL include timestamp, log level, and message

**Log File Format:**
```
[2026-01-02 13:26:45.123] [INFO] Message text
[2026-01-02 13:26:45.456] [WARNING] Warning text
[2026-01-02 13:26:45.789] [ERROR] Error text
[2026-01-02 13:26:46.012] [DEBUG] Debug text
```

**Verification:**
- [ ] Timestamp includes milliseconds (yyyy-MM-dd HH:mm:ss.fff)
- [ ] Log level is present: INFO, WARNING, ERROR, DEBUG
- [ ] Message text matches console output
- [ ] All console messages also appear in log file
- [ ] Log file is created in Logs/ directory
- [ ] Log file name includes date: SCUMWrapper_YYYY-MM-DD.log

**Code Location:** Lines 165-180 in SCUMWrapper.ps1

---

### 9. Log Rotation Verification (Requirement 5.9)

#### 9.1 Automatic Log Deletion

**Requirement:** 5.9 - WHEN log files are older than 7 days, THEN the Wrapper SHALL automatically delete them

**Expected Behavior:**
- Logs older than 7 days are deleted at wrapper startup
- Logs newer than 7 days are preserved
- Current day's log is created/updated
- No error messages if no old logs exist

**Verification:**
- [ ] Create test log files with old dates (8+ days)
- [ ] Start wrapper
- [ ] Verify old logs are deleted
- [ ] Verify recent logs are preserved
- [ ] No errors in log output

**Code Location:** Lines 183-187 in SCUMWrapper.ps1

---

## Verification Checklist Summary

### By Requirement

- [ ] **Requirement 5.1:** Dual logging (console + file) verified
- [ ] **Requirement 5.2:** Log entry format (timestamp, level, message) verified
- [ ] **Requirement 5.3:** Wrapper PID and version logged at startup
- [ ] **Requirement 5.4:** Server PID logged after start
- [ ] **Requirement 5.5:** State transitions logged with DEBUG level
- [ ] **Requirement 5.6:** Orphan process PIDs logged during termination
- [ ] **Requirement 5.7:** Server uptime logged in minutes and seconds
- [ ] **Requirement 5.8:** Exit reason and cleanup actions logged
- [ ] **Requirement 5.9:** Log files older than 7 days deleted

### By Category

- [ ] **PID Tracking:** All PID-related logs present and correct
- [ ] **State Transitions:** All state changes logged with proper level
- [ ] **Process Checks:** Orphan detection and cleanup logged
- [ ] **Shutdown Decisions:** Uptime and mode selection logged
- [ ] **LogExit Detection:** Monitoring progress and results logged
- [ ] **Exit Logging:** Cleanup and exit reasons logged
- [ ] **Error Handling:** All error conditions logged appropriately
- [ ] **Dual Output:** Console and file logging working correctly

---

## Testing Procedure

### 1. Automated Log Verification

Run this PowerShell script to verify log message presence:

```powershell
# Log Message Verification Script
$logFile = "Binaries\Win64\Logs\SCUMWrapper_$(Get-Date -Format 'yyyy-MM-dd').log"

# Define required log patterns
$requiredPatterns = @(
    "SCUM Server Graceful Shutdown Wrapper v3.0",
    "Wrapper PID:",
    "SCUM Server PID:",
    "Created PID file:",
    "State: RUNNING",
    "State: SHUTDOWN_REQUESTED",
    "Server uptime:",
    "Cleaned up PID file",
    "Wrapper exiting"
)

# Check for each pattern
$results = @()
foreach ($pattern in $requiredPatterns) {
    $found = Select-String -Path $logFile -Pattern $pattern -Quiet
    $results += [PSCustomObject]@{
        Pattern = $pattern
        Found = $found
        Status = if ($found) { "✓ PASS" } else { "✗ FAIL" }
    }
}

# Display results
$results | Format-Table -AutoSize

# Summary
$passed = ($results | Where-Object { $_.Found }).Count
$total = $results.Count
Write-Host "`nSummary: $passed/$total patterns found"

if ($passed -eq $total) {
    Write-Host "✓ All required log messages present" -ForegroundColor Green
} else {
    Write-Host "✗ Some log messages missing" -ForegroundColor Red
}
```

### 2. Manual Log Review

1. **Start the server** and let it run for 5+ minutes
2. **Stop the server** gracefully
3. **Open the log file:** `Binaries\Win64\Logs\SCUMWrapper_YYYY-MM-DD.log`
4. **Verify each section** using the checklists above
5. **Check console output** in AMP matches log file

### 3. Edge Case Testing

Test each error condition and verify appropriate log messages:

- [ ] Singleton violation (duplicate wrapper)
- [ ] Stale PID file removal
- [ ] Corrupted PID file handling
- [ ] Missing executable error
- [ ] Orphan process cleanup
- [ ] Failsafe timeout activation
- [ ] Signal sending failure

---

## Pass Criteria

All log message verification tests must pass:

✅ **Format Compliance:**
- Console messages use [WRAPPER-LEVEL] prefix
- Log file entries include timestamp with milliseconds
- Log levels are correct (INFO, WARNING, ERROR, DEBUG)

✅ **Content Completeness:**
- All required log messages are present
- PIDs are logged correctly
- State transitions are tracked
- Uptime is formatted correctly
- Exit reasons are clear

✅ **Dual Output:**
- All messages appear in both console and file
- No messages are lost or duplicated
- Log file is created in correct location

✅ **Error Handling:**
- All error conditions produce appropriate log messages
- Warnings are used for non-fatal issues
- Errors are used for fatal issues

---

## Conclusion

After completing this verification:

1. ✅ All required log messages are present
2. ✅ Log format meets requirements
3. ✅ Dual logging (console + file) works correctly
4. ✅ All requirements 5.1-5.9 are satisfied
5. ✅ Logs provide sufficient information for troubleshooting

**Next Steps:**
- Document any missing or incorrect log messages
- Update wrapper if any issues found
- Proceed to production deployment if all checks pass

