# Run-IntegrationTest.ps1 - offline integration test (no Graph tenant needed):
#   1. verify phase against real local files (one deliberately corrupted)
#   2. download phase worker-pool spin-up/shutdown with an empty queue
#   3. status snapshot content
#   4. dashboard HTTP server: page, APIs, control commands
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module PSSQLite
foreach ($m in @('Config','Logging','PathUtils','Database','GraphApi','Discovery','StatusReporter','Downloader','Verifier','Dashboard')) {
    Import-Module (Join-Path $root "src\$m.psm1") -Force -DisableNameChecking
}

$script:pass = 0; $script:fail = 0
function Assert {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red }
}

# ---------- setup: clean state, config, db, fake exported files ----------
$cfg = Get-ExportConfig -Path (Join-Path $root 'config.test.json')
if (Test-Path $cfg.databasePath) { Remove-Item $cfg.databasePath -Force }
if (Test-Path $cfg.destinationRoot) { Remove-Item $cfg.destinationRoot -Recurse -Force }
New-Item -ItemType Directory -Path $cfg.destinationRoot -Force | Out-Null
Initialize-Logging -LogDir $cfg.logDir
$conn = Open-ExportDb -Path $cfg.databasePath
Initialize-ExportDb -Conn $conn
Set-StateValue -Conn $conn -Key 'drive_id' -Value 'test-drive-id'

function New-SharedState {
    return [hashtable]::Synchronized(@{
        Stop = $false; UserPaused = $false; SystemPaused = $false; PauseReason = ''; LastControlTs = ''
        AccessToken = 'dummy-token'; TokenExpiresOn = [DateTimeOffset]::UtcNow.AddHours(1); TokenExpired = $false
        BackoffUntil = $null; LastBackoffReason = ''; Throttle429 = 0; Throttle5xx = 0
        DriveId = 'test-drive-id'; Phase = 'test'; DiscoveryPages = 0; QuotaUsedBytes = [int64]0
        SessionStart = [datetime]::UtcNow; SessionDownloaded = [int64]0; SessionSkippedExisting = [int64]0
        SessionFailed = [int64]0; SessionRetries = [int64]0
        LastSampleTime = $null; LastSampleBytes = [int64]0; EmaBps = $null; History = $null; DashboardError = $null
        Workers = [hashtable]::Synchronized(@{}); WorkerBytes = [hashtable]::Synchronized(@{})
        RecentErrors = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    })
}
$refreshStub = { }

# Three "downloaded" files: good (with correct quickxor), corrupt (wrong size on disk), hash-mismatch
$goodContent = [System.Text.Encoding]::ASCII.GetBytes('The quick brown fox jumps over the lazy dog')
$goodPath = Join-Path $cfg.destinationRoot 'docs\good.txt'
New-Item -ItemType Directory -Path (Split-Path $goodPath) -Force | Out-Null
[System.IO.File]::WriteAllBytes($goodPath, $goodContent)
$goodHash = Get-QuickXorHash -Path $goodPath

$corruptPath = Join-Path $cfg.destinationRoot 'docs\corrupt.txt'
[System.IO.File]::WriteAllBytes($corruptPath, [byte[]](1..10))      # manifest will claim 999 bytes

$badHashPath = Join-Path $cfg.destinationRoot 'docs\badhash.txt'
[System.IO.File]::WriteAllBytes($badHashPath, $goodContent)

$rows = @(
    @{ id='g1'; parent_id='d'; name='good.txt';    rel_path='docs\good.txt';    is_folder=0; size=[int64]$goodContent.Length; last_modified=$null; created=$null; etag='e1'; ctag=$null; quickxor=$goodHash; status='downloaded'; local_path=$goodPath;    error=$null },
    @{ id='g2'; parent_id='d'; name='corrupt.txt'; rel_path='docs\corrupt.txt'; is_folder=0; size=[int64]999;                 last_modified=$null; created=$null; etag='e2'; ctag=$null; quickxor=$null;     status='downloaded'; local_path=$corruptPath; error=$null },
    @{ id='g3'; parent_id='d'; name='badhash.txt'; rel_path='docs\badhash.txt'; is_folder=0; size=[int64]$goodContent.Length; last_modified=$null; created=$null; etag='e3'; ctag=$null; quickxor='WRONGHASHWRONGHASHWRONGHASH='; status='downloaded'; local_path=$badHashPath; error=$null }
)
Save-DiscoveryPage -Conn $conn -Rows $rows

