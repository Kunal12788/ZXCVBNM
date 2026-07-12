$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $root ".running-pids.txt"

if (-not (Test-Path $pidFile)) {
    Write-Host "Nothing to stop — no .running-pids.txt found." -ForegroundColor Yellow
    Write-Host "(This shows up if things were started manually instead of via start-all.bat.)" -ForegroundColor Yellow
    exit 0
}

$lines = Get-Content $pidFile
$stoppedAny = $false

foreach ($line in $lines) {
    if ($line -match "^(\w+)=(\d+)$") {
        $label = $matches[1]
        $procId = [int]$matches[2]

        $stillRunning = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($stillRunning) {
            # /T kills the whole process tree (e.g. Chrome's child renderer
            # processes too, not just the top-level process)
            taskkill /PID $procId /T /F | Out-Null
            Write-Host "Stopped $label (PID $procId)." -ForegroundColor Green
            $stoppedAny = $true
        } else {
            Write-Host "$label (PID $procId) was already not running." -ForegroundColor Yellow
        }
    }
}

Remove-Item $pidFile

Write-Host ""
if ($stoppedAny) {
    Write-Host "All tracked processes stopped." -ForegroundColor Green
} else {
    Write-Host "Nothing was actually running." -ForegroundColor Yellow
}
