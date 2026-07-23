<#
.SYNOPSIS
    Watchdog wrapper: runs the exporter and restarts it automatically if it
    exits with an error (crash, unhandled exception). Exits when the run
    completes cleanly or the operator stops it.
.EXAMPLE
    pwsh -File .\tools\Start-WithAutoRestart.ps1 -Mode Full
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'),
    [ValidateSet('Full', 'Discover', 'Download', 'Verify', 'RetryFailed')]
    [string]$Mode = 'Full',
    [int]$RestartDelaySec = 60,
    [int]$MaxRestarts = 100
)
$ErrorActionPreference = 'Continue'
$exporter = Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-OneDriveExport.ps1'
$pwshExe = (Get-Process -Id $PID).Path

for ($attempt = 0; $attempt -le $MaxRestarts; $attempt++) {
    if ($attempt -gt 0) {
        Write-Host ("[watchdog] restart #{0} in {1}s..." -f $attempt, $RestartDelaySec) -ForegroundColor Yellow
        Start-Sleep -Seconds $RestartDelaySec
    }
    # -ExitOnComplete so a finished run ends the loop instead of holding the prompt
    & $pwshExe -NoProfile -File $exporter -ConfigPath $ConfigPath -Mode $Mode -ExitOnComplete
    if ($LASTEXITCODE -eq 0) {
        Write-Host '[watchdog] exporter finished cleanly - done.' -ForegroundColor Green
        exit 0
    }
    Write-Host ("[watchdog] exporter exited with code {0}" -f $LASTEXITCODE) -ForegroundColor Red
}
Write-Host "[watchdog] gave up after $MaxRestarts restarts - check logs." -ForegroundColor Red
exit 1
