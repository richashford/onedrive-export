# Database.psm1 - SQLite persistence layer (system of record for the manifest).
# Requires the PSSQLite module. All DB access happens on the MAIN thread only;
# worker threads communicate results through in-memory queues.

$script:Schema = @'
CREATE TABLE IF NOT EXISTS items (
    id            TEXT PRIMARY KEY,
    parent_id     TEXT,
    name          TEXT NOT NULL,
    rel_path      TEXT NOT NULL,
    is_folder     INTEGER NOT NULL DEFAULT 0,
    size          INTEGER NOT NULL DEFAULT 0,
    last_modified TEXT,
    created       TEXT,
    etag          TEXT,
    ctag          TEXT,
    quickxor      TEXT,
    status        TEXT NOT NULL DEFAULT 'discovered',
    local_path    TEXT,
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_attempt  TEXT,
    next_retry_at TEXT,
    error         TEXT,
    completed_at  TEXT,
    verified_at   TEXT
);
CREATE INDEX IF NOT EXISTS idx_items_status  ON items(status);
CREATE INDEX IF NOT EXISTS idx_items_parent  ON items(parent_id);
CREATE INDEX IF NOT EXISTS idx_items_relpath ON items(rel_path COLLATE NOCASE);

CREATE TABLE IF NOT EXISTS state (
    key   TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS runs (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    started TEXT,
    ended   TEXT,
    mode    TEXT,
    notes   TEXT
);
'@

function Open-ExportDb {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $conn = New-SQLiteConnection -DataSource $Path
    Invoke-SqliteQuery -SQLiteConnection $conn -Query 'PRAGMA journal_mode=WAL;' | Out-Null
    Invoke-SqliteQuery -SQLiteConnection $conn -Query 'PRAGMA synchronous=NORMAL;' | Out-Null
    Invoke-SqliteQuery -SQLiteConnection $conn -Query 'PRAGMA busy_timeout=10000;' | Out-Null
    return $conn
}

function Initialize-ExportDb {
    param([Parameter(Mandatory)]$Conn)
    Invoke-SqliteQuery -SQLiteConnection $Conn -Query $script:Schema | Out-Null
}

function Close-ExportDb {
    param($Conn)
    if ($Conn) { try { $Conn.Close(); $Conn.Dispose() } catch { } }
}

function Invoke-Db {
    param(
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Params
    )
    if ($Params) {
        return Invoke-SqliteQuery -SQLiteConnection $Conn -Query $Query -SqlParameters $Params -As PSObject
    }
    return Invoke-SqliteQuery -SQLiteConnection $Conn -Query $Query -As PSObject
}

function Get-DbValue {
    # Normalizes DBNull to $null when reading query results.
    param($Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    return $Value
}

# ---------- state key/value ----------

function Get-StateValue {
    param([Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][string]$Key)
    $r = Invoke-Db -Conn $Conn -Query 'SELECT value FROM state WHERE key = @k' -Params @{ k = $Key }
    if ($r) { return (Get-DbValue $r.value) }
    return $null
}

function Set-StateValue {
    param([Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][string]$Key, $Value)
    $v = $Value
    if ($null -eq $v) { $v = [System.DBNull]::Value }
    Invoke-Db -Conn $Conn -Query 'INSERT INTO state (key, value) VALUES (@k, @v) ON CONFLICT(key) DO UPDATE SET value = excluded.value' -Params @{ k = $Key; v = $v } | Out-Null
}

function Remove-StateValue {
    param([Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][string]$Key)
    Invoke-Db -Conn $Conn -Query 'DELETE FROM state WHERE key = @k' -Params @{ k = $Key } | Out-Null
}

# ---------- transactions ----------

function Start-DbTransaction { param($Conn) Invoke-SqliteQuery -SQLiteConnection $Conn -Query 'BEGIN IMMEDIATE;' | Out-Null }
function Complete-DbTransaction { param($Conn) Invoke-SqliteQuery -SQLiteConnection $Conn -Query 'COMMIT;' | Out-Null }
function Undo-DbTransaction { param($Conn) try { Invoke-SqliteQuery -SQLiteConnection $Conn -Query 'ROLLBACK;' | Out-Null } catch { } }

# ---------- items ----------

$script:UpsertItemSql = @'
INSERT INTO items (id, parent_id, name, rel_path, is_folder, size, last_modified, created, etag, ctag, quickxor, status, local_path, error)
VALUES (@id, @parent_id, @name, @rel_path, @is_folder, @size, @last_modified, @created, @etag, @ctag, @quickxor, @status, @local_path, @error)
ON CONFLICT(id) DO UPDATE SET
    parent_id     = excluded.parent_id,
    name          = excluded.name,
    rel_path      = excluded.rel_path,
    is_folder     = excluded.is_folder,
    size          = excluded.size,
    last_modified = excluded.last_modified,
    created       = excluded.created,
    etag          = excluded.etag,
    ctag          = excluded.ctag,
    quickxor      = excluded.quickxor,
    local_path    = excluded.local_path,
    status        = CASE
                        WHEN items.etag = excluded.etag
                             AND items.status IN ('downloaded','verified')
                        THEN items.status
                        ELSE excluded.status
                    END,
    error         = CASE
                        WHEN items.etag = excluded.etag
                             AND items.status IN ('downloaded','verified')
                        THEN items.error
                        ELSE excluded.error
                    END
-- note: 'skipped' is deliberately NOT preserved - it is recomputed from the
-- current include/exclude config on every discovery pass, so changing filters
-- followed by -FullRescan re-queues previously skipped files.
'@

function Save-DiscoveryPage {
    <#
      Persists one page of delta results plus the delta paging cursor in a SINGLE
      transaction, so a crash resumes discovery exactly at the last committed page.
      $Rows: hashtables matching UpsertItemSql params. $DeletedIds: ids flagged deleted.
    #>
    param(
        [Parameter(Mandatory)]$Conn,
        [object[]]$Rows = @(),
        [string[]]$DeletedIds = @(),
        [string]$NextLink,
        [string]$DeltaLink
    )
    Start-DbTransaction -Conn $Conn
    try {
        foreach ($row in $Rows) {
            $p = @{}
            foreach ($key in $row.Keys) {
                if ($null -eq $row[$key]) { $p[$key] = [System.DBNull]::Value } else { $p[$key] = $row[$key] }
            }
            Invoke-SqliteQuery -SQLiteConnection $Conn -Query $script:UpsertItemSql -SqlParameters $p | Out-Null
        }
        foreach ($id in $DeletedIds) {
            Invoke-Db -Conn $Conn -Query @'
UPDATE items SET
    status = CASE WHEN status IN ('downloaded','verified') THEN status ELSE 'gone' END,
    error  = 'deleted in source (delta)'
WHERE id = @id
'@ -Params @{ id = $id } | Out-Null
        }
        if ($DeltaLink) {
            Invoke-Db -Conn $Conn -Query "INSERT INTO state (key,value) VALUES ('delta_link', @v) ON CONFLICT(key) DO UPDATE SET value=excluded.value" -Params @{ v = $DeltaLink } | Out-Null
            Invoke-Db -Conn $Conn -Query "DELETE FROM state WHERE key='delta_next'" | Out-Null
        } elseif ($NextLink) {
            Invoke-Db -Conn $Conn -Query "INSERT INTO state (key,value) VALUES ('delta_next', @v) ON CONFLICT(key) DO UPDATE SET value=excluded.value" -Params @{ v = $NextLink } | Out-Null
        }
        Complete-DbTransaction -Conn $Conn
    } catch {
        Undo-DbTransaction -Conn $Conn
        throw
    }
}

function Reset-StaleStatus {
    # Items left 'dispatched' by a previous crashed/stopped run go back to the queue.
    param([Parameter(Mandatory)]$Conn)
    Invoke-Db -Conn $Conn -Query "UPDATE items SET status='queued' WHERE status IN ('dispatched','downloading')" | Out-Null
}

function Get-NextBatch {
    <#
      Pulls the next set of downloadable files from durable state and marks them
      'dispatched'. Crash-safe: dispatched items are reset to queued on startup.
    #>
    param(
        [Parameter(Mandatory)]$Conn,
        [int]$Limit = 32
    )
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $rows = @(Invoke-Db -Conn $Conn -Query @'
SELECT id, rel_path, local_path, size, etag, attempts, status
FROM items
WHERE is_folder = 0
  AND (status = 'queued' OR (status = 'retry_wait' AND next_retry_at <= @now))
LIMIT @lim
'@ -Params @{ now = $now; lim = $Limit })

    if ($rows.Count -eq 0) { return @() }

    $params = @{}
    $names = for ($i = 0; $i -lt $rows.Count; $i++) {
        $params["p$i"] = $rows[$i].id
        "@p$i"
    }
    $sql = "UPDATE items SET status='dispatched' WHERE id IN (" + ($names -join ',') + ")"
    Invoke-SqliteQuery -SQLiteConnection $Conn -Query $sql -SqlParameters $params | Out-Null
    return $rows
}

function Get-DbStats {
    # Aggregate counts/bytes by status, split by folder flag.
    param([Parameter(Mandatory)]$Conn)
    return @(Invoke-Db -Conn $Conn -Query @'
SELECT status, is_folder, COUNT(*) AS cnt, IFNULL(SUM(size), 0) AS bytes
FROM items
GROUP BY status, is_folder
'@)
}

function Get-PendingSummary {
    param([Parameter(Mandatory)]$Conn)
    $r = Invoke-Db -Conn $Conn -Query @'
SELECT
    SUM(CASE WHEN status IN ('queued','dispatched') THEN 1 ELSE 0 END)                     AS active,
    SUM(CASE WHEN status = 'retry_wait' THEN 1 ELSE 0 END)                                 AS waiting,
    MIN(CASE WHEN status = 'retry_wait' THEN next_retry_at END)                            AS next_due,
    SUM(CASE WHEN status IN ('queued','dispatched','retry_wait') THEN size ELSE 0 END)     AS pending_bytes
FROM items
WHERE is_folder = 0
'@
    return $r
}

Export-ModuleMember -Function Open-ExportDb, Initialize-ExportDb, Close-ExportDb, Invoke-Db, Get-DbValue,
    Get-StateValue, Set-StateValue, Remove-StateValue,
    Start-DbTransaction, Complete-DbTransaction, Undo-DbTransaction,
    Save-DiscoveryPage, Reset-StaleStatus, Get-NextBatch, Get-DbStats, Get-PendingSummary
