# GraphAuth.psm1 - token acquisition for Microsoft Graph without external auth libraries.
#   DeviceCode  : delegated flow for interactive testing. Sign in AS the target user.
#                 Refresh token is cached DPAPI-encrypted so restarts are silent.
#   Certificate : client-credentials flow with a certificate (client assertion JWT)
#                 for unattended production runs. Fully non-interactive.

$script:LoginBase = 'https://login.microsoftonline.com'
$script:GraphScopeDelegated = 'https://graph.microsoft.com/Files.Read.All offline_access openid profile'
$script:GraphScopeApp       = 'https://graph.microsoft.com/.default'

function Get-GraphToken {
    <#
      Returns @{ AccessToken = <string>; ExpiresOn = [DateTimeOffset] }.
      Safe to call repeatedly; in DeviceCode mode it only prompts when no valid
      refresh token is cached.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$StateDir
    )
    if ($Config.authMode -eq 'Certificate') {
        return Get-TokenByCertificate -Config $Config
    }
    return Get-TokenByDeviceCode -Config $Config -StateDir $StateDir
}

# ---------------- Device code (delegated, interactive bootstrap) ----------------

function Get-TokenByDeviceCode {
    param($Config, [string]$StateDir)
    $tokenUrl = "$script:LoginBase/$($Config.tenantId)/oauth2/v2.0/token"
    $cacheFile = Join-Path $StateDir 'refresh_token.dat'

    # 1) Try cached refresh token (DPAPI-protected, current user only)
    $rt = Read-ProtectedString -Path $cacheFile
    if ($rt) {
        try {
            $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body @{
                client_id     = $Config.clientId
                grant_type    = 'refresh_token'
                refresh_token = $rt
                scope         = $script:GraphScopeDelegated
            }
            if ($resp.refresh_token) { Write-ProtectedString -Path $cacheFile -Value $resp.refresh_token }
            return New-TokenResult $resp
        } catch {
            Write-Warning "Cached refresh token was rejected; falling back to device-code sign-in. ($($_.Exception.Message))"
        }
    }

    # 2) Full device code flow
    $dc = Invoke-RestMethod -Method Post -Uri "$script:LoginBase/$($Config.tenantId)/oauth2/v2.0/devicecode" -Body @{
        client_id = $Config.clientId
        scope     = $script:GraphScopeDelegated
    }
    Write-Host ''
    Write-Host '=== SIGN-IN REQUIRED ===============================================' -ForegroundColor Cyan
    Write-Host $dc.message -ForegroundColor Cyan
    Write-Host "Sign in as the OneDrive owner: $($Config.userPrincipalName)" -ForegroundColor Cyan
    Write-Host '====================================================================' -ForegroundColor Cyan

    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([int]$dc.interval)
        try {
            $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body @{
                client_id   = $Config.clientId
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                device_code = $dc.device_code
            }
            if ($resp.refresh_token) { Write-ProtectedString -Path $cacheFile -Value $resp.refresh_token }
            return New-TokenResult $resp
        } catch {
            $err = Get-OAuthErrorCode $_
            if ($err -eq 'authorization_pending') { continue }
            if ($err -eq 'slow_down') { Start-Sleep -Seconds 5; continue }
            throw "Device code sign-in failed: $err - $($_.Exception.Message)"
        }
    }
    throw 'Device code sign-in timed out (code expired before anyone signed in).'
}

# ---------------- Certificate (application, unattended) ----------------

function Get-TokenByCertificate {
    param($Config)
    $cert = Get-AuthCertificate -Config $Config
    $tokenUrl = "$script:LoginBase/$($Config.tenantId)/oauth2/v2.0/token"
    $assertion = New-ClientAssertion -TenantId $Config.tenantId -ClientId $Config.clientId -Certificate $cert
    $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body @{
        client_id             = $Config.clientId
        grant_type            = 'client_credentials'
        scope                 = $script:GraphScopeApp
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $assertion
    }
    return New-TokenResult $resp
}

function Get-AuthCertificate {
    param($Config)
    if ($Config.certificateThumbprint) {
        foreach ($store in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
            $p = Join-Path $store $Config.certificateThumbprint
            if (Test-Path $p) {
                $cert = Get-Item $p
                if (-not $cert.HasPrivateKey) { throw "Certificate $($Config.certificateThumbprint) found in $store but has no private key." }
                return $cert
            }
        }
        throw "Certificate with thumbprint $($Config.certificateThumbprint) not found in CurrentUser\My or LocalMachine\My."
    }
    if ($Config.certificatePfxPath) {
        $pw = $env:ODEXPORT_PFX_PASSWORD
        if ($pw) {
            $sec = ConvertTo-SecureString -String $pw -AsPlainText -Force
            return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Config.certificatePfxPath, $sec)
        }
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Config.certificatePfxPath)
    }
    throw 'Certificate auth mode requires certificateThumbprint or certificatePfxPath.'
}

function New-ClientAssertion {
    param([string]$TenantId, [string]$ClientId, $Certificate)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = @{
        alg = 'RS256'
        typ = 'JWT'
        x5t = ConvertTo-Base64Url -Bytes $Certificate.GetCertHash()
    }
    $claims = @{
        aud = "$script:LoginBase/$TenantId/oauth2/v2.0/token"
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString()
        nbf = $now - 60
        exp = $now + 540
    }
    $headerB64 = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes(($header | ConvertTo-Json -Compress)))
    $claimsB64 = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress)))
    $unsigned = "$headerB64.$claimsB64"
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw 'Certificate private key is not RSA or is not accessible by this account.' }
    $sig = $rsa.SignData(
        [System.Text.Encoding]::UTF8.GetBytes($unsigned),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    return "$unsigned." + (ConvertTo-Base64Url -Bytes $sig)
}

# ---------------- helpers ----------------

function New-TokenResult {
    param($TokenResponse)
    return [pscustomobject]@{
        AccessToken = $TokenResponse.access_token
        ExpiresOn   = [DateTimeOffset]::UtcNow.AddSeconds([int]$TokenResponse.expires_in)
    }
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-OAuthErrorCode {
    param($ErrorRecord)
    try {
        $body = $ErrorRecord.ErrorDetails.Message
        if ($body) { return ($body | ConvertFrom-Json).error }
    } catch { }
    return 'unknown_error'
}

function Write-ProtectedString {
    # DPAPI (current user) protection via SecureString round-trip. Windows only.
    param([string]$Path, [string]$Value)
    try {
        $ss = ConvertTo-SecureString -String $Value -AsPlainText -Force
        $ss | ConvertFrom-SecureString | Set-Content -LiteralPath $Path -Encoding ascii
    } catch {
        Write-Warning "Could not cache refresh token: $($_.Exception.Message)"
    }
}

function Read-ProtectedString {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $enc = Get-Content -LiteralPath $Path -Raw
        $ss = $enc | ConvertTo-SecureString
        return [System.Net.NetworkCredential]::new('', $ss).Password
    } catch {
        return $null
    }
}

Export-ModuleMember -Function Get-GraphToken
