$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$profileDir = Join-Path $env:USERPROFILE "whatsapp-automation-profile"
$debugPort = 9222
$pidFile = Join-Path $root ".running-pids.txt"

# ------------------------------------------------------------------
# Which Node entry point to launch alongside Chrome:
#   "server.js"    -> manual Send Line test console (Supabase OFF)
#   "scheduler.js" -> real Supabase-driven scheduler
# Switch this once you've finished testing and enabled Supabase.
# ------------------------------------------------------------------
$entryFile = "server.js"

if (Test-Path $pidFile) { Remove-Item $pidFile }

# --- Locate Chrome ---
$chromeCandidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
)
$chromePath = $chromeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chromePath) {
    Write-Host "Could not find chrome.exe in the default install locations." -ForegroundColor Red
    Write-Host "Edit start-all.ps1 and set `$chromePath manually to your Chrome install path." -ForegroundColor Red
    exit 1
}

# --- Start Chrome with remote debugging + dedicated profile ---
Write-Host "Starting Chrome (remote debugging on port $debugPort)..."
$chromeProc = Start-Process -FilePath $chromePath `
    -ArgumentList "--remote-debugging-port=$debugPort", "--user-data-dir=$profileDir", "https://web.whatsapp.com" `
    -PassThru
"chrome=$($chromeProc.Id)" | Out-File -FilePath $pidFile -Append -Encoding ascii

Write-Host "Waiting for Chrome to settle..."
Start-Sleep -Seconds 4

# --- Start the Node process (test console or scheduler) ---
Write-Host "Starting $entryFile ..."
$nodeProc = Start-Process -FilePath "node" `
    -ArgumentList $entryFile `
    -WorkingDirectory $root `
    -WindowStyle Minimized `
    -PassThru
"node=$($nodeProc.Id)" | Out-File -FilePath $pidFile -Append -Encoding ascii

Write-Host ""
Write-Host "All started." -ForegroundColor Green
Write-Host "  Chrome PID : $($chromeProc.Id)"
Write-Host "  Node PID   : $($nodeProc.Id)  ($entryFile)"
Write-Host ""
if ($entryFile -eq "server.js") {
    Write-Host "Open http://localhost:4545 for the Send Line test console." -ForegroundColor Cyan
} else {
    Write-Host "Scheduler is running in the background, polling Supabase." -ForegroundColor Cyan
}
Write-Host "Log into WhatsApp Web in the Chrome window if this is the first run."
Write-Host "Run stop-all.bat when you're done."
