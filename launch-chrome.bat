@echo off
REM Launches Chrome with a remote debugging port open, using a DEDICATED
REM profile folder (so your WhatsApp Web login persists between launches
REM and never mixes with your normal everyday Chrome profile/history).
REM
REM Run this file first, log into WhatsApp Web when the page opens,
REM then start the Node scheduler (npm start) in a separate terminal.

set CHROME_PATH="C:\Program Files\Google\Chrome\Application\chrome.exe"
set PROFILE_DIR=%USERPROFILE%\whatsapp-automation-profile
set DEBUG_PORT=9222

if not exist %CHROME_PATH% (
    set CHROME_PATH="C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
)

start "" %CHROME_PATH% --remote-debugging-port=%DEBUG_PORT% --user-data-dir="%PROFILE_DIR%" "https://web.whatsapp.com"

echo Chrome launched with debugging port %DEBUG_PORT%.
echo Scan the WhatsApp Web QR code in the window that just opened.
echo Once logged in, run "npm start" to begin the scheduler.
pause