# ---------- 1) verify phase (config.test.json has verifyMode=hash) ----------
Write-Host "`n--- Verify phase ---"
$Shared = New-SharedState
$vr = Invoke-VerifyPhase -Config $cfg -Conn $conn -Shared $Shared
Assert ($vr.Verified -eq 1) 'good file verified' "verified=$($vr.Verified)"
Assert ($vr.Requeued -eq 2) 'corrupt + bad-hash re-queued' "requeued=$($vr.Requeued)"
Assert ((Invoke-Db -Conn $conn -Query "SELECT status FROM items WHERE id='g1'").status -eq 'verified') 'g1 -> verified'
Assert ((Invoke-Db -Conn $conn -Query "SELECT status FROM items WHERE id='g2'").status -eq 'queued') 'g2 -> queued (size mismatch)'
Assert ((Invoke-Db -Conn $conn -Query "SELECT status FROM items WHERE id='g3'").status -eq 'queued') 'g3 -> queued (hash mismatch)'

# ---------- 2) download phase: worker pool spin-up with empty queue ----------
# Remove the queued rows so the pool has nothing to fetch (we can't reach Graph);
# the pool must start N workers, detect completion, and shut down cleanly.
Invoke-Db -Conn $conn -Query "DELETE FROM items WHERE status='queued'" | Out-Null
Write-Host "`n--- Download phase (empty queue, pool lifecycle) ---"
$Shared = New-SharedState
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Invoke-DownloadPhase -Config $cfg -Conn $conn -Shared $Shared -SrcDir (Join-Path $root 'src') -RefreshToken $refreshStub
$sw.Stop()
Assert ($true) "download phase completed cleanly in $([int]$sw.Elapsed.TotalSeconds)s"
Assert ($sw.Elapsed.TotalSeconds -lt 60) 'no hang on empty queue'
$leftover = @(Get-Job -Name 'odx-worker-*' -ErrorAction SilentlyContinue)
Assert ($leftover.Count -eq 0) 'worker jobs cleaned up' "leftover=$($leftover.Count)"
Assert ($Shared.Workers.Keys.Count -eq 2) 'all configured workers ran' "registered=$($Shared.Workers.Keys.Count)"
Assert ($Shared.Stop -eq $false) 'global Stop untouched by pool shutdown (dashboard survives phase end)' "Stop=$($Shared.Stop)"
Assert ($Shared.PoolStop -eq $true) 'pool shutdown used PoolStop'

# ---------- 3) status snapshot ----------
Write-Host "`n--- Status snapshot ---"
$statusFile = Join-Path $cfg.statusDir 'status.json'
Assert (Test-Path $statusFile) 'status.json written'
$s = Get-Content $statusFile -Raw | ConvertFrom-Json
Assert ($s.totals.files -eq 1) 'totals.files correct (g1 only after queue purge)' "files=$($s.totals.files)"
Assert ($s.totals.doneFiles -eq 1) 'verified file counted done' "done=$($s.totals.doneFiles)"
Assert ($null -ne $s.generatedAt -and $null -ne $s.config.destination) 'snapshot has metadata'
$failFile = Join-Path $cfg.statusDir 'failures.json'
Assert (Test-Path $failFile) 'failures.json written'

