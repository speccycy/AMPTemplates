@echo off
REM SCUM Wrapper Script for AMP
REM This script launches SCUM and handles the shutdown signal
REM Usage: Place this in the same folder as SCUMServer.exe (Binaries\Win64)

echo [Wrapper] Starting SCUM Server...
echo [Wrapper] Arguments: %*

REM Launch SCUM directly. 
REM AMP sends Ctrl+C to this CMD window, which propagates to the child process.
"%~dp0SCUMServer.exe" %*

echo [Wrapper] SCUM Server exited with code %ERRORLEVEL%
