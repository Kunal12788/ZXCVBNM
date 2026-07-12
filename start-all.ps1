$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$profileDir = Join-Path $env:USERPROFILE "whatsapp-automation-profile"
$envFile = Join-Path $root ".env"
$pidFile = Join-Path $root ".running-pids.txt"
$debugPort = 9222
$testUiPort = 4545

if (Test-Path $envFile) {
    $envContent = Get-Content $envFile -Raw
    if ($envContent -match "CHROME_DEBUG_PORT=(\d+)") {
        $debugPort = [int]$Matches[1]
    }
    if ($envContent -match "TEST_UI_PORT=(\d+)") {
        $testUiPort = [int]$Matches[1]
    }
}

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

# --- Start the Node processes ---
Write-Host "Starting server.js (local UI on port $testUiPort)..."
$serverProc = Start-Process -FilePath "node" `
    -ArgumentList "server.js" `
    -WorkingDirectory $root `
    -WindowStyle Minimized `
    -PassThru
"node=$($serverProc.Id)" | Out-File -FilePath $pidFile -Append -Encoding ascii

# --- Check if Supabase keys are configured in .env ---
$hasSupabase = $false
if (Test-Path $envFile) {
    $envContent = Get-Content $envFile -Raw
    # Check if the variables are populated with something other than placeholder text
    if ($envContent -match "SUPABASE_URL=https://[^\s]+" -and $envContent -match "SUPABASE_SERVICE_ROLE_KEY=[^y\s][^\s]+") {
        $hasSupabase = $true
    }
}

if ($hasSupabase) {
    Write-Host "Supabase configured. Starting scheduler.js in background..." -ForegroundColor Green
    $schedulerProc = Start-Process -FilePath "node" `
        -ArgumentList "scheduler.js" `
        -WorkingDirectory $root `
        -WindowStyle Minimized `
        -PassThru
    "node=$($schedulerProc.Id)" | Out-File -FilePath $pidFile -Append -Encoding ascii
} else {
    Write-Host "Supabase credentials not configured in .env. Skipping scheduler.js." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "All started." -ForegroundColor Green
Write-Host "  Chrome PID : $($chromeProc.Id)"
Write-Host "  Server PID : $($serverProc.Id) (server.js)"
if ($hasSupabase) {
    Write-Host "  Scheduler PID : $($schedulerProc.Id) (scheduler.js)"
}
Write-Host ""
Write-Host "Open http://localhost:$testUiPort for the Direct Mode console." -ForegroundColor Cyan
if ($hasSupabase) {
    Write-Host "Scheduler is running in the background, polling Supabase for messages." -ForegroundColor Cyan
}
Write-Host "Log into WhatsApp Web in the Chrome window if this is the first run."
Write-Host "Run stop-all.bat when you're done to shut down all processes."
