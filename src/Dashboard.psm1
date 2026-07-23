# Dashboard.psm1 - lightweight localhost web dashboard.
# Runs an HttpListener in a background thread. It ONLY reads JSON snapshot files
# written by the main loop (never touches SQLite), and writes control.json for
# pause/resume/stop commands. No cloud, no external dependencies.

function Start-DashboardJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$WebRoot,
        [Parameter(Mandatory)][string]$StatusDir,
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][string]$ControlFile,
        [Parameter(Mandatory)][hashtable]$Shared
    )

    $job = Start-ThreadJob -Name 'odx-dashboard' -ThrottleLimit 32 -ArgumentList @($Port, $WebRoot, $StatusDir, $LogDir, $ControlFile, $Shared) -ScriptBlock {
        param($Port, $WebRoot, $StatusDir, $LogDir, $ControlFile, $Shared)

        function Send-Bytes {
            param($Context, [byte[]]$Bytes, [string]$ContentType, [int]$Code = 200)
            try {
                $Context.Response.StatusCode = $Code
                $Context.Response.ContentType = $ContentType
                $Context.Response.Headers.Add('Cache-Control', 'no-store')
                $Context.Response.ContentLength64 = $Bytes.Length
                $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
            } catch { } finally {
                try { $Context.Response.OutputStream.Close() } catch { }
            }
        }

        function Send-Text {
            param($Context, [string]$Text, [string]$ContentType = 'text/plain; charset=utf-8', [int]$Code = 200)
            Send-Bytes -Context $Context -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text)) -ContentType $ContentType -Code $Code
        }

        function Send-JsonFile {
            param($Context, [string]$Path)
            if (Test-Path -LiteralPath $Path) {
                $bytes = $null
                # Retry briefly: the writer may be mid-rename.
                for ($i = 0; $i -lt 3; $i++) {
                    try { $bytes = [System.IO.File]::ReadAllBytes($Path); break } catch { Start-Sleep -Milliseconds 50 }
                }
                if ($bytes) { Send-Bytes -Context $Context -Bytes $bytes -ContentType 'application/json; charset=utf-8'; return }
            }
            Send-Text -Context $Context -Text '{}' -ContentType 'application/json; charset=utf-8'
        }

        function Get-LogTail {
            param([string]$LogDir, [int]$Lines)
            try {
                $latest = Get-ChildItem -LiteralPath $LogDir -Filter 'export-*.log' -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | Select-Object -First 1
                if (-not $latest) { return '(no log file yet)' }
                $fs = [System.IO.File]::Open($latest.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                    ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                try {
                    $take = [math]::Min($fs.Length, 131072)
                    $fs.Seek(-$take, [System.IO.SeekOrigin]::End) | Out-Null
                    $buf = [byte[]]::new($take)
                    $read = $fs.Read($buf, 0, $take)
                    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                } finally { $fs.Dispose() }
                $all = $text -split "`r?`n"
                $start = [math]::Max(0, $all.Count - $Lines)
                return (($all[$start..($all.Count - 1)]) -join "`n")
            } catch {
                return "(log tail unavailable: $($_.Exception.Message))"
            }
        }

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$Port/")
        try {
            $listener.Start()
        } catch {
            $Shared.DashboardError = "Dashboard failed to start on port ${Port}: $($_.Exception.Message). " +
                "If access was denied, run once as admin:  netsh http add urlacl url=http://localhost:$Port/ user=$env:USERNAME"
            return
        }
        $Shared.DashboardError = $null

        while (-not $Shared.Stop) {
            $ctxTask = $listener.GetContextAsync()
            $gotOne = $false
            while (-not $gotOne) {
                if ($ctxTask.Wait(1000)) { $gotOne = $true; break }
                if ($Shared.Stop) { break }
            }
            if (-not $gotOne) { break }
            $ctx = $ctxTask.Result

            try {
                $path = $ctx.Request.Url.AbsolutePath
                $method = $ctx.Request.HttpMethod

                if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
                    $file = Join-Path $WebRoot 'index.html'
                    if (Test-Path -LiteralPath $file) {
                        Send-Bytes -Context $ctx -Bytes ([System.IO.File]::ReadAllBytes($file)) -ContentType 'text/html; charset=utf-8'
                    } else {
                        Send-Text -Context $ctx -Text 'index.html not found' -Code 404
                    }
                }
                elseif ($method -eq 'GET' -and $path -eq '/api/status') {
                    Send-JsonFile -Context $ctx -Path (Join-Path $StatusDir 'status.json')
                }
                elseif ($method -eq 'GET' -and $path -eq '/api/failures') {
                    Send-JsonFile -Context $ctx -Path (Join-Path $StatusDir 'failures.json')
                }
                elseif ($method -eq 'GET' -and $path -eq '/api/log') {
                    $lines = 200
                    $q = $ctx.Request.QueryString['lines']
                    if ($q) { [int]::TryParse($q, [ref]$lines) | Out-Null }
                    if ($lines -lt 10) { $lines = 10 }
                    if ($lines -gt 2000) { $lines = 2000 }
                    Send-Text -Context $ctx -Text (Get-LogTail -LogDir $LogDir -Lines $lines)
                }
                elseif ($method -eq 'POST' -and $path -eq '/api/control') {
                    $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $body = $reader.ReadToEnd()
                    $reader.Dispose()
                    $cmd = $null
                    try { $cmd = ($body | ConvertFrom-Json).command } catch { }
                    if ($cmd -in @('pause', 'resume', 'stop')) {
                        $ctl = @{ command = $cmd; ts = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress
                        [System.IO.File]::WriteAllText($ControlFile, $ctl)
                        Send-Text -Context $ctx -Text '{"ok":true}' -ContentType 'application/json'
                    } else {
                        Send-Text -Context $ctx -Text '{"ok":false,"error":"command must be pause|resume|stop"}' -ContentType 'application/json' -Code 400
                    }
                }
                else {
                    Send-Text -Context $ctx -Text 'not found' -Code 404
                }
            } catch {
                try { Send-Text -Context $ctx -Text "server error: $($_.Exception.Message)" -Code 500 } catch { }
            }
        }
        try { $listener.Stop(); $listener.Close() } catch { }
    }

    return $job
}

Export-ModuleMember -Function Start-DashboardJob
