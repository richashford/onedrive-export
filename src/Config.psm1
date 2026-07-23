# Config.psm1 - load and validate the export configuration.

function Get-ExportConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path  (copy config.sample.json to config.json and edit it)"
    }

    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $baseDir = Split-Path -Path (Resolve-Path -LiteralPath $Path) -Parent

    # Defaults
    $cfg = [ordered]@{
        tenantId               = ''
        clientId               = ''
        userPrincipalName      = ''
        authMode               = 'DeviceCode'      # DeviceCode | Certificate
        certificateThumbprint  = ''
        certificatePfxPath     = ''
        destinationRoot        = ''
        concurrency            = 4
        maxRetries             = 8
        downloadBufferMB       = 1
        readStallTimeoutSec    = 180
        verifyMode             = 'size'            # size | timestamp | hash
        hashSpotCheckPercent   = 0
        timestampToleranceSec  = 5
        include                = @()
        exclude                = @()
        dashboardPort          = 8787
        statusIntervalSeconds  = 5
        diskMinFreeGB          = 20
        notifyWebhookUrl       = ''
        notifyFailureThreshold = 200
        databasePath           = ''
        logDir                 = ''
        stateDir               = ''
    }

    foreach ($p in $raw.PSObject.Properties) {
        if ($p.Name -eq 'paths') { continue }
        if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
    }

    # Resolve paths (relative to the config file's directory)
    $dbRel    = 'state\export.db'
    $logRel   = 'logs'
    $stateRel = 'state'
    if ($raw.paths) {
        if ($raw.paths.database) { $dbRel = $raw.paths.database }
        if ($raw.paths.logDir)   { $logRel = $raw.paths.logDir }
        if ($raw.paths.stateDir) { $stateRel = $raw.paths.stateDir }
    }
    $cfg.databasePath = Resolve-ConfigPath -Base $baseDir -Path $dbRel
    $cfg.logDir       = Resolve-ConfigPath -Base $baseDir -Path $logRel
    $cfg.stateDir     = Resolve-ConfigPath -Base $baseDir -Path $stateRel

    # Derived paths
    $cfg.statusDir   = Join-Path $cfg.stateDir 'status'
    $cfg.controlFile = Join-Path $cfg.stateDir 'control.json'
    $cfg.webRoot     = Join-Path $baseDir 'web'
    $cfg.baseDir     = $baseDir

    # Validation
    $errors = [System.Collections.Generic.List[string]]::new()
    if (-not $cfg.tenantId)          { $errors.Add('tenantId is required') }
    if (-not $cfg.clientId)          { $errors.Add('clientId is required') }
    if (-not $cfg.userPrincipalName) { $errors.Add('userPrincipalName is required') }
    if (-not $cfg.destinationRoot)   { $errors.Add('destinationRoot is required') }
    if ($cfg.authMode -notin @('DeviceCode', 'Certificate')) {
        $errors.Add("authMode must be 'DeviceCode' or 'Certificate' (got '$($cfg.authMode)')")
    }
    if ($cfg.authMode -eq 'Certificate' -and -not $cfg.certificateThumbprint -and -not $cfg.certificatePfxPath) {
        $errors.Add('Certificate auth requires certificateThumbprint or certificatePfxPath')
    }
    if ($cfg.verifyMode -notin @('size', 'timestamp', 'hash')) {
        $errors.Add("verifyMode must be size, timestamp or hash (got '$($cfg.verifyMode)')")
    }
    if ($cfg.concurrency -lt 1 -or $cfg.concurrency -gt 16) {
        $errors.Add('concurrency must be between 1 and 16 (keep it low: Graph throttles per-user)')
    }
    if ($errors.Count -gt 0) {
        throw "Invalid configuration:`n - " + ($errors -join "`n - ")
    }

    # Ensure working directories exist (destination is checked at runtime, it may be offline now)
    foreach ($d in @($cfg.stateDir, $cfg.logDir, $cfg.statusDir, (Split-Path $cfg.databasePath -Parent))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    return [pscustomobject]$cfg
}

function Resolve-ConfigPath {
    param([string]$Base, [string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $Base $Path)
}

Export-ModuleMember -Function Get-ExportConfig
