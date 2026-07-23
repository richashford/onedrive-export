# Logging.psm1 - structured logging: JSON lines for machines, text log for humans.
# Files roll daily: export-YYYYMMDD.jsonl / export-YYYYMMDD.log

$script:LogDir  = $null
$script:LogLock = [object]::new()

function Initialize-Logging {
    param([Parameter(Mandatory)][string]$LogDir)
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $script:LogDir = $LogDir
}

function Get-CurrentLogFile {
    param([ValidateSet('text','json')][string]$Kind = 'text')
    if (-not $script:LogDir) { return $null }
    $stamp = (Get-Date).ToString('yyyyMMdd')
    if ($Kind -eq 'json') { return (Join-Path $script:LogDir "export-$stamp.jsonl") }
    return (Join-Path $script:LogDir "export-$stamp.log")
}

function Write-Log {
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data,
        [switch]$Console     # echo INFO/DEBUG to console too (WARN/ERROR always echo)
    )
    if (-not $script:LogDir) { return }
    $now = Get-Date
    $rec = [ordered]@{ ts = $now.ToUniversalTime().ToString('o'); level = $Level; msg = $Message }
    if ($Data) { foreach ($k in $Data.Keys) { $rec[$k] = $Data[$k] } }
    $json = [pscustomobject]$rec | ConvertTo-Json -Compress -Depth 6

    $text = '{0} [{1,-5}] {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Data -and $Data.Count -gt 0) {
        $pairs = foreach ($k in $Data.Keys) { '{0}={1}' -f $k, $Data[$k] }
        $text += '  |  ' + ($pairs -join ' ')
    }

    [System.Threading.Monitor]::Enter($script:LogLock)
    try {
        [System.IO.File]::AppendAllText((Get-CurrentLogFile -Kind json), $json + [Environment]::NewLine)
        [System.IO.File]::AppendAllText((Get-CurrentLogFile -Kind text), $text + [Environment]::NewLine)
    } finally {
        [System.Threading.Monitor]::Exit($script:LogLock)
    }

    if ($Level -eq 'ERROR')     { Write-Host $text -ForegroundColor Red }
    elseif ($Level -eq 'WARN')  { Write-Host $text -ForegroundColor Yellow }
    elseif ($Console)           { Write-Host $text }
}

Export-ModuleMember -Function Initialize-Logging, Write-Log, Get-CurrentLogFile
