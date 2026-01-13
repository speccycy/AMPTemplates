# SCUM AMP Wrapper - Troubleshooting Guide

## Table of Contents
1. [Quick Diagnostics](#quick-diagnostics)
2. [Common Issues](#common-issues)
3. [Log Message Reference](#log-message-reference)
4. [FAQ](#faq)
5. [Advanced Troubleshooting](#advanced-troubleshooting)

---

## Quick Diagnostics

### Step 1: Check Wrapper Logs
Wrapper logs are located in: `Binaries/Win64/Logs/SCUMWrapper_YYYY-MM-DD.log`

Look for these key indicators:
- `[WRAPPER-ERROR]` - Critical errors that prevent operation
- `[WRAPPER-WARN]` - Warnings that may indicate problems
- `[WRAPPER-DEBUG]` - Detailed state transitions for troubleshooting

### Step 2: Check Server Logs
Server logs are located in: `Saved/Logs/SCUM.log`

Look for:
- `LogExit: Exiting` - Confirms successful graceful shutdown
- Error messages near the end of the file

### Step 3: Check PID File
PID file location: `Binaries/Win64/scum_server.pid`

If this file exists when no server is running, it's stale and should be deleted.

---

## Common Issues

### Issue 1: "Another instance is running" Error

**Symptoms:**
```
[WRAPPER-ERROR] ERROR: Another instance is running (PID: 12345)
[WRAPPER-ERROR] If this is incorrect, delete: scum_server.pid
```

**Cause:** 
- Another wrapper instance is actually running
- Stale PID file from crashed wrapper

**Solution:**
1. Check if process is actually running:
   ```powershell
   Get-Process -Id 12345 -ErrorAction SilentlyContinue
   ```
2. If no process found, delete the PID file:
   ```powershell
   Remove-Item "Binaries\Win64\scum_server.pid" -Force
   ```
3. Restart the server in AMP

**Prevention:**
- Always use AMP's Stop button (don't kill processes manually)
- The wrapper automatically cleans up stale PID files older than 5 minutes

---

### Issue 2: Server Won't Stop (Hangs on "Stopping")

**Symptoms:**
- AMP shows "Stopping..." for more than 30 seconds
- Server process still visible in Task Manager

**Cause:**
- Server is frozen/crashed and not responding to Ctrl+C
- Failsafe timeout will activate after 30 seconds

**What Happens:**
1. Wrapper sends Ctrl+C signal
2. Waits up to 30 seconds for LogExit pattern
3. If no response, force kills the process (failsafe)

**Log Messages:**
```
[WRAPPER-ERROR] State: FAILSAFE_TIMEOUT - No LogExit after 30s!
[WRAPPER-ERROR] Assuming server frozen/crashed - Force killing PID 12345...
[WRAPPER-WARN] Process killed (failsafe timeout)
```

**Solution:**
- Wait for failsafe timeout (30 seconds)
- Check server logs for crash information
- If this happens frequently, investigate server stability

---

### Issue 3: Orphan Processes After Restart

**Symptoms:**
```
[WRAPPER-WARN] Pre-start check: Found 1 existing SCUM process(es)
[WRAPPER-WARN] Pre-start check: Terminating existing PID: 12345
```

**Cause:**
- Previous server instance didn't terminate cleanly
- Race condition during restart

**What Happens:**
1. Wrapper detects orphan processes
2. Terminates all orphan processes
3. Waits 5 seconds for cleanup
4. Verifies all processes are gone
5. Starts new instance

**Solution:**
- This is handled automatically by the wrapper
- If you see this frequently, check for:
  - Server crashes
  - Manual process kills
  - System resource issues

---

### Issue 4: Database Corruption / Lost Player Data

**Symptoms:**
- Players lose progress after restart
- Database errors in server logs
- World state reverted to earlier save

**Cause:**
- Server was force killed without graceful shutdown
- LogExit pattern never appeared (save didn't complete)

**Prevention:**
1. **Always use AMP's Stop button** - Never kill processes manually
2. **Wait for graceful shutdown** - Don't restart immediately
3. **Check logs for LogExit** - Confirms successful save

**Log Messages to Look For:**
```
✓ GOOD: [WRAPPER-DEBUG] LogExit pattern detected! Server saved successfully.
✓ GOOD: Shutdown completed successfully in 8.2s (graceful, LogExit detected)

✗ BAD: [WRAPPER-WARN] Shutdown completed in 5.1s (process exited, no LogExit)
✗ BAD: [WRAPPER-WARN] Process killed (failsafe timeout)
```

**Recovery:**
- If corruption occurs, restore from backup
- Check server logs for specific database errors
- Consider increasing failsafe timeout if saves take longer than 30s

---

### Issue 5: Startup Abort (Server Killed During Startup)

**Symptoms:**
```
[WRAPPER-WARN] Server in startup phase (< 30s) - ABORT MODE
[WRAPPER-DEBUG] Process killed (startup abort)
```

**Cause:**
- User clicked Stop/Abort within 30 seconds of starting
- This is expected behavior

**Why This Happens:**
- Servers in startup phase (< 30 seconds) don't have player data to save
- Graceful shutdown would waste time
- Immediate force kill is safe and faster

**Solution:**
- This is normal behavior, not an error
- If you need to stop during startup, this is the correct behavior

---

### Issue 6: Port Conflicts / "Address Already in Use"

**Symptoms:**
- Server fails to start
- Error about port already in use
- Multiple SCUM processes visible in Task Manager

**Cause:**
- Orphan process cleanup failed
- Another application using the same ports

**Solution:**
1. Check for orphan processes:
   ```powershell
   Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
   ```
2. If found, kill manually:
   ```powershell
   Stop-Process -Name "SCUMServer" -Force
   ```
3. Wait 5 seconds, then restart in AMP
4. If problem persists, check for other applications using your ports

---

## Log Message Reference

### Startup Messages

| Message | Meaning | Action Required |
|---------|---------|-----------------|
| `SCUM Server Graceful Shutdown Wrapper v3.0` | Wrapper started successfully | None |
| `Wrapper PID: 12345` | Wrapper process ID | Note for troubleshooting |
| `Windows API loaded successfully` | Ctrl+C signal support enabled | None |
| `Failed to load Windows API` | Using fallback signal method | None (automatic fallback) |
| `Created PID file: scum_server.pid` | Singleton enforcement active | None |
| `Registered cleanup event handler` | Crash recovery enabled | None |

### Pre-Start Check Messages

| Message | Meaning | Action Required |
|---------|---------|-----------------|
| `Pre-start check: No existing processes found` | Clean start, no orphans | None |
| `Pre-start check: Found X existing SCUM process(es)` | Orphan processes detected | None (auto-cleanup) |
| `Pre-start check: Terminating existing PID: X` | Killing orphan process | None |
| `Pre-start check: All processes terminated successfully` | Orphan cleanup successful | None |
| `Pre-start check: WARNING - X process(es) still running!` | Orphan cleanup failed | Investigate stuck processes |

### Server Startup Messages

| Message | Meaning | Action Required |
|---------|---------|-----------------|
| `Server started successfully` | Server process launched | None |
| `SCUM Server PID: 12345` | Server process ID | Note for troubleshooting |
| `PID file updated with server PID` | PID tracking active | None |
| `State: RUNNING - Monitoring process...` | Server running normally | None |

### Shutdown Messages

| Message | Meaning | Action Required |
|---------|---------|-----------------|
| `State: SHUTDOWN_REQUESTED` | AMP sent stop signal | None |
| `Server uptime: X.XX min (XXs)` | Server runtime before shutdown | None |
| `Server in startup phase (< 30s) - ABORT MODE` | Using immediate force kill | None (expected) |
| `Server is running - GRACEFUL SHUTDOWN MODE` | Using graceful shutdown | None |
| `Ctrl+C signal sent to PID X` | Shutdown signal delivered | None |
| `State: WAITING_FOR_LOGEXIT` | Monitoring for save confirmation | None |
| `LogExit pattern detected! Server saved successfully.` | ✓ Graceful shutdown confirmed | None |
| `Still waiting for LogExit... (Xs/30s)` | Waiting for save to complete | None (normal) |
| `State: FAILSAFE_TIMEOUT - No LogExit after 30s!` | ✗ Server not responding | Check server logs |
| `Assuming server frozen/crashed - Force killing` | Activating failsafe | Investigate server stability |
| `State: SIGNAL_FAILED - Ctrl+C failed` | ✗ Signal delivery failed | Check Windows API status |

### Shutdown Completion Messages

| Message | Meaning | Data Integrity |
|---------|---------|----------------|
| `Shutdown completed successfully (graceful, LogExit detected)` | ✓ Perfect shutdown | ✓ 100% Safe |
| `Shutdown completed (process exited, no LogExit)` | ⚠ Uncertain shutdown | ⚠ Possibly unsafe |
| `Shutdown completed (failsafe timeout, force killed)` | ✗ Forced shutdown | ✗ Risk of corruption |
| `Shutdown completed (signal failed, force killed)` | ✗ Forced shutdown | ✗ Risk of corruption |
| `Shutdown completed (startup abort, force killed)` | ✓ Abort during startup | ✓ Safe (no data) |

### Cleanup Messages

| Message | Meaning | Action Required |
|---------|---------|-----------------|
| `Cleaned up PID file` | PID file removed | None |
| `Event handler cleaned up PID file` | Crash recovery cleanup | None |
| `Wrapper exiting` | Wrapper terminating | None |

---

## FAQ

### Q: How long should graceful shutdown take?

**A:** Typically 5-15 seconds for normal servers. Factors affecting shutdown time:
- Number of players (more players = more data to save)
- World size (larger worlds = more data)
- Disk speed (SSD vs HDD)
- Server load (CPU/memory usage)

If shutdowns consistently take longer than 25 seconds, consider:
- Upgrading to SSD storage
- Reducing world size
- Checking for server performance issues

### Q: What happens if I kill the wrapper process manually?

**A:** The PowerShell.Exiting event handler will:
1. Clean up the PID file
2. Log the cleanup action

However, the SCUM server process will become orphaned and continue running. The next wrapper start will detect and terminate it.

**Best Practice:** Always use AMP's Stop button instead of killing processes manually.

### Q: Can I adjust the 30-second failsafe timeout?

**A:** Yes, but it requires editing the wrapper script:

1. Open `SCUMWrapper.ps1`
2. Find the line: `Set-Variable -Name FAILSAFE_TIMEOUT -Value 30 -Option Constant`
3. Change `30` to your desired timeout (in seconds)
4. Save and restart the server

**Recommendation:** Only increase if you have evidence that saves take longer than 30 seconds. Check wrapper logs for actual shutdown times.

### Q: Why does the wrapper use two different shutdown modes?

**A:** The two-mode system optimizes for different scenarios:

**ABORT MODE (< 30 seconds uptime):**
- Server is still initializing
- No players connected yet
- No data to save
- Immediate force kill is safe and fast

**GRACEFUL MODE (≥ 30 seconds uptime):**
- Server is fully running
- Players may be connected
- Data must be saved
- Graceful shutdown prevents corruption

### Q: What's the difference between wrapper logs and server logs?

**A:** 

**Wrapper Logs** (`Binaries/Win64/Logs/SCUMWrapper_*.log`):
- Process management (start/stop/restart)
- Shutdown decisions (abort vs graceful)
- PID file operations
- Orphan cleanup
- Signal sending

**Server Logs** (`Saved/Logs/SCUM.log`):
- Game events (player joins, deaths, etc.)
- Server errors and warnings
- Save operations
- LogExit pattern (shutdown confirmation)

Both are needed for complete troubleshooting.

### Q: How do I know if my last shutdown was safe?

**A:** Check the wrapper log for the shutdown completion message:

✓ **SAFE:**
```
Shutdown completed successfully in 8.2s (graceful, LogExit detected)
```

⚠ **UNCERTAIN:**
```
Shutdown completed in 5.1s (process exited, no LogExit)
```

✗ **UNSAFE:**
```
Shutdown completed in 30.5s (failsafe timeout, force killed)
```

### Q: Can I run multiple SCUM servers on the same machine?

**A:** Yes, but each must have its own AMP instance with:
- Separate installation directory
- Different ports (Port, QueryPort, etc.)
- Separate PID file (automatic per directory)

The wrapper's singleton enforcement is per-directory, not system-wide.

### Q: What happens during scheduled restarts?

**A:** AMP sends Ctrl+C to the wrapper, which:
1. Detects shutdown request
2. Checks server uptime
3. Uses graceful shutdown (if uptime ≥ 30s)
4. Waits for LogExit pattern
5. Exits cleanly
6. AMP starts new instance

The wrapper ensures the old instance fully terminates before AMP starts the new one.

### Q: Why do I see "Removing stale PID file" messages?

**A:** This happens when:
- Previous wrapper crashed without cleanup
- PID file is older than 5 minutes
- Referenced process no longer exists

This is normal recovery behavior and not an error. The wrapper automatically cleans up stale files.

### Q: How can I verify the wrapper is working correctly?

**A:** Perform this test:

1. Start server in AMP
2. Wait 60 seconds (ensure uptime > 30s)
3. Click Stop in AMP
4. Check wrapper log for:
   ```
   [WRAPPER-DEBUG] LogExit pattern detected! Server saved successfully.
   Shutdown completed successfully in X.Xs (graceful, LogExit detected)
   ```

If you see this, the wrapper is working perfectly.

---

## Advanced Troubleshooting

### Enabling Debug Logging

Debug logging is already enabled by default. All state transitions are logged with `[WRAPPER-DEBUG]` prefix.

To view only debug messages:
```powershell
Get-Content "Binaries\Win64\Logs\SCUMWrapper_*.log" | Select-String "DEBUG"
```

### Monitoring Shutdown in Real-Time

Open two PowerShell windows:

**Window 1 - Wrapper Log:**
```powershell
Get-Content "Binaries\Win64\Logs\SCUMWrapper_$(Get-Date -Format 'yyyy-MM-dd').log" -Wait -Tail 20
```

**Window 2 - Server Log:**
```powershell
Get-Content "Saved\Logs\SCUM.log" -Wait -Tail 20
```

Then click Stop in AMP and watch both logs simultaneously.

### Checking for Orphan Processes

```powershell
# List all SCUM server processes
Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue | 
    Select-Object Id, StartTime, @{Name="Uptime";Expression={(Get-Date) - $_.StartTime}}

# Kill all orphan processes (use with caution!)
Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue | Stop-Process -Force
```

### Analyzing Shutdown Times

Extract shutdown times from logs:
```powershell
Get-Content "Binaries\Win64\Logs\SCUMWrapper_*.log" | 
    Select-String "Shutdown completed" | 
    Select-Object -Last 10
```

Look for patterns:
- Consistently long shutdowns (> 25s) → Performance issue
- Frequent failsafe timeouts → Server stability issue
- Frequent "no LogExit" warnings → Save system issue

### Testing Graceful Shutdown

Manual test script:
```powershell
# Start server
& ".\SCUMWrapper.ps1" Port=7042 QueryPort=7043

# In another window, wait 60 seconds, then:
Get-Process -Name "powershell" | Where-Object { $_.MainWindowTitle -match "SCUMWrapper" } | 
    ForEach-Object { $_.CloseMainWindow() }

# Check logs for graceful shutdown confirmation
```

### Recovering from Corruption

If database corruption occurs:

1. **Stop the server immediately**
2. **Check for backups** in `Saved/SaveGames/`
3. **Restore from most recent backup** before corruption
4. **Review logs** to identify cause
5. **Prevent recurrence** by ensuring graceful shutdowns

### Performance Monitoring

Monitor wrapper resource usage:
```powershell
Get-Process -Name "powershell" | 
    Where-Object { $_.MainWindowTitle -match "SCUMWrapper" } |
    Select-Object Id, CPU, WorkingSet, StartTime
```

The wrapper should use minimal resources (< 1% CPU, < 50MB RAM).

---

## Getting Help

If you're still experiencing issues:

1. **Collect logs:**
   - Latest wrapper log: `Binaries/Win64/Logs/SCUMWrapper_*.log`
   - Latest server log: `Saved/Logs/SCUM.log`
   - AMP console output

2. **Document the issue:**
   - What were you doing when it happened?
   - Is it reproducible?
   - What error messages did you see?

3. **Check for known issues:**
   - CubeCoders AMP Discord
   - SCUM official Discord
   - GitHub issues (if applicable)

4. **Provide details:**
   - Wrapper version (check first line of log)
   - AMP version
   - SCUM server version
   - Windows version
   - Hardware specs (especially disk type: SSD vs HDD)

---

## Version History

- **v3.0** - Current version
  - Graceful shutdown with LogExit detection
  - Failsafe timeout (30s)
  - Orphan process cleanup
  - Singleton enforcement with PID file
  - Uptime-based shutdown decision
  - Comprehensive logging
  - Event-based cleanup handlers
