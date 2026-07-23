# GraphApi.psm1 - Microsoft Graph REST wrapper with throttling-aware retries.
# Implements Microsoft's throttling guidance:
#   - honours Retry-After on 429/503
#   - exponential backoff with jitter for transient failures
#   - a shared "backoff gate" so ALL workers pause together when throttled
# This module is imported by the main thread AND by download worker threads.
# It never touches the database.

$script:GraphBase = 'https://graph.microsoft.com/v1.0'
$script:UserAgent = 'OneDriveExport/1.0'

function Invoke-GraphApi {
    <#
      $Uri     : absolute URL (nextLink) or path relative to /v1.0 (e.g. "/users/x/drive").
      $Shared  : the synchronized session hashtable. Must contain AccessToken; the
                 function reads it fresh on every attempt so token refreshes by the
                 main loop are picked up automatically. Also uses/updates:
                 BackoffUntil, Throttle429, Throttle5xx, TokenExpired, Stop.
      Returns the parsed JSON body (PSCustomObject), $null for 404 with -AllowNotFound.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Shared,
        [string]$Method = 'GET',
        [switch]$AllowNotFound,
        [int]$MaxRetries = 10
    )

    $url = $Uri
    if (-not $url.StartsWith('http')) { $url = $script:GraphBase + $Uri }

    $auth401Count = 0
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        if ($Shared.Stop) { throw 'stop requested' }
        Wait-GraphBackoff -Shared $Shared

        $resp = $null
        try {
            $resp = Invoke-WebRequest -Uri $url -Method $Method -Headers @{
                Authorization = "Bearer $($Shared.AccessToken)"
                'User-Agent'  = $script:UserAgent
            } -SkipHttpErrorCheck -TimeoutSec 300 -ErrorAction Stop
        } catch {
            # DNS/socket/timeout level failure - retry with backoff
            if ($attempt -ge $MaxRetries) { throw "Graph request failed (network) after $($attempt) retries: $($_.Exception.Message)" }
            Start-GraphDelay -Shared $Shared -Attempt $attempt -Reason 'network'
            continue
        }

        $code = [int]$resp.StatusCode

        if ($code -ge 200 -and $code -lt 300) {
            if ([string]::IsNullOrEmpty($resp.Content)) { return $null }
            return ($resp.Content | ConvertFrom-Json -Depth 32)
        }

        if ($code -eq 404 -and $AllowNotFound) { return $null }

        if ($code -eq 401) {
            $auth401Count++
            if ($auth401Count -ge 2) {
                # Still 401 after a refresh opportunity: this is a permissions problem,
                # not an expired token. Fail fast with something actionable.
                throw "Graph request failed: HTTP 401 persists after token refresh. The token is valid but lacks the required permission. " +
                      "DeviceCode mode needs DELEGATED Files.Read.All (signed in as the drive owner); Certificate mode needs the " +
                      "APPLICATION permission Files.Read.All with admin consent granted (delegated consent does not apply to app-only tokens). ($url)"
            }
            # First 401: assume expiry. Signal the refresher and give it up to 60s.
            # (Worker threads get a fresh token from the main loop within seconds;
            # on the main thread this simply times out once and retries.)
            $oldToken = $Shared.AccessToken
            $Shared.TokenExpired = $true
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($Shared.AccessToken -eq $oldToken -and $sw.Elapsed.TotalSeconds -lt 60 -and -not $Shared.Stop) {
                Start-Sleep -Milliseconds 1000
            }
            continue
        }

        if ($code -eq 429 -or ($code -ge 500 -and $code -le 599)) {
            $retryAfter = Get-RetryAfterSeconds -Response $resp
            if ($code -eq 429) { $Shared.Throttle429 = [int]$Shared.Throttle429 + 1 }
            else               { $Shared.Throttle5xx = [int]$Shared.Throttle5xx + 1 }
            if ($attempt -ge $MaxRetries) { throw "Graph request failed: HTTP $code after $attempt retries ($url)" }
            Start-GraphDelay -Shared $Shared -Attempt $attempt -RetryAfterSec $retryAfter -Reason "http$code" -GlobalGate:($code -eq 429 -or $code -eq 503)
            continue
        }

        # Non-retryable (400, 403, plain 404, ...)
        $bodySnippet = ''
        if ($resp.Content) { $bodySnippet = ([string]$resp.Content) }
        if ($bodySnippet.Length -gt 500) { $bodySnippet = $bodySnippet.Substring(0, 500) }
        throw "Graph request failed: HTTP $code $bodySnippet ($url)"
    }
    throw "Graph request failed after $MaxRetries attempts ($url)"
}

function Get-RetryAfterSeconds {
    param($Response)
    try {
        if ($Response.Headers.ContainsKey('Retry-After')) {
            $v = @($Response.Headers['Retry-After'])[0]
            $sec = 0
            if ([int]::TryParse($v, [ref]$sec)) { return $sec }
        }
    } catch { }
    return 0
}

function Wait-GraphBackoff {
    # Global throttle gate: when set, every caller (all workers) waits together.
    param([hashtable]$Shared)
    while (-not $Shared.Stop) {
        $until = $Shared.BackoffUntil
        if ($null -eq $until -or (Get-Date) -ge $until) { return }
        Start-Sleep -Milliseconds 500
    }
}

function Start-GraphDelay {
    param(
        [hashtable]$Shared,
        [int]$Attempt,
        [int]$RetryAfterSec = 0,
        [string]$Reason = '',
        [switch]$GlobalGate
    )
    if ($RetryAfterSec -gt 0) {
        $delay = $RetryAfterSec
    } else {
        # exponential backoff with jitter, capped at 5 minutes
        $delay = [math]::Min(300, [math]::Pow(2, $Attempt) * 2)
        $delay = $delay + (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
    }
    if ($GlobalGate) {
        $gate = (Get-Date).AddSeconds($delay)
        if ($null -eq $Shared.BackoffUntil -or $gate -gt $Shared.BackoffUntil) {
            $Shared.BackoffUntil = $gate
        }
    }
    $Shared.LastBackoffReason = $Reason
    $end = (Get-Date).AddSeconds($delay)
    while ((Get-Date) -lt $end -and -not $Shared.Stop) { Start-Sleep -Milliseconds 250 }
}

Export-ModuleMember -Function Invoke-GraphApi, Wait-GraphBackoff, Start-GraphDelay, Get-RetryAfterSeconds
