# StatusReporter.psm1 - builds the status snapshot the dashboard consumes.
# The main loop calls Write-StatusSnapshot on an interval; the dashboard thread
# only ever reads JSON files, so it never contends with SQLite.

function Get-SyncSnapshot {
    <#
      Thread-safe copy of a synchronized hashtable. Enumerating one directly is
      NOT thread-safe even though individual reads/writes are - concurrent value
      updates invalidate the enumerator (crashed a live run). Cloning under the
      SyncRoot lock is the documented safe pattern; writers block only for the
      microseconds the clone takes.
    #>
    param([Parameter(Mandatory)][hashtable]$Table)
    $lock = $Table.SyncRoot
    [System.Threading.Monitor]::Enter($lock)
    try { return $Table.Clone() } finally { [System.Threading.Monitor]::Exit($lock) }
}

function Write-StatusSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)][hashtable]$Shared,
        [Parameter(Mandatory)]$Config
    )

    $now = [datetime]::UtcNow

    # ---- aggregate DB stats ----
    $byStatus = @{}
    $totalFiles = [int64]0; $totalBytes = [int64]0
    $doneFiles = [int64]0;  $doneBytes = [int64]0
    $failedFiles = [int64]0; $skippedFiles = [int64]0; $goneFiles = [int64]0
    $pendingFiles = [int64]0; $pendingBytes = [int64]0
    $folderCount = [int64]0

    foreach ($row in @(Get-DbStats -Conn $Conn)) {
        if ([int]$row.is_folder -eq 1) { $folderCount += [int64]$row.cnt; continue }
        $st = [string]$row.status
        $cnt = [int64]$row.cnt; $bytes = [int64]$row.bytes
        $byStatus[$st] = @{ count = $cnt; bytes = $bytes }
        $totalFiles += $cnt; $totalBytes += $bytes
        switch ($st) {
            'downloaded' { $doneFiles += $cnt; $doneBytes += $bytes }
            'verified'   { $doneFiles += $cnt; $doneBytes += $bytes }
            'failed'     { $failedFiles += $cnt }
            'skipped'    { $skippedFiles += $cnt }
            'gone'       { $goneFiles += $cnt }
            default      { $pendingFiles += $cnt; $pendingBytes += $bytes }   # queued/dispatched/retry_wait/discovered
        }
    }

    # ---- session throughput ----
    $wbSnap = Get-SyncSnapshot -Table $Shared.WorkerBytes
    $sessionBytes = [int64]0
    foreach ($v in $wbSnap.Values) { $sessionBytes += [int64]$v }

    $bps = 0.0
    if ($Shared.LastSampleTime) {
        $dt = ($now - [datetime]$Shared.LastSampleTime).TotalSeconds
        if ($dt -gt 0) { $bps = ($sessionBytes - [int64]$Shared.LastSampleBytes) / $dt }
    }
    $Shared.LastSampleTime = $now
    $Shared.LastSampleBytes = $sessionBytes

    # EMA for a stable recent-throughput figure
    if ($null -eq $Shared.EmaBps) { $Shared.EmaBps = $bps }
    else { $Shared.EmaBps = 0.85 * [double]$Shared.EmaBps + 0.15 * $bps }

    $avgBps = 0.0
    if ($Shared.SessionStart) {
        $elapsed = ($now - [datetime]$Shared.SessionStart).TotalSeconds
        if ($elapsed -gt 0) { $avgBps = $sessionBytes / $elapsed }
    }

    $etaSec = $null
    if ($Shared.EmaBps -gt 1000 -and $pendingBytes -gt 0) {
        $etaSec = [int64]($pendingBytes / [double]$Shared.EmaBps)
    }

    # ---- history ring for charts (bounded) ----
    if ($null -eq $Shared.History) { $Shared.History = [System.Collections.ArrayList]::new() }
    [void]$Shared.History.Add(@{
        t     = $now.ToString('o')
        bps   = [math]::Round($bps, 0)
        done  = $doneFiles
        fail  = $failedFiles
    })
    while ($Shared.History.Count -gt 720) { $Shared.History.RemoveAt(0) }

    # ---- workers ----
    $wSnap = Get-SyncSnapshot -Table $Shared.Workers
    $workers = @()
    foreach ($wid in @($wSnap.Keys | Sort-Object)) {
        $w = $wSnap[$wid]
        if ($null -eq $w) { continue }
        $entry = @{ id = $wid; state = [string]$w.state }
        if ($w.file)  { $entry.file = [string]$w.file }
        if ($w.total) { $entry.total = [int64]$w.total }
        if ($null -ne $w.bytes) { $entry.bytes = [int64]$w.bytes }
        if ($w.started) { $entry.started = [string]$w.started }
        $workers += ,$entry
    }

    $paused = ($Shared.UserPaused -or $Shared.SystemPaused)
    $pauseReason = ''
    if ($Shared.UserPaused) { $pauseReason = 'paused by operator' }
    elseif ($Shared.SystemPaused) { $pauseReason = [string]$Shared.PauseReason }

    $backoffRemaining = 0
    if ($Shared.BackoffUntil -and $Shared.BackoffUntil -gt (Get-Date)) {
        $backoffRemaining = [int]($Shared.BackoffUntil - (Get-Date)).TotalSeconds
    }

    $status = [ordered]@{
        generatedAt      = $now.ToString('o')
        phase            = [string]$Shared.Phase
        paused           = $paused
        pauseReason      = $pauseReason
        discovery        = @{ pages = [int]$Shared.DiscoveryPages; quotaUsedBytes = [int64]$Shared.QuotaUsedBytes }
        totals           = @{
            files        = $totalFiles
            bytes        = $totalBytes
            folders      = $folderCount
            doneFiles    = $doneFiles
            doneBytes    = $doneBytes
            pendingFiles = $pendingFiles
            pendingBytes = $pendingBytes
            failedFiles  = $failedFiles
            skippedFiles = $skippedFiles
            goneFiles    = $goneFiles
        }
        byStatus         = $byStatus
        session          = @{
            startedAt        = ([datetime]$Shared.SessionStart).ToString('o')
            bytesDownloaded  = $sessionBytes
            filesDownloaded  = [int64]$Shared.SessionDownloaded
            filesSkippedHave = [int64]$Shared.SessionSkippedExisting
            filesFailed      = [int64]$Shared.SessionFailed
            filesRetried     = [int64]$Shared.SessionRetries
            bpsRecent        = [math]::Round([double]$Shared.EmaBps, 0)
            bpsAverage       = [math]::Round($avgBps, 0)
            etaSeconds       = $etaSec
        }
        throttling       = @{
            http429          = [int]$Shared.Throttle429
            http5xx          = [int]$Shared.Throttle5xx
            backoffRemaining = $backoffRemaining
            lastReason       = [string]$Shared.LastBackoffReason
        }
        workers          = $workers
        recentErrors     = @($Shared.RecentErrors)
        history          = @($Shared.History)
        config           = @{
            concurrency = [int]$Config.concurrency
            destination = [string]$Config.destinationRoot
            verifyMode  = [string]$Config.verifyMode
            authMode    = [string]$Config.authMode
            upn         = [string]$Config.userPrincipalName
        }
    }

    Write-JsonAtomic -Object ([pscustomobject]$status) -Path (Join-Path $Config.statusDir 'status.json') -Depth 8
}

