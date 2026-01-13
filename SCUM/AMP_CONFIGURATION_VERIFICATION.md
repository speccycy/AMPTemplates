# SCUM AMP Configuration Verification Report

**Date:** January 2, 2026  
**Template Version:** 3.0  
**Verification Status:** ✅ PASSED

## Executive Summary

This document verifies that the SCUM AMP template configuration (`scum.kvp`) is correctly configured to support the graceful shutdown system implemented in `SCUMWrapper.ps1`.

## Configuration Requirements (from Requirement 1.1)

The wrapper requires specific AMP configuration to function correctly:

1. **Exit Method:** Must use `CtrlC` signal on Windows
2. **Exit Timeout:** Must allow sufficient time for graceful shutdown + failsafe
3. **Command Line:** Must invoke the wrapper script instead of direct server execution

## Verification Results

### ✅ 1. Exit Method Configuration

**Requirement:** `App.ExitMethodWindows=CtrlC`

**Current Configuration:**
```kvp
App.ExitMethod=OS_CLOSE
App.ExitMethodWindows=CtrlC
```

**Status:** ✅ **CORRECT**

**Analysis:**
- `App.ExitMethod=OS_CLOSE` tells AMP to use OS-specific close methods
- `App.ExitMethodWindows=CtrlC` specifies that on Windows, AMP should send Ctrl+C signal
- This ensures AMP sends Ctrl+C to the wrapper process, which the wrapper catches and handles gracefully

### ✅ 2. Exit Timeout Configuration

**Requirement:** `App.ExitTimeout=35` (or greater)

**Current Configuration:**
```kvp
App.ExitTimeout=35
```

**Status:** ✅ **CORRECT**

**Analysis:**
- Wrapper failsafe timeout: 30 seconds
- Additional buffer: 5 seconds
- Total timeout: 35 seconds
- This gives the wrapper enough time to:
  1. Detect server uptime (instant)
  2. Send Ctrl+C signal (instant)
  3. Monitor for LogExit pattern (up to 30 seconds)
  4. Force kill if needed (instant)
  5. Cleanup PID file and exit (< 1 second)

**Timing Breakdown:**
```
0s  - AMP sends Ctrl+C to wrapper
0s  - Wrapper receives signal, calculates uptime
0s  - Wrapper sends Ctrl+C to SCUM server
0-30s - Wrapper monitors log file for LogExit pattern
30s - Failsafe timeout activates (if LogExit not found)
30s - Wrapper force kills server
30s - Wrapper cleans up PID file
30s - Wrapper exits
```

**Worst Case:** 30 seconds (failsafe) + ~1 second (cleanup) = ~31 seconds  
**Configured Timeout:** 35 seconds  
**Safety Margin:** 4 seconds ✅

### ✅ 3. Wrapper Invocation

**Requirement:** Must invoke `SCUMWrapper.ps1` instead of `SCUMServer.exe` directly

**Current Configuration:**
```kvp
App.ExecutableWin=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
App.CommandLineArgs=-ExecutionPolicy Bypass -File "SCUM\Binaries\Win64\SCUMWrapper.ps1" {{$PlatformArgs}} SCUM -Port={{$ServerPort}} -QueryPort={{$QueryPort}} -MaxPlayers={{$MaxUsers}} -log {{nobattleye}}{{AdditionalArgs}}{{$FormattedArgs}}
```

**Status:** ✅ **CORRECT**

**Analysis:**
- AMP launches PowerShell as the main process
- PowerShell executes `SCUMWrapper.ps1` with `-ExecutionPolicy Bypass`
- Wrapper receives all server arguments and passes them to `SCUMServer.exe`
- When AMP sends Ctrl+C, it goes to the wrapper (not the server directly)

### ✅ 4. Application Ready Detection

**Requirement:** Must detect when wrapper/server is ready

**Current Configuration:**
```kvp
Console.AppReadyRegex=^\[WRAPPER-DEBUG\] State: RUNNING - Monitoring process\.\.\.|^\[[\d.]+-[\d.:]+\]\[[\d ]+\]LogSCUM: Global Stats:.*$
```

**Status:** ✅ **CORRECT**

**Analysis:**
- Primary pattern: `[WRAPPER-DEBUG] State: RUNNING - Monitoring process...`
  - This is logged by the wrapper when the server successfully starts
  - Ensures AMP knows the wrapper is operational
- Fallback pattern: SCUM server's "Global Stats" log line
  - Provides redundancy if wrapper log is missed
  - Confirms server is actually running and processing game logic

### ✅ 5. Console Monitoring

**Requirement:** Must monitor the correct log file for user join/leave events

**Current Configuration:**
```kvp
App.TailLogFilePath={{$FullBaseDir}}SCUM/Saved/Logs/SCUM.log
Console.UserJoinRegex=^\[[\d.]+-[\d.:]+\]\[[\d ]+\]LogSCUM: '(?<endpoint>.*?) (?<userid>\d+?):(?<username>.*?)\(\d+\)' logged in at:.*$
Console.UserLeaveRegex=^\[[\d.]+-[\d.:]+\]\[[\d ]+\]LogSCUM: Warning: Prisoner logging out: (?<username>.*?) \((?<userid>\d+?)\)$
```

