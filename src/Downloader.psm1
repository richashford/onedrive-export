# Downloader.psm1 - phase 2: the download worker pool + orchestration loop.
#
# Design:
#   - The MAIN thread owns SQLite. It pulls batches of queued files, marks them
#     'dispatched', and feeds an in-memory ConcurrentQueue.
#   - N worker THREADS (Start-ThreadJob) each: take an item, fetch fresh metadata
#     (fresh pre-authenticated downloadUrl), stream content to <file>.partial,
#     then atomically move into place and stamp timestamps. Results go back on a
#     ConcurrentQueue; the main thread commits them to SQLite in transactions.
#   - Crash safety: 'dispatched' rows are re-queued on startup; .partial files
#     are resumed via HTTP Range when the eTag still matches, else discarded.

function Invoke-DownloadPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)][hashtable]$Shared,
        [Parameter(Mandatory)][string]$SrcDir,
        [Parameter(Mandatory)][scriptblock]$RefreshToken
    )

    $Shared.Phase = 'download'
    $Shared.PoolStop = $false   # pool-local shutdown signal; Stop remains global (operator/final)

    $driveId = Get-StateValue -Conn $Conn -Key 'drive_id'
    if (-not $driveId) { throw "No drive_id in state - run discovery first (-Mode Discover or -Mode Full)." }
    $Shared.DriveId = [string]$driveId

    Reset-StaleStatus -Conn $Conn

    $workQueue   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $resultQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

    $workerCfg = @{
        BufferBytes         = [int]($Config.downloadBufferMB) * 1MB
        ReadStallTimeoutSec = [int]$Config.readStallTimeoutSec
    }

    $workerScript = Get-WorkerScriptBlock
    $jobs = @{}
    for ($wid = 1; $wid -le [int]$Config.concurrency; $wid++) {
        $jobs[$wid] = Start-DownloadWorker -WorkerScript $workerScript -Shared $Shared -WorkQueue $workQueue -ResultQueue $resultQueue -WorkerId $wid -SrcDir $SrcDir -WorkerCfg $workerCfg
    }
    Write-Log -Level INFO -Console -Message "Download phase started" -Data @{ workers = $Config.concurrency; destination = $Config.destinationRoot }

    $lastStatusWrite  = [datetime]::MinValue
    $lastFailuresWrite = [datetime]::MinValue
    $lastDestCheck    = [datetime]::MinValue
    $idleSince        = $null
    $notifiedFailures = $false

    try {
        while ($true) {
            # ---- 1) apply completed results to durable state ----
            $batch = [System.Collections.Generic.List[object]]::new()
            $r = $null
            while ($batch.Count -lt 500 -and $resultQueue.TryDequeue([ref]$r)) { $batch.Add($r) }
            if ($batch.Count -gt 0) {
                Update-ResultBatch -Conn $Conn -Shared $Shared -Config $Config -Results $batch
            }

            # ---- 2) keep the token fresh ----
            & $RefreshToken

            # ---- 3) destination health check ----
            if (([datetime]::UtcNow - $lastDestCheck).TotalSeconds -ge 15) {
                $lastDestCheck = [datetime]::UtcNow
                Test-Destination -Config $Config -Shared $Shared
            }

            # ---- 4) operator control (dashboard / control.json) ----
            Read-ControlCommand -Config $Config -Shared $Shared

            if ($Shared.Stop) { break }

            # ---- 5) refill the work queue ----
            $paused = ($Shared.UserPaused -or $Shared.SystemPaused)
            if (-not $paused -and $workQueue.Count -lt ([int]$Config.concurrency * 2)) {
                $next = @(Get-NextBatch -Conn $Conn -Limit ([int]$Config.concurrency * 6))
                foreach ($row in $next) {
                    $workQueue.Enqueue([pscustomobject]@{
                        id         = [string]$row.id
                        rel_path   = [string](Get-DbValue $row.rel_path)
                        local_path = [string](Get-DbValue $row.local_path)
                        size       = [int64](Get-DbValue $row.size)
                        etag       = [string](Get-DbValue $row.etag)
                        attempts   = [int](Get-DbValue $row.attempts)
                    })
                }
            }

            # ---- 6) worker health: restart crashed worker threads ----
            foreach ($wid in @($jobs.Keys)) {
                $j = $jobs[$wid]
                if ($j.State -in @('Failed', 'Stopped', 'Completed') -and -not $Shared.Stop) {
                    $err = ''
                    try { $err = (Receive-Job -Job $j -ErrorAction SilentlyContinue 2>&1 | Out-String).Trim() } catch { }
                    Write-Log -Level ERROR -Message "Worker $wid died unexpectedly - restarting" -Data @{ state = [string]$j.State; error = $err }
                    Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
                    $jobs[$wid] = Start-DownloadWorker -WorkerScript $workerScript -Shared $Shared -WorkQueue $workQueue -ResultQueue $resultQueue -WorkerId $wid -SrcDir $SrcDir -WorkerCfg $workerCfg
                }
            }

            # ---- 7) status snapshots ----
            if (([datetime]::UtcNow - $lastStatusWrite).TotalSeconds -ge [int]$Config.statusIntervalSeconds) {
                $lastStatusWrite = [datetime]::UtcNow
                Write-StatusSnapshot -Conn $Conn -Shared $Shared -Config $Config
            }
            if (([datetime]::UtcNow - $lastFailuresWrite).TotalSeconds -ge 30) {
                $lastFailuresWrite = [datetime]::UtcNow
                Write-FailuresSnapshot -Conn $Conn -Config $Config
                Send-FailureNotificationIfNeeded -Conn $Conn -Config $Config -Shared $Shared -AlreadySent ([ref]$notifiedFailures)
            }

            # ---- 8) completion / retry-wait detection ----
            $pending = Get-PendingSummary -Conn $Conn
            $active  = [int64](Get-DbValue $pending.active)
            $waiting = [int64](Get-DbValue $pending.waiting)
            $allIdle = Test-AllWorkersIdle -Shared $Shared

            if ($active -eq 0 -and $waiting -eq 0 -and $workQueue.IsEmpty -and $resultQueue.IsEmpty -and $allIdle) {
                Write-Log -Level INFO -Console -Message 'Download phase complete: nothing left to download'
                break
            }

            if ($active -eq 0 -and $waiting -gt 0 -and $workQueue.IsEmpty -and $allIdle) {
                $nextDue = [string](Get-DbValue $pending.next_due)
                Write-Log -Level INFO -Message "All remaining items are in retry-wait; next due at $nextDue" -Data @{ waiting = $waiting }
            }

            # Sweep: if everything looks idle but rows are stuck 'dispatched' for a
            # while (e.g. queue entries lost to a crashed worker), re-queue them.
            if ($allIdle -and $workQueue.IsEmpty -and $resultQueue.IsEmpty -and $active -gt 0) {
                if ($null -eq $idleSince) { $idleSince = [datetime]::UtcNow }
                elseif (([datetime]::UtcNow - $idleSince).TotalSeconds -gt 120) {
                    Write-Log -Level WARN -Message 'Re-queueing stuck dispatched items'
                    Invoke-Db -Conn $Conn -Query "UPDATE items SET status='queued' WHERE status='dispatched'" | Out-Null
                    $idleSince = $null
                }
            } else {
                $idleSince = $null
            }

            Start-Sleep -Milliseconds 700
        }
    } finally {
        # Graceful shutdown: signal THIS pool's workers (not the whole app - the
        # dashboard and later phases keep running), drain results that made it back.
        $Shared.PoolStop = $true
        foreach ($j in $jobs.Values) {
            try { Wait-Job -Job $j -Timeout 20 | Out-Null } catch { }
            try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch { }
        }
        $tail = [System.Collections.Generic.List[object]]::new()
        $r2 = $null
        while ($resultQueue.TryDequeue([ref]$r2)) { $tail.Add($r2) }
        if ($tail.Count -gt 0) {
            try { Update-ResultBatch -Conn $Conn -Shared $Shared -Config $Config -Results $tail } catch { Write-Log -Level ERROR -Message "Failed to persist final results: $($_.Exception.Message)" }
        }
        # Anything still marked dispatched goes back to the queue for next run.
        try { Reset-StaleStatus -Conn $Conn } catch { }
        try { Write-StatusSnapshot -Conn $Conn -Shared $Shared -Config $Config } catch { }
        try { Write-FailuresSnapshot -Conn $Conn -Config $Config } catch { }
    }
}