function Write-FailuresSnapshot {
    param(
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)]$Config
    )
    $rows = @(Invoke-Db -Conn $Conn -Query @'
SELECT rel_path, size, status, attempts, last_attempt, next_retry_at, error
FROM items
WHERE is_folder = 0 AND status IN ('failed','retry_wait')
ORDER BY last_attempt DESC
LIMIT 1000
'@)
    $list = foreach ($r in $rows) {
        @{
            relPath     = [string](Get-DbValue $r.rel_path)
            size        = [int64](Get-DbValue $r.size)
            status      = [string](Get-DbValue $r.status)
            attempts    = [int](Get-DbValue $r.attempts)
            lastAttempt = [string](Get-DbValue $r.last_attempt)
            nextRetry   = [string](Get-DbValue $r.next_retry_at)
            error       = [string](Get-DbValue $r.error)
        }
    }
    Write-JsonAtomic -Object @{ generatedAt = [datetime]::UtcNow.ToString('o'); failures = @($list) } -Path (Join-Path $Config.statusDir 'failures.json') -Depth 5
}

function Write-JsonAtomic {
    # Write to temp then rename, so the dashboard never reads a half-written file.
    param($Object, [string]$Path, [int]$Depth = 6)
    $tmp = "$Path.tmp"
    $json = $Object | ConvertTo-Json -Depth $Depth -Compress
    # BOM-less UTF-8: a BOM breaks strict JSON parsers reading the API
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($tmp, $Path, $true)
}

Export-ModuleMember -Function Write-StatusSnapshot, Write-FailuresSnapshot, Write-JsonAtomic, Get-SyncSnapshot
