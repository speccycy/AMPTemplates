# SCUM AMP Graceful Shutdown System - Deployment Checklist

**Version:** 3.0  
**Date:** January 2, 2026  
**Status:** Ready for Production

## Pre-Deployment Verification

### 1. File Deployment

Ensure all required files are in place:

- [ ] `AMPTemplates/scum.kvp` - AMP template configuration
- [ ] `AMPTemplates/scumconfig.json` - Server settings configuration
- [ ] `AMPTemplates/scummetaconfig.json` - Meta configuration
- [ ] `AMPTemplates/scumports.json` - Port configuration
- [ ] `AMPTemplates/scumupdates.json` - Update configuration
- [ ] `AMPTemplates/SCUM/Binaries/Win64/SCUMWrapper.ps1` - Wrapper script v3.0
- [ ] `AMPTemplates/SCUM/Binaries/Win64/Logs/` - Log directory (created automatically)

### 2. Configuration Verification

Run the automated pre-flight check:

```powershell
cd AMPTemplates/SCUM/Binaries/Win64
.\Test-AMPIntegration.ps1
```

**Expected Results:**
- ✅ Wrapper script exists
- ✅ No orphan processes
- ✅ No stale PID file
- ✅ PowerShell version 5.0+
- ✅ Log directory exists
- ✅ Windows API available
- ✅ Execution policy allows scripts

**Acceptable Warnings:**
- ⚠️ SCUM server executable not found (if not yet installed)
- ⚠️ SCUM log file not found (if server never ran)
- ⚠️ scum.kvp not found (if in different location)

### 3. AMP Configuration Review

Verify these settings in `scum.kvp`:

```kvp
App.ExitMethod=OS_CLOSE
App.ExitMethodWindows=CtrlC
App.ExitTimeout=35
App.ExecutableWin=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
App.CommandLineArgs=-ExecutionPolicy Bypass -File "SCUM\Binaries\Win64\SCUMWrapper.ps1" ...
Console.AppReadyRegex=^\[WRAPPER-DEBUG\] State: RUNNING - Monitoring process\.\.\.|...
```

**Critical Settings:**
- [x] `App.ExitMethodWindows=CtrlC` - Enables graceful shutdown
- [x] `App.ExitTimeout=35` - Allows 30s failsafe + 5s buffer
- [x] Wrapper script invoked via PowerShell
- [x] Application ready detection includes wrapper state

## Deployment Steps

### Step 1: Install SCUM Server Files

1. Create AMP instance for SCUM
2. Install SCUM Dedicated Server via SteamCMD (App ID: 3792580)
3. Wait for installation to complete

### Step 2: Deploy Wrapper Script

1. Copy `SCUMWrapper.ps1` to `SCUM/Binaries/Win64/`
2. Verify file permissions (should be readable/executable)
3. Create `Logs` directory if it doesn't exist:
   ```powershell
   New-Item -ItemType Directory -Path "SCUM/Binaries/Win64/Logs" -Force
   ```

### Step 3: Verify AMP Template

1. In AMP, go to **Configuration** → **Application Configuration**
2. Verify the template is using the correct settings (see Configuration Review above)
3. If settings are incorrect, update `scum.kvp` and restart AMP

### Step 4: Initial Test

1. Click **Start** button in AMP
2. Monitor console for wrapper logs:
   - `[WRAPPER-INFO] SCUMWrapper v3.0 starting...`
   - `[WRAPPER-INFO] Wrapper PID: XXXXX`
   - `[WRAPPER-INFO] SCUM Server PID: XXXXX`
   - `[WRAPPER-DEBUG] State: RUNNING - Monitoring process...`
3. Verify server status changes to "Running" (green)
4. Wait 60 seconds
5. Click **Stop** button
6. Monitor console for graceful shutdown:
   - `[WRAPPER-INFO] Server is running - GRACEFUL SHUTDOWN MODE`
   - `[WRAPPER-INFO] Sending Ctrl+C signal to SCUM server`
   - `[WRAPPER-INFO] LogExit pattern detected! Server saved successfully.`
   - `[WRAPPER-INFO] Graceful shutdown confirmed - exiting cleanly`

**If Initial Test Fails:**
- Check wrapper logs in `SCUM/Binaries/Win64/Logs/`
- Verify PowerShell execution policy: `Get-ExecutionPolicy`
- Check for orphan processes: `Get-Process -Name SCUMServer`
- Review troubleshooting guide: `AMP_INTEGRATION_TEST_GUIDE.md`

## Post-Deployment Testing

### Quick Validation Tests

Run these tests to ensure everything works:

#### Test 1: Normal Stop (Graceful Shutdown)
1. Start server
2. Wait 60 seconds
3. Stop server
4. **Expected:** LogExit detected, clean shutdown in 5-15 seconds

#### Test 2: Quick Stop (Startup Abort)
1. Start server
2. Immediately stop (within 10 seconds)
3. **Expected:** Abort mode, immediate force kill in < 2 seconds

#### Test 3: Restart
1. Start server
2. Wait 60 seconds
3. Click Restart
4. **Expected:** Graceful shutdown, then new instance starts

#### Test 4: Orphan Recovery
1. Manually start SCUM server outside AMP
2. Start server via AMP
3. **Expected:** Orphan detected and terminated, new instance starts

### Full Integration Testing