function Start-DownloadWorker {
    param($WorkerScript, $Shared, $WorkQueue, $ResultQueue, [int]$WorkerId, [string]$SrcDir, [hashtable]$WorkerCfg)
    $wid = $WorkerId
    $workQueue = $WorkQueue
    $resultQueue = $ResultQueue
    return Start-ThreadJob -Name "odx-worker-$wid" -ScriptBlock $WorkerScript -ArgumentList @($Shared, $workQueue, $resultQueue, $wid, $SrcDir, $WorkerCfg)
}

function Test-AllWorkersIdle {
    param([hashtable]$Shared)
    $snap = Get-SyncSnapshot -Table $Shared.Workers
    foreach ($wid in @($snap.Keys)) {
        $w = $snap[$wid]
        if ($null -ne $w -and [string]$w.state -in @('downloading', 'metadata')) { return $false }
    }
    return $true
}

function Update-ResultBatch {
    param($Conn, [hashtable]$Shared, $Config, $Results)
    $maxRetries = [int]$Config.maxRetries
    Start-DbTransaction -Conn $Conn
    try {
        foreach ($res in $Results) {
            $now = [datetime]::UtcNow.ToString('o')
            switch ([string]$res.status) {
                'downloaded' {
                    Invoke-Db -Conn $Conn -Query @'
UPDATE items SET status='downloaded', size=@size, etag=@etag, error=NULL,
                 last_attempt=@now, completed_at=@now, next_retry_at=NULL
WHERE id=@id
'@ -Params @{ id = $res.id; size = [int64]$res.size; etag = [string]$res.etag; now = $now } | Out-Null
                    $Shared.SessionDownloaded = [int64]$Shared.SessionDownloaded + 1
                    Write-Log -Level INFO -Message 'downloaded' -Data @{ file = $res.rel; bytes = $res.size; ms = $res.durMs }
                }
                'skipped_existing' {
                    Invoke-Db -Conn $Conn -Query @'
UPDATE items SET status='downloaded', size=@size, etag=@etag,
                 error='existing local file matched size - kept',
                 last_attempt=@now, completed_at=@now, next_retry_at=NULL
WHERE id=@id
'@ -Params @{ id = $res.id; size = [int64]$res.size; etag = [string]$res.etag; now = $now } | Out-Null
                    $Shared.SessionSkippedExisting = [int64]$Shared.SessionSkippedExisting + 1
                    Write-Log -Level DEBUG -Message 'kept existing file' -Data @{ file = $res.rel }
                }
                'gone' {
                    Invoke-Db -Conn $Conn -Query "UPDATE items SET status='gone', error=@err, last_attempt=@now WHERE id=@id" `
                        -Params @{ id = $res.id; err = [string]$res.error; now = $now } | Out-Null
                    Write-Log -Level WARN -Message 'item gone from source' -Data @{ file = $res.rel }
                }
                'failed_permanent' {
                    Invoke-Db -Conn $Conn -Query "UPDATE items SET status='failed', error=@err, attempts=attempts+1, last_attempt=@now WHERE id=@id" `
                        -Params @{ id = $res.id; err = [string]$res.error; now = $now } | Out-Null
                    $Shared.SessionFailed = [int64]$Shared.SessionFailed + 1
                    Add-RecentError -Shared $Shared -File $res.rel -Message ([string]$res.error)
                    Write-Log -Level ERROR -Message 'download failed (permanent)' -Data @{ file = $res.rel; error = $res.error }
                }
                'retry' {
                    if ([string]$res.error -eq 'stop requested') {
                        # Not a real failure: put straight back in the queue, no attempt charged.
                        Invoke-Db -Conn $Conn -Query "UPDATE items SET status='queued' WHERE id=@id" -Params @{ id = $res.id } | Out-Null
                        continue
                    }
                    $newAttempts = [int]$res.attempts + 1
                    if ($newAttempts -ge $maxRetries) {
                        Invoke-Db -Conn $Conn -Query "UPDATE items SET status='failed', error=@err, attempts=@att, last_attempt=@now WHERE id=@id" `
                            -Params @{ id = $res.id; err = [string]$res.error; att = $newAttempts; now = $now } | Out-Null
                        $Shared.SessionFailed = [int64]$Shared.SessionFailed + 1
                        Add-RecentError -Shared $Shared -File $res.rel -Message ([string]$res.error)
                        Write-Log -Level ERROR -Message 'download failed (retries exhausted)' -Data @{ file = $res.rel; attempts = $newAttempts; error = $res.error }
                    } else {
                        $delaySec = [math]::Min(3600, 30 * [math]::Pow(2, $newAttempts)) + (Get-Random -Minimum 0 -Maximum 30)
                        $due = [datetime]::UtcNow.AddSeconds($delaySec).ToString('o')
                        Invoke-Db -Conn $Conn -Query "UPDATE items SET status='retry_wait', error=@err, attempts=@att, last_attempt=@now, next_retry_at=@due WHERE id=@id" `
                            -Params @{ id = $res.id; err = [string]$res.error; att = $newAttempts; now = $now; due = $due } | Out-Null
                        $Shared.SessionRetries = [int64]$Shared.SessionRetries + 1
                        Add-RecentError -Shared $Shared -File $res.rel -Message ([string]$res.error)
                        Write-Log -Level WARN -Message 'download failed - will retry' -Data @{ file = $res.rel; attempt = $newAttempts; nextTry = $due; error = $res.error }
                    }
                }
                default {
                    Write-Log -Level ERROR -Message "Unknown worker result status '$($res.status)'" -Data @{ file = $res.rel }
                }
            }
        }
        Complete-DbTransaction -Conn $Conn
    } catch {
        Undo-DbTransaction -Conn $Conn
        throw
    }
}

