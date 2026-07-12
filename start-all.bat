@echo off
REM Double-click this to start Chrome (linked to WhatsApp Web) and the
REM Node app together in one go. Run stop-all.bat to shut both down.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-all.ps1"
echo.
pause