For comprehensive testing, follow:
- **Test Guide:** `AMP_INTEGRATION_TEST_GUIDE.md`
- **9 detailed test scenarios** covering all operations
- **Expected results** and **troubleshooting** for each test

## Monitoring and Maintenance

### Daily Monitoring

Check these items daily:

- [ ] No orphan SCUM processes in Task Manager
- [ ] PID file cleaned up after shutdowns
- [ ] Wrapper logs show graceful shutdowns (not failsafe timeouts)
- [ ] No errors in wrapper logs

### Weekly Maintenance

Perform these tasks weekly:

- [ ] Review wrapper logs for patterns:
  - Frequent failsafe timeouts (indicates server issues)
  - Orphan process cleanups (indicates crash issues)
  - Singleton violations (indicates configuration issues)
- [ ] Verify log rotation working (logs > 7 days deleted)
- [ ] Check disk space in log directory

### Monthly Review

Perform these tasks monthly:

- [ ] Review shutdown timing metrics
- [ ] Analyze failsafe activation frequency
- [ ] Check for wrapper script updates
- [ ] Review AMP template updates

## Troubleshooting

### Issue: "Another wrapper instance is already running"

**Symptoms:**
- Server fails to start
- Error in console: `[WRAPPER-ERROR] Another wrapper instance is already running`

**Diagnosis:**
1. Check Task Manager for orphan processes
2. Check for stale PID file: `SCUM/Binaries/Win64/scum_server.pid`

**Solution:**
```powershell
# Stop any orphan processes
Get-Process -Name SCUMServer -ErrorAction SilentlyContinue | Stop-Process -Force

# Remove stale PID file
Remove-Item "SCUM/Binaries/Win64/scum_server.pid" -Force -ErrorAction SilentlyContinue

# Restart server via AMP
```

### Issue: Failsafe Timeout Always Activates

**Symptoms:**
- Every shutdown takes 30+ seconds
- Console shows: `[WRAPPER-WARNING] FAILSAFE_TIMEOUT - No LogExit after 30s!`

**Diagnosis:**
1. Check if LogExit pattern appears in SCUM log
2. Verify log file path is correct
3. Check for SCUM server version changes (pattern may have changed)

**Solution:**
1. Review recent SCUM.log file for exit pattern
2. If pattern changed, update wrapper script
3. If server is freezing, investigate server issues (mods, corruption)

### Issue: Orphan Processes After Shutdown

**Symptoms:**
- Multiple SCUM processes in Task Manager
- Port conflict errors on restart

**Diagnosis:**
1. Check wrapper logs for shutdown errors
2. Verify `App.ExitTimeout` is sufficient (35+ seconds)
3. Check if force kill is failing

**Solution:**
```powershell
# Manually clean up orphans
Get-Process -Name SCUMServer | Stop-Process -Force

# Increase timeout if needed (in scum.kvp)
App.ExitTimeout=40

# Restart AMP to apply changes
```

### Issue: Port Conflict on Restart

**Symptoms:**
- Server fails to start after restart
- Error: "Port already in use"

**Diagnosis:**
1. Old process not fully terminated
2. Race condition (new process starts too soon)

**Solution:**
1. Verify graceful shutdown is working (LogExit detected)
2. Increase `App.ExitTimeout` to 40 seconds
3. Check for orphan processes before restart

## Support Resources

### Documentation

- **Configuration Verification:** `AMP_CONFIGURATION_VERIFICATION.md`
- **Integration Test Guide:** `AMP_INTEGRATION_TEST_GUIDE.md`
- **Wrapper README:** `SCUM/Binaries/Win64/README.md`
- **Log Messages Reference:** `SCUM/Binaries/Win64/LOG_MESSAGES.md`
- **Troubleshooting Guide:** `SCUM/Binaries/Win64/TROUBLESHOOTING.md`

### Automated Tools

- **Pre-Flight Check:** `Test-AMPIntegration.ps1`
- **Test Runner:** `Tests/RunTests.ps1` (for developers)

### Requirements and Design

- **Requirements Document:** `.kiro/specs/scum-amp-graceful-shutdown/requirements.md`
- **Design Document:** `.kiro/specs/scum-amp-graceful-shutdown/design.md`
- **Task List:** `.kiro/specs/scum-amp-graceful-shutdown/tasks.md`

## Success Criteria

The deployment is successful when:

- ✅ Server starts reliably via AMP Start button
- ✅ Graceful shutdown works consistently (LogExit detected)
- ✅ Failsafe activates only when server is frozen/crashed
- ✅ No orphan processes after any operation
- ✅ PID file always cleaned up correctly
- ✅ Restart cycles work without issues
- ✅ Updates complete without file locking errors
- ✅ Singleton enforcement prevents duplicates
- ✅ Wrapper logs are clear and actionable

## Sign-Off

**Deployed By:** ___________________________  
**Deployment Date:** ___________________________  
**AMP Version:** ___________________________  
**Wrapper Version:** ___________________________  
**Initial Test Result:** ⏳ Pending / ✅ Passed / ❌ Failed  

**Notes:**
_____________________________________________
_____________________________________________
_____________________________________________

**Approved By:** ___________________________  
**Approval Date:** ___________________________

---

**Deployment Status:** ✅ Ready for Production  
**Last Updated:** January 2, 2026
