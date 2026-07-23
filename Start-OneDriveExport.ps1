<#
.SYNOPSIS
    Exports a single OneDrive for Business user's drive to local storage (R:\).

.DESCRIPTION
    Long-running, resumable, throttling-aware export driven by a SQLite manifest.
    Phases: discovery (Graph delta enumeration) -> download (worker pool) ->
    verify -> summary. A local web dashboard runs at http://localhost:<port>/.

.PARAMETER Mode
    Full        discovery + download + verify (default)
    Discover    discovery only ("dry run")
    Download    download only (uses existing manifest)
    Verify      verify only (re-queues bad files but does not download)
    RetryFailed reset permanently-failed items and download again

.EXAMPLE
    pwsh -File .\Start-OneDriveExport.ps1 -ConfigPath .\config.json -Mode Full

.EXAMPLE
    pwsh -File .\Start-OneDriveExport.ps1 -Mode Discover      # dry run, no downloads
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [ValidateSet('Full', 'Discover', 'Download', 'Verify', 'RetryFailed')]
    [string]$Mode = 'Full',
    [switch]$FullRescan,      # discard the delta cursor and re-enumerate everything
    [switch]$NoDashboard,
    [switch]$ExitOnComplete   # exit immediately when done (for scheduled tasks) instead of keeping the dashboard up
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ is required. Install with:  winget install Microsoft.PowerShell   then run via 'pwsh'."
}

# ---------- dependencies ----------
if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
    Write-Host 'PSSQLite module not found - installing for current user...' -ForegroundColor Yellow
    Install-Module PSSQLite -Scope CurrentUser -Force
}
Import-Module PSSQLite
if (-not (Get-Module -ListAvailable -Name ThreadJob) -and -not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
    Install-Module ThreadJob -Scope CurrentUser -Force
}

$srcDir = Join-Path $PSScriptRoot 'src'
foreach ($m in @('Config', 'Logging', 'PathUtils', 'Database', 'GraphAuth', 'GraphApi', 'Discovery', 'StatusReporter', 'Downloader', 'Verifier', 'Dashboard')) {
    Import-Module (Join-Path $srcDir "$m.psm1") -Force -DisableNameChecking
}

# ---------- config / logging / db ----------
$cfg = Get-ExportConfig -Path $ConfigPath
Initialize-Logging -LogDir $cfg.logDir
Write-Log -Level INFO -Console -Message '=== OneDrive export starting ===' -Data @{ mode = $Mode; user = $cfg.userPrincipalName; auth = $cfg.authMode; dest = $cfg.destinationRoot }

$conn = Open-ExportDb -Path $cfg.databasePath
Initialize-ExportDb -Conn $conn

# A control file left over from a previous run (e.g. its final 'stop') must not
# affect this run - commands are only valid for the session they were issued in.
if (Test-Path -LiteralPath $cfg.controlFile) { Remove-Item -LiteralPath $cfg.controlFile -Force -ErrorAction SilentlyContinue }

# ---------- shared session state (visible to all worker threads) ----------
$Shared = [hashtable]::Synchronized(@{
    Stop                   = $false
    PoolStop               = $false
    UserPaused             = $false
    SystemPaused           = $false
    PauseReason            = ''
    LastControlTs          = ''
    AccessToken            = ''
    TokenExpiresOn         = [DateTimeOffset]::MinValue
    TokenExpired           = $false
    BackoffUntil           = $null
    LastBackoffReason      = ''
    Throttle429            = 0
    Throttle5xx            = 0
    DriveId                = ''
    Phase                  = 'init'
    DiscoveryPages         = 0
    QuotaUsedBytes         = [int64]0
    SessionStart           = [datetime]::UtcNow
    SessionDownloaded      = [int64]0
    SessionSkippedExisting = [int64]0
    SessionFailed          = [int64]0
    SessionRetries         = [int64]0
    LastSampleTime         = $null
    LastSampleBytes        = [int64]0
    EmaBps                 = $null
    History                = $null
    DashboardError         = $null
    Workers                = [hashtable]::Synchronized(@{})
    WorkerBytes            = [hashtable]::Synchronized(@{})
    RecentErrors           = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
})

# Restore quota estimate from a previous run so the dashboard has context early.
$savedQuota = Get-StateValue -Conn $conn -Key 'quota_used'
if ($savedQuota) { $Shared.QuotaUsedBytes = [int64]$savedQuota }

# ---------- token management ----------
# Called frequently by every phase; refreshes ~10 minutes before expiry, and
# retries forever (with pauses) rather than crashing a week-long run.
$refreshToken = {
    if (-not $Shared.TokenExpired -and $Shared.TokenExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(10)) { return }
    while (-not $Shared.Stop) {
        try {
            $tok = Get-GraphToken -Config $cfg -StateDir $cfg.stateDir
            $Shared.AccessToken = $tok.AccessToken
            $Shared.TokenExpiresOn = $tok.ExpiresOn
            $Shared.TokenExpired = $false
            Write-Log -Level DEBUG -Message 'Access token refreshed' -Data @{ expiresOn = $tok.ExpiresOn.ToString('o') }
            return
        } catch {
            Write-Log -Level ERROR -Message "Token acquisition failed - retrying in 60s: $($_.Exception.Message)"
            $end = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $end -and -not $Shared.Stop) { Start-Sleep -Seconds 1 }
        }
    }
}.GetNewClosure()

