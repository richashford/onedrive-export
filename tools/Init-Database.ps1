<#
.SYNOPSIS
    Creates/initializes the SQLite manifest database (schema only).
    Normally not needed - Start-OneDriveExport.ps1 does this automatically -
    but useful for pre-creating the DB or repairing after schema inspection.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json')
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable PSSQLite)) { Install-Module PSSQLite -Scope CurrentUser -Force }
Import-Module PSSQLite

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\Config.psm1') -Force
Import-Module (Join-Path $root 'src\Database.psm1') -Force

$cfg = Get-ExportConfig -Path $ConfigPath
$conn = Open-ExportDb -Path $cfg.databasePath
try {
    Initialize-ExportDb -Conn $conn
    $tables = @(Invoke-Db -Conn $conn -Query "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    Write-Host "Database ready: $($cfg.databasePath)"
    Write-Host ("Tables: " + (($tables | ForEach-Object { $_.name }) -join ', '))
} finally {
    Close-ExportDb -Conn $conn
}