function Add-RecentError {
    param([hashtable]$Shared, [string]$File, [string]$Message)
    $Shared.RecentErrors.Insert(0, @{ ts = [datetime]::UtcNow.ToString('o'); file = $File; error = $Message })
    while ($Shared.RecentErrors.Count -gt 50) { $Shared.RecentErrors.RemoveAt($Shared.RecentErrors.Count - 1) }
}

function Test-Destination {
    # Auto-pause when R:\ vanishes or fills up; auto-resume when it comes back.
    param($Config, [hashtable]$Shared)
    $root = [System.IO.Path]::GetPathRoot($Config.destinationRoot)
    $ok = $false
    $reason = ''
    try {
        if (Test-Path -LiteralPath $root) {
            $di = [System.IO.DriveInfo]::new($root)
            $freeGB = $di.AvailableFreeSpace / 1GB
            if ($freeGB -lt [double]$Config.diskMinFreeGB) {
                $reason = "destination low on space: $([math]::Round($freeGB,1)) GB free (min $($Config.diskMinFreeGB) GB)"
            } else {
                $ok = $true
            }
        } else {
            $reason = "destination drive $root is not available"
        }
    } catch {
        $reason = "destination check failed: $($_.Exception.Message)"
    }

    if (-not $ok) {
        if (-not $Shared.SystemPaused) {
            $Shared.SystemPaused = $true
            $Shared.PauseReason = $reason
            Write-Log -Level ERROR -Message "AUTO-PAUSED: $reason"
        }
    } elseif ($Shared.SystemPaused) {
        $Shared.SystemPaused = $false
        $Shared.PauseReason = ''
        Write-Log -Level INFO -Console -Message 'Destination available again - resuming downloads'
    }
}

