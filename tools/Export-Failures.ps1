<#
.SYNOPSIS
    Exports all failed / retrying / gone items from the manifest to a CSV.
.EXAMPLE
    pwsh -File .\tools\Export-Failures.ps1 -OutFile .\failures.csv
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'),
    [string]$OutFile = (Join-Path (Split-Path $PSScriptRoot -Parent) ("failures-{0}.csv" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))),
    [switch]$IncludeGone
)
$ErrorActionPreference = 'Stop'
Import-Module PSSQLite

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\Config.psm1') -Force
Import-Module (Join-Path $root 'src\Database.psm1') -Force

$cfg = Get-ExportConfig -Path $ConfigPath
$conn = Open-ExportDb -Path $cfg.databasePath
try {
    $statuses = "'failed','retry_wait'"
    if ($IncludeGone) { $statuses += ",'gone'" }
    $rows = @(Invoke-Db -Conn $conn -Query @"
SELECT id, rel_path, local_path, size, status, attempts, last_attempt, next_retry_at, error
FROM items
WHERE is_folder = 0 AND status IN ($statuses)
ORDER BY rel_path
"@)
    if ($rows.Count -eq 0) {
        Write-Host 'No failed items - nothing to export.' -ForegroundColor Green
        return
    }
    $rows | Export-Csv -Path $OutFile -NoTypeInformation -Encoding utf8
    Write-Host "Exported $($rows.Count) rows to $OutFile"
} finally {
    Close-ExportDb -Conn $conn
}
