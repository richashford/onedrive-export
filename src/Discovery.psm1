# Discovery.psm1 - phase 1: enumerate the entire drive into the manifest DB.
# Uses the Graph delta API:
#   - one flat, pageable stream of every item in the drive
#   - parents are always delivered before children, so relative paths can be
#     built from an id -> path map without extra requests
#   - the nextLink cursor is committed WITH each page, so discovery resumes
#     mid-enumeration after a crash
#   - the final deltaLink is stored; re-running discovery later only sees changes

function Invoke-DiscoveryPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)][hashtable]$Shared,
        [Parameter(Mandatory)][scriptblock]$RefreshToken,   # invoked once per page; keeps the token fresh
        [switch]$FullRescan
    )

    $Shared.Phase = 'discovery'
    & $RefreshToken

    # Resolve the user's default drive
    $upn = [uri]::EscapeDataString($Config.userPrincipalName)
    $drive = Invoke-GraphApi -Uri "/users/$upn/drive?`$select=id,driveType,quota,owner" -Shared $Shared
    Set-StateValue -Conn $Conn -Key 'drive_id' -Value $drive.id
    $Shared.DriveId = $drive.id
    if ($drive.quota) {
        $Shared.QuotaUsedBytes = [int64]$drive.quota.used
        Set-StateValue -Conn $Conn -Key 'quota_used' -Value ([string]$drive.quota.used)
    }
    Write-Log -Level INFO -Console -Message 'Resolved drive' -Data @{ driveId = $drive.id; quotaUsedGB = [math]::Round($drive.quota.used / 1GB, 1) }

    if ($FullRescan) {
        Remove-StateValue -Conn $Conn -Key 'delta_link'
        Remove-StateValue -Conn $Conn -Key 'delta_next'
        Write-Log -Level INFO -Console -Message 'FullRescan requested: delta cursor cleared, re-enumerating from scratch'
    }

    # Build folder-path cache from any previous discovery (id -> rel_path)
    $folderPaths = @{}
    foreach ($row in @(Invoke-Db -Conn $Conn -Query "SELECT id, rel_path FROM items WHERE is_folder = 1")) {
        $folderPaths[$row.id] = [string](Get-DbValue $row.rel_path)
    }

    # Resume cursor: mid-enumeration nextLink wins, else stored deltaLink (change scan), else fresh start
    $link = Get-StateValue -Conn $Conn -Key 'delta_next'
    $resuming = [bool]$link
    if (-not $link) { $link = Get-StateValue -Conn $Conn -Key 'delta_link' }
    if (-not $link) {
        $link = "/drives/$($drive.id)/root/delta?`$select=id,name,size,parentReference,file,folder,root,package,deleted,eTag,cTag,fileSystemInfo&`$top=999"
    }
    if ($resuming) { Write-Log -Level INFO -Console -Message 'Resuming interrupted discovery from saved page cursor' }

    $pageCount = 0
    $newFiles = 0
    $newBytes = [int64]0

    while ($link) {
        # Honour dashboard pause/stop during long enumerations too
        Read-ControlCommand -Config $Config -Shared $Shared
        while ($Shared.UserPaused -and -not $Shared.Stop) {
            $Shared.Phase = 'discovery (paused)'
            try { Write-StatusSnapshot -Conn $Conn -Shared $Shared -Config $Config } catch { }
            Start-Sleep -Seconds 2
            Read-ControlCommand -Config $Config -Shared $Shared
        }
        $Shared.Phase = 'discovery'
        if ($Shared.Stop) { Write-Log -Level WARN -Message 'Discovery interrupted by stop request (will resume from saved cursor)'; return $false }
        & $RefreshToken

        $page = Invoke-GraphApi -Uri $link -Shared $Shared
        $pageCount++

        $rows = [System.Collections.Generic.List[object]]::new()
        $deleted = [System.Collections.Generic.List[string]]::new()

        foreach ($it in $page.value) {
            if ($it.root) {
                $folderPaths[$it.id] = ''
                continue
            }
            if ($it.deleted) {
                $deleted.Add([string]$it.id)
                continue
            }

            $safeName = ConvertTo-SafeName -Name $it.name
            $parentId = $null
            if ($it.parentReference) { $parentId = $it.parentReference.id }

            $parentPath = $null
            if ($parentId -and $folderPaths.ContainsKey($parentId)) {
                $parentPath = $folderPaths[$parentId]
            } else {
                # Fallback: parse parentReference.path ("/drives/<id>/root:/A/B").
                $parentPath = ConvertFrom-ParentReferencePath -Item $it
            }

            $rel = $safeName
            if ($parentPath) { $rel = "$parentPath\$safeName" }

            # Collision guard: sanitization can map two distinct source names onto one
            # local name. Only when sanitization changed the name, check and de-dupe.
            if ($safeName -cne $it.name) {
                $clash = Invoke-Db -Conn $Conn -Query 'SELECT id FROM items WHERE rel_path = @rp COLLATE NOCASE AND id <> @id LIMIT 1' -Params @{ rp = $rel; id = $it.id }
                if ($clash) {
                    $suffix = '~' + ($it.id -replace '[^A-Za-z0-9]', '').Substring([math]::Max(0, ($it.id -replace '[^A-Za-z0-9]', '').Length - 6))
                    $ext = [System.IO.Path]::GetExtension($safeName)
                    $stem = [System.IO.Path]::GetFileNameWithoutExtension($safeName)
                    $safeName = "$stem$suffix$ext"
                    $rel = $safeName
                    if ($parentPath) { $rel = "$parentPath\$safeName" }
                }
            }

            $isFolder = [bool]$it.folder
            $isPackage = [bool]$it.package
            if ($isFolder) { $folderPaths[$it.id] = $rel }

            $status = 'discovered'
            $errMsg = $null
            $localPath = $null
            $size = [int64]0
            $quickxor = $null
            $lastMod = $null
            $created = $null

            if ($it.fileSystemInfo) {
                $lastMod = ConvertTo-IsoString $it.fileSystemInfo.lastModifiedDateTime
                $created = ConvertTo-IsoString $it.fileSystemInfo.createdDateTime
            }

            if (-not $isFolder) {
                $size = [int64]$it.size
                $localPath = Join-Path $Config.destinationRoot $rel
                if ($isPackage -or -not $it.file) {
                    # OneNote notebooks & other packages have no downloadable content stream
                    $status = 'skipped'
                    $errMsg = 'package item (e.g. OneNote notebook) - no content stream via Graph'
                } elseif (Test-PathExcluded -RelativePath $rel -Name $it.name -Exclude $Config.exclude -Include $Config.include) {
                    $status = 'skipped'
                    $errMsg = 'excluded by include/exclude pattern'
                } else {
                    $status = 'queued'
                    if ($it.file.hashes) { $quickxor = $it.file.hashes.quickXorHash }
                }
            }

            $rows.Add(@{
                id            = [string]$it.id
                parent_id     = $parentId
                name          = [string]$it.name
                rel_path      = $rel
                is_folder     = [int]$isFolder
                size          = $size
                last_modified = $lastMod
                created       = $created
                etag          = [string]$it.eTag
                ctag          = [string]$it.cTag
                quickxor      = $quickxor
                status        = $status
                local_path    = $localPath
                error         = $errMsg
            })

            if (-not $isFolder -and $status -eq 'queued') {
                $newFiles++
                $newBytes += $size
            }
        }

        # Commit page + cursor atomically
        Save-DiscoveryPage -Conn $Conn -Rows $rows.ToArray() -DeletedIds $deleted.ToArray() `
            -NextLink ([string]$page.'@odata.nextLink') -DeltaLink ([string]$page.'@odata.deltaLink')

        $Shared.DiscoveryPages = $pageCount

        # Keep the dashboard live during long enumerations
        if (($pageCount % 5) -eq 0) {
            try { Write-StatusSnapshot -Conn $Conn -Shared $Shared -Config $Config } catch { }
        }

        if (($pageCount % 10) -eq 0) {
            $pct = ''
            if ($Shared.QuotaUsedBytes -gt 0) {
                $stats = Get-DbStats -Conn $Conn
                $seen = [int64]0
                foreach ($s in $stats) { if (-not [int]$s.is_folder) { $seen += [int64]$s.bytes } }
                $pct = [string][math]::Round(100.0 * $seen / $Shared.QuotaUsedBytes, 1) + '% of quota'
            }
            Write-Log -Level INFO -Console -Message "Discovery progress: $pageCount pages" -Data @{ queuedThisRun = $newFiles; estimate = $pct }
        }

        if ($page.'@odata.deltaLink') {
            Write-Log -Level INFO -Console -Message 'Discovery complete' -Data @{ pages = $pageCount; newOrChangedFiles = $newFiles; newBytesGB = [math]::Round($newBytes / 1GB, 2) }
            return $true
        }
        $link = [string]$page.'@odata.nextLink'
    }
    return $true
}

function ConvertFrom-ParentReferencePath {
    # Fallback path builder from parentReference.path, only used if the parent
    # folder was not seen yet (should be rare: delta sends parents first).
    param($Item)
    try {
        $p = [string]$Item.parentReference.path
        if (-not $p) { return $null }
        $idx = $p.IndexOf('root:')
        if ($idx -lt 0) { return $null }
        $tail = $p.Substring($idx + 5).TrimStart('/')
        if (-not $tail) { return $null }
        $tail = [uri]::UnescapeDataString($tail)
        $parts = foreach ($seg in $tail.Split('/')) { ConvertTo-SafeName -Name $seg }
        return ($parts -join '\')
    } catch {
        return '_orphaned'
    }
}

function ConvertTo-IsoString {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    try { return ([datetime]::Parse([string]$Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)).ToString('o') }
    catch { return [string]$Value }
}

Export-ModuleMember -Function Invoke-DiscoveryPhase
