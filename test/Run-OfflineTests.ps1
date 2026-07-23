# Run-OfflineTests.ps1 - offline smoke tests: everything testable without a Graph tenant.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module PSSQLite
foreach ($m in @('Config','Logging','PathUtils','Database','GraphApi','StatusReporter','Verifier')) {
    Import-Module (Join-Path $root "src\$m.psm1") -Force -DisableNameChecking
}

$script:pass = 0; $script:fail = 0
function Assert {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red }
}

Write-Host "`n--- PathUtils ---"
Assert ((ConvertTo-SafeName 'report: Q1|final?.docx') -eq 'report_ Q1_final_.docx') 'invalid chars replaced' (ConvertTo-SafeName 'report: Q1|final?.docx')
Assert ((ConvertTo-SafeName 'trailing dots... ') -eq 'trailing dots') 'trailing dots/spaces trimmed' (ConvertTo-SafeName 'trailing dots... ')
Assert ((ConvertTo-SafeName 'CON.txt') -eq '_CON.txt') 'reserved name prefixed' (ConvertTo-SafeName 'CON.txt')
Assert ((ConvertTo-SafeName 'normal file.pdf') -eq 'normal file.pdf') 'normal name untouched'
Assert ((ConvertTo-SafeName '...') -eq '_') 'all-dots becomes underscore' (ConvertTo-SafeName '...')
Assert ((Get-LongPath 'R:\a\b.txt') -eq '\\?\R:\a\b.txt') 'long path prefix'
Assert ((Get-LongPath '\\server\share\x') -eq '\\?\UNC\server\share\x') 'UNC long path prefix'
Assert ((Test-PathExcluded -RelativePath 'a\b\~$doc.docx' -Name '~$doc.docx' -Exclude @('~$*')) -eq $true) 'name pattern exclude'
Assert ((Test-PathExcluded -RelativePath 'Recordings\x.mp4' -Name 'x.mp4' -Exclude @('Recordings\*')) -eq $true) 'path pattern exclude'
Assert ((Test-PathExcluded -RelativePath 'Docs\x.pdf' -Name 'x.pdf' -Exclude @('Recordings\*')) -eq $false) 'non-matching not excluded'
Assert ((Test-PathExcluded -RelativePath 'Docs\x.pdf' -Name 'x.pdf' -Include @('TestFolder\*')) -eq $true) 'include filter excludes others'
Assert ((Test-PathExcluded -RelativePath 'TestFolder\x.pdf' -Name 'x.pdf' -Include @('TestFolder\*')) -eq $false) 'include filter admits matches'