# ---------- helper functions ----------

function Wait-DashboardClose {
    # After a completed run, keep the web server up so the operator can review the
    # final result. Closes on ENTER at the console or Stop on the dashboard.
    param($Conn, $Config, [hashtable]$Shared)
    $Shared.Phase = 'complete'
    try {
        Write-StatusSnapshot -Conn $Conn -Shared $Shared -Config $Config
        Write-FailuresSnapshot -Conn $Conn -Config $Config
    } catch { }

    $canReadKeys = $true
    try { [void][console]::KeyAvailable } catch { $canReadKeys = $false }
    if (-not $canReadKeys) {
        Write-Log -Level INFO -Message 'No interactive console detected - skipping post-run dashboard hold-open (use -ExitOnComplete to silence this)'
        return
    }

    Write-Host ''
    Write-Host "Run complete. The dashboard is still available at http://localhost:$($Config.dashboardPort)/" -ForegroundColor Green
    Write-Host 'Press ENTER here (or use the Stop button on the dashboard) to shut down the web server and exit.' -ForegroundColor Green

    $lastSnap = [datetime]::UtcNow
    while (-not $Shared.Stop) {
        try {
            if ([console]::KeyAvailable) {
                $k = [console]::ReadKey($true)
                if ($k.Key -eq 'Enter') { break }
            }
        } catch { break }
        Read-ControlCommand -Config $Config -Shared $Shared
        # keep the snapshot fresh so the page doesn't show a staleness warning
        if (([datetime]::UtcNow - $lastSnap).TotalSeconds -ge 20) {
            $lastSnap = [datetime]::UtcNow
            try { Write-StatusSnapshot -Conn $Conn -Shared $Shared -Config $Config } catch { }
        }
        Start-Sleep -Milliseconds 400
    }
    Write-Host 'Shutting down web server...'
}

function Get-SummaryText {
    param($Conn)
    $rows = @(Get-DbStats -Conn $Conn)
    $lines = foreach ($r in $rows) {
        $kind = 'files'
        if ([int]$r.is_folder -eq 1) { $kind = 'folders' }
        '{0,-12} {1,-8} count={2,-8} bytes={3:N0}' -f $r.status, $kind, $r.cnt, $r.bytes
    }
    return ($lines -join "`n")
}

