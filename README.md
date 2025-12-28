# SCUM AMP Graceful Shutdown Fix - README

## Quick Start

This solution fixes SCUM Dedicated Server database rollback issues on AMP by implementing proper graceful shutdown instead of immediate process termination.

##  Problem

- When stopping SCUM server through AMP, the process is killed immediately
- Database doesn't save properly → rollback on next start
- Missing proper shutdown logs ("SHUTTING DOWN" messages)

## Solution

PowerShell wrapper script that intercepts shutdown signals and properly forwards Ctrl+C to SCUM server process using Windows APIs.

## Files

- **scum.kvp** - Modified AMP template configuration  
- **SCUM\Binaries\Win64\SCUMWrapper.ps1** - Wrapper script

## Changes Made

### Template Configuration (scum.kvp)
- Execute through PowerShell wrapper instead of direct .exe
- Enable `CtrlC` exit method
- Increase timeout to 60 seconds
- Enable writeable console

### Wrapper Script (SCUMWrapper.ps1)
- Uses Windows API `GenerateConsoleCtrlEvent` to send proper Ctrl+C
- Attaches to child process console for signal delivery
- Waits up to 60 seconds for graceful exit
- Falls back to force kill if timeout reached
- Detailed logging for troubleshooting

## Quick Test (Without AMP)

```powershell
cd "C:\path\to\SCUM_Server\3792580\SCUM\Binaries\Win64"
powershell.exe -ExecutionPolicy Bypass -File "SCUMWrapper.ps1" SCUM -Port=7042 -QueryPort=7043 -MaxPlayers=64 -log

# Press Ctrl+C after server starts
# Check logs for graceful shutdown messages
```

## Deployment to AMP

1. **Back up current template**: Copy `scum.kvp` to `scum.kvp.backup`

2. **Deploy files**:
   - Copy `scum.kvp` to `<AMP_DATA>\AMPTemplates\`
   - Copy `SCUMWrapper.ps1` to each instance's `3792580\SCUM\Binaries\Win64\`

3. **Update instance**: Stop server, update/restart AMP, start server

4. **Verify**: Stop server and check logs for proper shutdown sequence

## Expected Results

### Before (❌ Immediate Kill)
```
< Server running >
< Instant termination - no shutdown logs >
< Database rollback warning on next start >
```

### After (✅ Graceful Shutdown)
```
[Wrapper] Initiating graceful shutdown...
[Wrapper] Ctrl+C signal sent successfully.
LogCore: *** INTERRUPTED *** : SHUTTING DOWN
LogSCUM: [Basebuilding] Saving base data.
LogDatabase: Closing connection to 'SCUM.db'...
[Wrapper] Process exited gracefully after 35 seconds.
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| API not loading | Uses fallback automatically; upgrade .NET if needed |
| Still immediate kill | Verify template settings applied, wrapper in correct location |
| Timeout during shutdown | Increase `App.ExitTimeout` value |
| Execution policy error | Template uses `-ExecutionPolicy Bypass`, should work automatically |

## Documentation

See artifacts folder for detailed documentation:
- **walkthrough.md** - Technical details, testing, troubleshooting
- **implementation_plan.md** - Design decisions and verification plan
- **task.md** - Implementation checklist

## Support

If issues persist after deployment:
1. Check wrapper console output for error messages
2. Review SCUM logs for shutdown sequence
3. Verify template configuration applied correctly
4. Test wrapper script manually outside AMP

---

**Status**: ✅ Ready for Deployment  
**Tested**: Manual wrapper test  
**Requires**: AMP deployment and verification