**Status:** ✅ **CORRECT**

**Analysis:**
- AMP monitors the SCUM server log (not the wrapper log)
- User join/leave patterns correctly parse SCUM's log format
- This is independent of the wrapper's graceful shutdown functionality

### ✅ 6. Linux Configuration (Proton)

**Current Configuration:**
```kvp
App.ExecutableLinux=.proton/proton
App.LinuxCommandLineArgs=runinprefix "{{$FullBaseDir}}SCUM/Binaries/Win64/SCUMServer.exe"
```

**Status:** ⚠️ **NEEDS ATTENTION**

**Analysis:**
- Linux configuration directly launches `SCUMServer.exe` via Proton
- **Does NOT use the wrapper script**
- This means Linux installations will NOT have graceful shutdown protection

**Recommendation:**
- Update Linux configuration to use the wrapper:
  ```kvp
  App.LinuxCommandLineArgs=runinprefix "{{$FullBaseDir}}SCUM/Binaries/Win64/SCUMWrapper.ps1"
  ```
- However, this requires PowerShell Core to be installed on Linux
- Alternative: Create a bash wrapper script with equivalent functionality

**Current Decision:** Leave as-is for now (Windows-only wrapper)

## Configuration Validation Checklist

- [x] `App.ExitMethodWindows=CtrlC` is set
- [x] `App.ExitTimeout=35` is appropriate (≥ 31 seconds required)
- [x] Wrapper script is invoked via PowerShell
- [x] Application ready detection includes wrapper state
- [x] Console monitoring configured correctly
- [x] Exit method allows graceful shutdown
- [x] Timeout allows failsafe to complete

## Testing Recommendations

### Manual Testing Scenarios

1. **Normal Stop (Graceful Shutdown)**
   - Start server via AMP
   - Wait 60 seconds (ensure uptime > 30s)
   - Click "Stop" button in AMP
   - **Expected:** Wrapper logs "GRACEFUL SHUTDOWN MODE", LogExit detected, clean exit
   - **Verify:** No orphan processes, PID file removed

2. **Quick Stop (Startup Abort)**
   - Start server via AMP
   - Immediately click "Stop" (within 10 seconds)
   - **Expected:** Wrapper logs "ABORT MODE", immediate force kill
   - **Verify:** No orphan processes, PID file removed

3. **Restart Button**
   - Start server via AMP
   - Wait 60 seconds
   - Click "Restart" button in AMP
   - **Expected:** Graceful shutdown, then new instance starts
   - **Verify:** No duplicate processes, new PID file created

4. **Update and Restart**
   - Start server via AMP
   - Wait 60 seconds
   - Click "Update" button in AMP
   - **Expected:** Graceful shutdown, SteamCMD update, new instance starts
   - **Verify:** No file locking errors during update

5. **Failsafe Timeout**
   - Start server via AMP
   - Wait 60 seconds
   - Manually lock the SCUM.log file (simulate frozen server)
   - Click "Stop" button in AMP
   - **Expected:** Wrapper waits 30 seconds, logs "FAILSAFE_TIMEOUT", force kills
   - **Verify:** Process terminated, PID file removed

6. **Duplicate Prevention**
   - Start server via AMP (let it run)
   - Manually run `SCUMWrapper.ps1` from command line
   - **Expected:** Second wrapper exits with error code 1, logs singleton violation
   - **Verify:** Only one server process running

## Integration Test Results

### Test Environment
- **OS:** Windows Server 2019/2022
- **AMP Version:** 2.6.0.0 or higher
- **PowerShell Version:** 5.1 or higher

### Test Results (To be completed during Task 15.2)

| Test Scenario | Status | Notes |
|---------------|--------|-------|
| Start Button | ⏳ Pending | |
| Stop Button (Graceful) | ⏳ Pending | |
| Stop Button (Abort) | ⏳ Pending | |
| Restart Button | ⏳ Pending | |
| Update and Restart | ⏳ Pending | |
| Failsafe Timeout | ⏳ Pending | |
| Duplicate Prevention | ⏳ Pending | |

## Conclusion

The SCUM AMP template configuration (`scum.kvp`) is **correctly configured** to support the graceful shutdown system. All critical settings are in place:

- ✅ Ctrl+C signal delivery
- ✅ Adequate timeout for failsafe
- ✅ Wrapper script invocation
- ✅ Application ready detection

**Next Steps:**
1. Complete Task 15.2: Test all AMP integration scenarios
2. Document test results in this report
3. Address Linux configuration if needed (future enhancement)

## References

- **Requirements Document:** `.kiro/specs/scum-amp-graceful-shutdown/requirements.md`
- **Design Document:** `.kiro/specs/scum-amp-graceful-shutdown/design.md`
- **Wrapper Script:** `AMPTemplates/SCUM/Binaries/Win64/SCUMWrapper.ps1`
- **AMP Template:** `AMPTemplates/scum.kvp`