function Write-ExportSummary {
    param($Conn, $Config, [hashtable]$Shared)
    $text = Get-SummaryText -Conn $Conn
    $elapsed = [datetime]::UtcNow - [datetime]$Shared.SessionStart
    $wbSnap = Get-SyncSnapshot -Table $Shared.WorkerBytes
    $sessionBytes = [int64]0
    foreach ($v in $wbSnap.Values) { $sessionBytes += [int64]$v }
    Write-Host ''
    Write-Host '================ EXPORT SUMMARY ================' -ForegroundColor Green
    Write-Host $text
    Write-Host ('this session: {0:N1} GB downloaded, {1} files, elapsed {2:d\.hh\:mm\:ss}' -f ($sessionBytes / 1GB), $Shared.SessionDownloaded, $elapsed)
    Write-Host '================================================' -ForegroundColor Green
    Write-Log -Level INFO -Message 'Export summary' -Data @{
        summary = ($text -replace "`n", ' | ')
        sessionBytes = $sessionBytes
        sessionFiles = [int64]$Shared.SessionDownloaded
        elapsedSec = [int]$elapsed.TotalSeconds
    }
    $failCsv = Join-Path $Config.logDir ("failures-{0}.csv" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    $failed = @(Invoke-Db -Conn $Conn -Query "SELECT rel_path, size, attempts, last_attempt, error FROM items WHERE is_folder=0 AND status IN ('failed','retry_wait')")
    if ($failed.Count -gt 0) {
        $failed | Export-Csv -Path $failCsv -NoTypeInformation -Encoding utf8
        Write-Host "Failed/retrying items exported to: $failCsv" -ForegroundColor Yellow
    }
}

# ---------- run bookkeeping ----------
Invoke-Db -Conn $conn -Query "INSERT INTO runs (started, mode) VALUES (@s, @m)" -Params @{ s = [datetime]::UtcNow.ToString('o'); m = $Mode } | Out-Null
$runId = (Invoke-Db -Conn $conn -Query 'SELECT last_insert_rowid() AS id').id

$dashboardJob = $null
$exitNote = 'completed'

try {
    # ---------- dashboard ----------
    if (-not $NoDashboard) {
        $dashboardJob = Start-DashboardJob -Port $cfg.dashboardPort -WebRoot $cfg.webRoot -StatusDir $cfg.statusDir `
            -LogDir $cfg.logDir -ControlFile $cfg.controlFile -Shared $Shared
        Start-Sleep -Milliseconds 1500
        if ($Shared.DashboardError) {
            Write-Log -Level WARN -Message $Shared.DashboardError
        } else {
            Write-Log -Level INFO -Console -Message "Dashboard running at http://localhost:$($cfg.dashboardPort)/"
        }
    }

    # ---------- initial auth ----------
    & $refreshToken
    if (-not $Shared.AccessToken) { throw 'Could not obtain an access token.' }
    Write-StatusSnapshot -Conn $conn -Shared $Shared -Config $cfg

    # ---------- phases ----------
    switch ($Mode) {
        'Discover' {
            Invoke-DiscoveryPhase -Config $cfg -Conn $conn -Shared $Shared -RefreshToken $refreshToken -FullRescan:$FullRescan | Out-Null
        }
        'Download' {
            Invoke-DownloadPhase -Config $cfg -Conn $conn -Shared $Shared -SrcDir $srcDir -RefreshToken $refreshToken
        }
        'Verify' {
            Invoke-VerifyPhase -Config $cfg -Conn $conn -Shared $Shared | Out-Null
        }
        'RetryFailed' {
            $n = (Invoke-Db -Conn $conn -Query "SELECT COUNT(*) AS c FROM items WHERE is_folder=0 AND status='failed'").c
            Invoke-Db -Conn $conn -Query "UPDATE items SET status='queued', attempts=0, error=NULL, next_retry_at=NULL WHERE is_folder=0 AND status='failed'" | Out-Null
            Write-Log -Level INFO -Console -Message "Re-queued $n permanently-failed items"
            Invoke-DownloadPhase -Config $cfg -Conn $conn -Shared $Shared -SrcDir $srcDir -RefreshToken $refreshToken
        }
        'Full' {
            # Shared.Stop is only ever true here on operator stop or fatal error -
            # the download phase shuts its worker pool down via Shared.PoolStop.
            $discoveryDone = Invoke-DiscoveryPhase -Config $cfg -Conn $conn -Shared $Shared -RefreshToken $refreshToken -FullRescan:$FullRescan
            if ($discoveryDone -and -not $Shared.Stop) {
                Invoke-DownloadPhase -Config $cfg -Conn $conn -Shared $Shared -SrcDir $srcDir -RefreshToken $refreshToken
            }
            if ($cfg.verifyMode -and -not $Shared.Stop) {
                $result = Invoke-VerifyPhase -Config $cfg -Conn $conn -Shared $Shared
                if ($result.Requeued -gt 0 -and -not $Shared.Stop) {
                    Write-Log -Level WARN -Message "Verification re-queued $($result.Requeued) files - running download pass again"
                    Invoke-DownloadPhase -Config $cfg -Conn $conn -Shared $Shared -SrcDir $srcDir -RefreshToken $refreshToken
                }
            }
        }
    }

    # ---------- summary ----------
    $Shared.Phase = 'complete'
    Write-ExportSummary -Conn $conn -Config $cfg -Shared $Shared
    Send-Notification -Config $cfg -Subject 'OneDrive export: run finished' -Body (Get-SummaryText -Conn $conn)

    # ---------- keep dashboard up for final review ----------
    if ($dashboardJob -and -not $ExitOnComplete -and -not $Shared.Stop -and -not $Shared.DashboardError) {
        Wait-DashboardClose -Conn $conn -Config $cfg -Shared $Shared
    }
} catch {
    $exitNote = "error: $($_.Exception.Message)"
    Write-Log -Level ERROR -Message "Run aborted: $($_.Exception.Message)"
    Write-Log -Level ERROR -Message ($_.ScriptStackTrace | Out-String)
    Send-Notification -Config $cfg -Subject 'OneDrive export: run ABORTED' -Body $_.Exception.Message
    throw
} finally {
    $Shared.Stop = $true
    if ($dashboardJob) {
        try { Wait-Job -Job $dashboardJob -Timeout 5 | Out-Null } catch { }
        try { Remove-Job -Job $dashboardJob -Force -ErrorAction SilentlyContinue } catch { }
    }
    try {
        Invoke-Db -Conn $conn -Query "UPDATE runs SET ended=@e, notes=@n WHERE id=@id" `
            -Params @{ e = [datetime]::UtcNow.ToString('o'); n = $exitNote; id = $runId } | Out-Null
    } catch { }
    try { Write-StatusSnapshot -Conn $conn -Shared $Shared -Config $cfg } catch { }
    Close-ExportDb -Conn $conn
    Write-Log -Level INFO -Console -Message "=== OneDrive export stopped ($exitNote) ==="
}