# ---------- 4) dashboard HTTP server ----------
Write-Host "`n--- Dashboard ---"
$Shared = New-SharedState
$port = 8790
$job = Start-DashboardJob -Port $port -WebRoot $cfg.webRoot -StatusDir $cfg.statusDir -LogDir $cfg.logDir -ControlFile $cfg.controlFile -Shared $Shared
Start-Sleep -Seconds 2
if ($Shared.DashboardError) {
    Assert $false 'dashboard started' $Shared.DashboardError
} else {
    $html = Invoke-WebRequest -Uri "http://localhost:$port/" -UseBasicParsing
    Assert ($html.StatusCode -eq 200 -and $html.Content -match 'OneDrive Export') 'GET / serves dashboard page'
    $api = Invoke-RestMethod -Uri "http://localhost:$port/api/status"
    Assert ($api.totals.files -eq 1) 'GET /api/status serves parseable JSON' "files=$($api.totals.files)"
    $logTail = Invoke-WebRequest -Uri "http://localhost:$port/api/log?lines=50" -UseBasicParsing
    Assert ($logTail.StatusCode -eq 200 -and $logTail.Content.Length -gt 0) 'GET /api/log serves tail'
    $ctl = Invoke-RestMethod -Uri "http://localhost:$port/api/control" -Method Post -Body '{"command":"pause"}'
    Assert ($ctl.ok -eq $true) 'POST /api/control accepts pause'
    Start-Sleep -Milliseconds 300
    $ctlFile = Get-Content $cfg.controlFile -Raw | ConvertFrom-Json
    Assert ($ctlFile.command -eq 'pause' -and $ctlFile.ts) 'control.json written with timestamp'
    $bad = Invoke-WebRequest -Uri "http://localhost:$port/api/control" -Method Post -Body '{"command":"format-c"}' -SkipHttpErrorCheck
    Assert ($bad.StatusCode -eq 400) 'invalid command rejected'
    $nf = Invoke-WebRequest -Uri "http://localhost:$port/nope" -SkipHttpErrorCheck
    Assert ($nf.StatusCode -eq 404) 'unknown route 404s'
}
$Shared.Stop = $true
Wait-Job -Job $job -Timeout 10 | Out-Null
Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
Assert ($true) 'dashboard shut down'

# ---------- 4b) wide worker pool (regression: Start-ThreadJob ThrottleLimit=5 default) ----------
# With the default thread-job pool limit of 5, an 8-worker pool silently ran
# only 5 workers (4 with the dashboard job holding a slot). Every configured
# worker must actually start and register itself.
Write-Host "`n--- Wide worker pool (8 workers) ---"
$Shared = New-SharedState
$cfg8 = $cfg.PSObject.Copy()
$cfg8.concurrency = 8
Invoke-DownloadPhase -Config $cfg8 -Conn $conn -Shared $Shared -SrcDir (Join-Path $root 'src') -RefreshToken $refreshStub
Assert ($Shared.Workers.Keys.Count -eq 8) 'all 8 workers started and registered' "registered=$($Shared.Workers.Keys.Count)"
$leftover8 = @(Get-Job -Name 'odx-worker-*' -ErrorAction SilentlyContinue)
Assert ($leftover8.Count -eq 0) 'wide pool cleaned up' "leftover=$($leftover8.Count)"

# ---------- 5) snapshot thread-safety hammer (regression: live crash 2026-07-23) ----------
# Enumerating a synchronized hashtable while workers mutate it invalidates the
# enumerator. Three writer threads hammer WorkerBytes/Workers while snapshots
# run in a tight loop; pre-fix this crashed within ~1 second.
Write-Host "`n--- Snapshot thread-safety hammer ---"
$Shared = New-SharedState
$writers = foreach ($i in 1..3) {
    Start-ThreadJob -ArgumentList @($Shared, $i) -ScriptBlock {
        param($Shared, $id)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 5) {
            $Shared.WorkerBytes[$id] = [int64]$Shared.WorkerBytes[$id] + 1
            $Shared.Workers[$id] = @{ state = 'downloading'; file = "f$id"; bytes = 1; total = 2 }
        }
    }
}
$hammerErr = $null
$snaps = 0
try {
    $end = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $end) {
        Write-StatusSnapshot -Conn $conn -Shared $Shared -Config $cfg
        $snaps++
    }
} catch { $hammerErr = $_.Exception.Message }
foreach ($w in $writers) { Wait-Job -Job $w -Timeout 15 | Out-Null; Remove-Job -Job $w -Force -ErrorAction SilentlyContinue }
Assert ($null -eq $hammerErr) "snapshots safe under concurrent worker writes ($snaps snapshots)" $hammerErr

Close-ExportDb -Conn $conn
Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor ($(if ($script:fail -eq 0) { 'Green' } else { 'Red' }))
exit $script:fail