function Read-ControlCommand {
    # control.json is written by the dashboard (or by hand): {"command":"pause|resume|stop","ts":"..."}
    param($Config, [hashtable]$Shared)
    if (-not (Test-Path -LiteralPath $Config.controlFile)) { return }
    try {
        $ctl = Get-Content -LiteralPath $Config.controlFile -Raw | ConvertFrom-Json
    } catch { return }
    if (-not $ctl.ts -or [string]$ctl.ts -eq [string]$Shared.LastControlTs) { return }
    $Shared.LastControlTs = [string]$ctl.ts
    switch ([string]$ctl.command) {
        'pause'  { $Shared.UserPaused = $true;  Write-Log -Level WARN -Message 'Operator requested PAUSE (dashboard/control file)' }
        'resume' { $Shared.UserPaused = $false; Write-Log -Level INFO -Console -Message 'Operator requested RESUME' }
        'stop'   { $Shared.Stop = $true;        Write-Log -Level WARN -Message 'Operator requested STOP - shutting down safely' }
    }
}

function Send-FailureNotificationIfNeeded {
    param($Conn, $Config, [hashtable]$Shared, [ref]$AlreadySent)
    if (-not $Config.notifyWebhookUrl -or $AlreadySent.Value) { return }
    $r = Invoke-Db -Conn $Conn -Query "SELECT COUNT(*) AS c FROM items WHERE is_folder=0 AND status='failed'"
    $failed = [int64](Get-DbValue $r.c)
    if ($failed -ge [int64]$Config.notifyFailureThreshold) {
        $AlreadySent.Value = $true
        Send-Notification -Config $Config -Subject 'OneDrive export: failure threshold reached' -Body "Permanently failed files: $failed (threshold $($Config.notifyFailureThreshold))"
    }
}