Write-Host "`n--- QuickXorHash ---"
$tmp = Join-Path $PSScriptRoot 'qx-test.bin'
[System.IO.File]::WriteAllBytes($tmp, [byte[]]::new(0))
$hEmpty = Get-QuickXorHash -Path $tmp
Assert ($hEmpty -eq 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=') 'empty file vector' $hEmpty
[System.IO.File]::WriteAllBytes($tmp, [System.Text.Encoding]::ASCII.GetBytes('The quick brown fox jumps over the lazy dog'))
$h1 = Get-QuickXorHash -Path $tmp
$h2 = Get-QuickXorHash -Path $tmp
Assert ($h1 -eq $h2 -and $h1.Length -eq 28) 'deterministic, 160-bit output' $h1
# chunk-size independence: hash of same content must not depend on read chunking
# (the QuickXorHash type was loaded by the Get-QuickXorHash calls above)
$algo1 = [QuickXorHash]::new()
$bytes = [byte[]](1..200 | ForEach-Object { $_ % 251 })
$full = [Convert]::ToBase64String($algo1.ComputeHash($bytes))
$algo2 = [QuickXorHash]::new()
$algo2.TransformBlock($bytes, 0, 77, $null, 0) | Out-Null
$algo2.TransformBlock($bytes, 77, 100, $null, 0) | Out-Null
$algo2.TransformFinalBlock($bytes, 177, 23) | Out-Null
$chunked = [Convert]::ToBase64String($algo2.Hash)
Assert ($full -eq $chunked) 'chunking-independent' "$full vs $chunked"
Remove-Item $tmp -Force

Write-Host "`n--- Database state machine ---"
$dbPath = Join-Path $PSScriptRoot 'state\unit.db'
if (Test-Path $dbPath) { Remove-Item $dbPath -Force }
$conn = Open-ExportDb -Path $dbPath
Initialize-ExportDb -Conn $conn

# discovery page upsert + cursor
$rows = @(
    @{ id='f1'; parent_id='root'; name='a.txt'; rel_path='a.txt'; is_folder=0; size=100; last_modified='2026-01-01T00:00:00Z'; created=$null; etag='e1'; ctag='c1'; quickxor='q1'; status='queued'; local_path='X:\a.txt'; error=$null },
    @{ id='f2'; parent_id='root'; name='b.txt'; rel_path='b.txt'; is_folder=0; size=200; last_modified=$null; created=$null; etag='e2'; ctag=$null; quickxor=$null; status='queued'; local_path='X:\b.txt'; error=$null },
    @{ id='d1'; parent_id='root'; name='sub';   rel_path='sub';   is_folder=1; size=0;   last_modified=$null; created=$null; etag='ed'; ctag=$null; quickxor=$null; status='discovered'; local_path=$null; error=$null }
)
Save-DiscoveryPage -Conn $conn -Rows $rows -NextLink 'https://graph.microsoft.com/next?page=2'
Assert ((Get-StateValue -Conn $conn -Key 'delta_next') -like '*page=2') 'nextLink persisted with page'
Save-DiscoveryPage -Conn $conn -Rows @() -DeltaLink 'https://graph.microsoft.com/delta?token=abc'
Assert ($null -eq (Get-StateValue -Conn $conn -Key 'delta_next')) 'nextLink cleared on completion'
Assert ((Get-StateValue -Conn $conn -Key 'delta_link') -like '*token=abc') 'deltaLink persisted'

# batch dispatch
$batch = @(Get-NextBatch -Conn $conn -Limit 10)
Assert ($batch.Count -eq 2) 'batch pulls only queued files' "got $($batch.Count)"
$st = (Invoke-Db -Conn $conn -Query "SELECT COUNT(*) AS c FROM items WHERE status='dispatched'").c
Assert ($st -eq 2) 'batch marks dispatched'
Assert (@(Get-NextBatch -Conn $conn -Limit 10).Count -eq 0) 'second batch empty'
Reset-StaleStatus -Conn $conn
Assert (@(Get-NextBatch -Conn $conn -Limit 10).Count -eq 2) 'reset re-queues dispatched'

# completed status survives re-discovery with same etag, resets on new etag
Invoke-Db -Conn $conn -Query "UPDATE items SET status='downloaded' WHERE id='f1'" | Out-Null
Reset-StaleStatus -Conn $conn
Save-DiscoveryPage -Conn $conn -Rows @(,@{ id='f1'; parent_id='root'; name='a.txt'; rel_path='a.txt'; is_folder=0; size=100; last_modified=$null; created=$null; etag='e1'; ctag='c1'; quickxor='q1'; status='queued'; local_path='X:\a.txt'; error=$null })
Assert ((Invoke-Db -Conn $conn -Query "SELECT status FROM items WHERE id='f1'").status -eq 'downloaded') 'same etag keeps downloaded status'
Save-DiscoveryPage -Conn $conn -Rows @(,@{ id='f1'; parent_id='root'; name='a.txt'; rel_path='a.txt'; is_folder=0; size=150; last_modified=$null; created=$null; etag='e1-NEW'; ctag='c1'; quickxor='q1'; status='queued'; local_path='X:\a.txt'; error=$null })
Assert ((Invoke-Db -Conn $conn -Query "SELECT status FROM items WHERE id='f1'").status -eq 'queued') 'changed etag re-queues'

# retry starvation: a DUE retry_wait row must be dispatched before queued rows
# even when the queued pool is large enough to fill the batch limit on its own
Invoke-Db -Conn $conn -Query "UPDATE items SET status='retry_wait', next_retry_at='2000-01-01T00:00:00.0000000Z' WHERE id='f2'" | Out-Null
$one = @(Get-NextBatch -Conn $conn -Limit 1)
Assert ($one.Count -eq 1 -and $one[0].id -eq 'f2') 'due retry dispatched before queued backlog' "got $($one[0].id)"
Reset-StaleStatus -Conn $conn
Invoke-Db -Conn $conn -Query "UPDATE items SET status='queued', next_retry_at=NULL WHERE id='f2'" | Out-Null

# filter change: a previously skipped row must be re-queued when re-discovered
# as queued (same etag) - e.g. include/exclude changed followed by -FullRescan
Invoke-Db -Conn $conn -Query "UPDATE items SET status='skipped', error='excluded by include/exclude pattern' WHERE id='f1'" | Out-Null
Save-DiscoveryPage -Conn $conn -Rows @(,@{ id='f1'; parent_id='root'; name='a.txt'; rel_path='a.txt'; is_folder=0; size=150; last_modified=$null; created=$null; etag='e1-NEW'; ctag='c1'; quickxor='q1'; status='queued'; local_path='X:\a.txt'; error=$null })
Assert ((Invoke-Db -Conn $conn -Query "SELECT status FROM items WHERE id='f1'").status -eq 'queued') 'skipped row re-queued after filter change'

# deleted handling
Save-DiscoveryPage -Conn $conn -Rows @() -DeletedIds @('f2')
Assert ((Invoke-Db -Conn $conn -Query "SELECT status FROM items WHERE id='f2'").status -eq 'gone') 'deleted item marked gone'

# pending summary
$p = Get-PendingSummary -Conn $conn
Assert ([int64](Get-DbValue $p.active) -eq 1) 'pending summary counts queued' "active=$(Get-DbValue $p.active)"
Close-ExportDb -Conn $conn

Write-Host "`n--- GraphApi backoff helpers ---"
$Shared = [hashtable]::Synchronized(@{ Stop=$false; BackoffUntil=$null; Throttle429=0; Throttle5xx=0; LastBackoffReason='' })
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Start-GraphDelay -Shared $Shared -Attempt 0 -RetryAfterSec 1 -Reason 'test' -GlobalGate
$elapsed = $sw.Elapsed.TotalSeconds
Assert ($elapsed -ge 0.9 -and $elapsed -lt 5) 'Retry-After honoured' "waited ${elapsed}s"
Assert ($Shared.BackoffUntil -is [datetime]) 'global gate set'
$sw.Restart()
Wait-GraphBackoff -Shared $Shared   # gate already expired by now or expires momentarily
Assert ($sw.Elapsed.TotalSeconds -lt 3) 'backoff gate releases'

Write-Host "`n--- Logging ---"
$logDir = Join-Path $PSScriptRoot 'logs-unit'
if (Test-Path $logDir) { Remove-Item $logDir -Recurse -Force }
Initialize-Logging -LogDir $logDir
Write-Log -Level INFO -Message 'test entry' -Data @{ file = 'x.txt'; bytes = 42 }
$jsonl = Get-Content (Get-CurrentLogFile -Kind json) -Raw | ConvertFrom-Json
Assert ($jsonl.msg -eq 'test entry' -and $jsonl.bytes -eq 42) 'JSONL structured record'
Assert ((Get-Content (Get-CurrentLogFile -Kind text) -Raw) -match 'test entry') 'text log written'

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor ($(if ($script:fail -eq 0) { 'Green' } else { 'Red' }))
exit $script:fail
