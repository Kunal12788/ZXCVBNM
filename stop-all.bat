@echo off
REM Double-click this to stop everything start-all.bat started
REM (the debug Chrome window and the Node process).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-all.ps1"
echo.
pause