function Send-Notification {
    param($Config, [string]$Subject, [string]$Body)
    if (-not $Config.notifyWebhookUrl) { return }
    try {
        $payload = @{ text = "$Subject`n$Body"; subject = $Subject; body = $Body } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri $Config.notifyWebhookUrl -Body $payload -ContentType 'application/json' -TimeoutSec 30 | Out-Null
        Write-Log -Level INFO -Message 'Notification sent' -Data @{ subject = $Subject }
    } catch {
        Write-Log -Level WARN -Message "Notification failed: $($_.Exception.Message)"
    }
}

function Get-WorkerScriptBlock {
    # The entire body of one download worker thread.
    return {
        param($Shared, $WorkQueue, $ResultQueue, $WorkerId, $SrcDir, $Wcfg)

        Import-Module (Join-Path $SrcDir 'GraphApi.psm1')  -Force -DisableNameChecking
        Import-Module (Join-Path $SrcDir 'PathUtils.psm1') -Force -DisableNameChecking

        $handler = [System.Net.Http.SocketsHttpHandler]::new()
        $handler.ConnectTimeout = [TimeSpan]::FromSeconds(30)
        $http = [System.Net.Http.HttpClient]::new($handler)
        $http.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
        $buffer = [byte[]]::new([int]$Wcfg.BufferBytes)
        $stallMs = [int]$Wcfg.ReadStallTimeoutSec * 1000

        function Set-WorkerState {
            param([hashtable]$State)
            $Shared.Workers[$WorkerId] = $State
        }

        function Wait-TaskResult {
            param($Task, [int]$TimeoutMs, [string]$What)
            if (-not $Task.Wait($TimeoutMs)) { throw "timeout waiting for $What" }
            return $Task.Result
        }

        function Invoke-OneItem {
            param($Item)
            $r = @{
                id = $Item.id; rel = $Item.rel_path; attempts = $Item.attempts
                status = 'retry'; error = $null
                size = [int64]$Item.size; etag = [string]$Item.etag
                bytes = [int64]0; durMs = [int64]0
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            Set-WorkerState @{ state = 'metadata'; file = $Item.rel_path; total = [int64]$Item.size; bytes = 0 }

            # Fresh metadata: current size/eTag + a fresh pre-authenticated downloadUrl.
            $meta = Invoke-GraphApi -Uri "/drives/$($Shared.DriveId)/items/$($Item.id)" -Shared $Shared -AllowNotFound
            if ($null -eq $meta -or $meta.deleted) { $r.status = 'gone'; $r.error = 'item no longer exists in source'; return $r }
            if ($meta.folder) { $r.status = 'gone'; $r.error = 'item is now a folder in source'; return $r }
            $dlUrl = $meta.'@microsoft.graph.downloadUrl'
            if (-not $dlUrl) { $r.status = 'failed_permanent'; $r.error = 'no downloadUrl (package/OneNote or unsupported item type)'; return $r }

            $r.size = [int64]$meta.size
            $r.etag = [string]$meta.eTag

            $final = [string]$Item.local_path
            $lfinal = Get-LongPath -Path $final
            $dir = [System.IO.Path]::GetDirectoryName($final)
            [void][System.IO.Directory]::CreateDirectory((Get-LongPath -Path $dir))

            # Already have a complete copy? (size match = complete under basic mode)
            if ([System.IO.File]::Exists($lfinal)) {
                $len = ([System.IO.FileInfo]::new($lfinal)).Length
                if ($len -eq [int64]$meta.size) { $r.status = 'skipped_existing'; return $r }
                [System.IO.File]::Delete($lfinal)   # incomplete/stale local copy
            }

            # Resume a partial download only if the source file hasn't changed since.
            $partial = "$final.partial"
            $lpartial = Get-LongPath -Path $partial
            $sidecar = "$final.partial.meta"
            $lsidecar = Get-LongPath -Path $sidecar
            $startAt = [int64]0
            if ([System.IO.File]::Exists($lpartial)) {
                $resumeOk = $false
                if ([System.IO.File]::Exists($lsidecar)) {
                    try {
                        $sc = [System.IO.File]::ReadAllText($lsidecar) | ConvertFrom-Json
                        if ([string]$sc.etag -eq [string]$meta.eTag) { $resumeOk = $true }
                    } catch { }
                }
                if ($resumeOk) { $startAt = ([System.IO.FileInfo]::new($lpartial)).Length }
                else { [System.IO.File]::Delete($lpartial) }
            }
            [System.IO.File]::WriteAllText($lsidecar, (@{ etag = [string]$meta.eTag; id = [string]$Item.id } | ConvertTo-Json -Compress))

            $startedIso = (Get-Date).ToUniversalTime().ToString('o')
            Set-WorkerState @{ state = 'downloading'; file = $Item.rel_path; total = [int64]$meta.size; bytes = $startAt; started = $startedIso }

            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $dlUrl)
            if ($startAt -gt 0) { $req.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($startAt, $null) }
            $resp = $null; $inStream = $null; $fs = $null
            try {
                $resp = Wait-TaskResult -Task ($http.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)) -TimeoutMs 120000 -What 'download response headers'
                $code = [int]$resp.StatusCode

                if ($code -eq 429 -or $code -eq 503) {
                    $ra = 30
                    try {
                        if ($resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) { $ra = [int]$resp.Headers.RetryAfter.Delta.Value.TotalSeconds }
                    } catch { }
                    if ($code -eq 429) { $Shared.Throttle429 = [int]$Shared.Throttle429 + 1 } else { $Shared.Throttle5xx = [int]$Shared.Throttle5xx + 1 }
                    $gate = (Get-Date).AddSeconds($ra)
                    if ($null -eq $Shared.BackoffUntil -or $gate -gt $Shared.BackoffUntil) { $Shared.BackoffUntil = $gate }
                    throw "throttled on content download (HTTP $code, retry-after ${ra}s)"
                }
                if ($code -eq 200 -and $startAt -gt 0) {
                    # Server ignored the Range header: restart the file from zero.
                    $startAt = [int64]0
                }
                if ($code -ne 200 -and $code -ne 206) {
                    throw "content download failed: HTTP $code (downloadUrl may have expired - will retry with a fresh one)"
                }

                $mode = [System.IO.FileMode]::Create
                if ($startAt -gt 0) { $mode = [System.IO.FileMode]::Append }
                $fs = [System.IO.FileStream]::new($lpartial, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1048576)
                $inStream = Wait-TaskResult -Task ($resp.Content.ReadAsStreamAsync()) -TimeoutMs 120000 -What 'content stream'

                $written = $startAt
                $lastUi = [datetime]::UtcNow
                while ($true) {
                    if ($Shared.Stop -or $Shared.PoolStop) { throw 'stop requested' }
                    $rt = $inStream.ReadAsync($buffer, 0, $buffer.Length)
                    if (-not $rt.Wait($stallMs)) { throw 'network read stalled' }
                    $n = [int]$rt.Result
                    if ($n -le 0) { break }
                    $fs.Write($buffer, 0, $n)
                    $written += $n
                    $Shared.WorkerBytes[$WorkerId] = [int64]$Shared.WorkerBytes[$WorkerId] + $n
                    if (([datetime]::UtcNow - $lastUi).TotalSeconds -ge 2) {
                        Set-WorkerState @{ state = 'downloading'; file = $Item.rel_path; total = [int64]$meta.size; bytes = $written; started = $startedIso }
                        $lastUi = [datetime]::UtcNow
                    }
                }
                $fs.Flush($true)
                $fs.Dispose(); $fs = $null

                $flen = ([System.IO.FileInfo]::new($lpartial)).Length
                if ($flen -ne [int64]$meta.size) {
                    [System.IO.File]::Delete($lpartial)
                    try { [System.IO.File]::Delete($lsidecar) } catch { }
                    throw "size mismatch after download (got $flen, expected $($meta.size))"
                }

                [System.IO.File]::Move($lpartial, $lfinal, $true)
                try { [System.IO.File]::Delete($lsidecar) } catch { }

                # Preserve source timestamps where practical.
                try {
                    if ($meta.fileSystemInfo) {
                        $lm = $meta.fileSystemInfo.lastModifiedDateTime
                        $cr = $meta.fileSystemInfo.createdDateTime
                        if ($cr) { [System.IO.File]::SetCreationTimeUtc($lfinal, ([datetime]$cr).ToUniversalTime()) }
                        if ($lm) { [System.IO.File]::SetLastWriteTimeUtc($lfinal, ([datetime]$lm).ToUniversalTime()) }
                    }
                } catch { }

                $r.bytes = $flen - $startAt
                $r.status = 'downloaded'
            } finally {
                if ($fs)       { try { $fs.Dispose() } catch { } }
                if ($inStream) { try { $inStream.Dispose() } catch { } }
                if ($resp)     { try { $resp.Dispose() } catch { } }
                try { $req.Dispose() } catch { }
            }
            $r.durMs = $sw.ElapsedMilliseconds
            return $r
        }

        # ---- worker main loop ----
        Set-WorkerState @{ state = 'idle' }
        if (-not $Shared.WorkerBytes.ContainsKey($WorkerId)) { $Shared.WorkerBytes[$WorkerId] = [int64]0 }

        while (-not $Shared.Stop -and -not $Shared.PoolStop) {
            if ($Shared.UserPaused -or $Shared.SystemPaused) {
                Set-WorkerState @{ state = 'paused' }
                Start-Sleep -Milliseconds 800
                continue
            }
            $item = $null
            if (-not $WorkQueue.TryDequeue([ref]$item)) {
                Set-WorkerState @{ state = 'idle' }
                Start-Sleep -Milliseconds 400
                continue
            }
            $result = $null
            try {
                $result = Invoke-OneItem -Item $item
            } catch {
                $msg = $_.Exception.Message
                if ($msg -and $msg.Length -gt 400) { $msg = $msg.Substring(0, 400) }
                $result = @{
                    id = $item.id; rel = $item.rel_path; attempts = $item.attempts
                    status = 'retry'; error = $msg
                    size = [int64]$item.size; etag = [string]$item.etag
                    bytes = [int64]0; durMs = [int64]0
                }
            }
            Set-WorkerState @{ state = 'idle' }
            $ResultQueue.Enqueue([pscustomobject]$result)
        }
        Set-WorkerState @{ state = 'stopped' }
    }
}

Export-ModuleMember -Function Invoke-DownloadPhase, Send-Notification, Read-ControlCommand
