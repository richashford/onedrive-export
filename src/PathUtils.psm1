# PathUtils.psm1 - Windows-safe filename sanitization and long-path helpers.

$script:InvalidFileChars = [System.IO.Path]::GetInvalidFileNameChars()
$script:ReservedNames = @('CON','PRN','AUX','NUL') + (1..9 | ForEach-Object { "COM$_"; "LPT$_" })

function ConvertTo-SafeName {
    <#
      Makes a single path segment (file or folder name) legal on NTFS/ReFS:
      - replaces invalid characters with '_'
      - trims trailing dots and spaces (illegal on Windows)
      - prefixes reserved device names (CON, PRN, COM1...) with '_'
      Returns the sanitized name; may equal the input.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $sb = [System.Text.StringBuilder]::new($Name.Length)
    foreach ($ch in $Name.ToCharArray()) {
        if ($script:InvalidFileChars -contains $ch) { [void]$sb.Append('_') }
        else { [void]$sb.Append($ch) }
    }
    $n = $sb.ToString().TrimEnd('.', ' ').TrimStart(' ')
    if ([string]::IsNullOrWhiteSpace($n)) { $n = '_' }

    $stem = $n.Split('.')[0].ToUpperInvariant()
    if ($script:ReservedNames -contains $stem) { $n = '_' + $n }
    return $n
}

function Get-LongPath {
    # Prefix with \\?\ so .NET file APIs handle paths beyond 260 chars.
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\'))   { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function Test-PathExcluded {
    <#
      Returns $true if the item should be excluded.
      Patterns without a path separator match the file/folder NAME (-like).
      Patterns containing \ or / match the full RELATIVE path.
      If Include is non-empty, the relative path must match at least one include pattern.
    #>
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Exclude = @(),
        [string[]]$Include = @()
    )
    $rel = $RelativePath.Replace('/', '\')
    foreach ($pat in $Exclude) {
        if ([string]::IsNullOrWhiteSpace($pat)) { continue }
        $p = $pat.Replace('/', '\')
        if ($p.Contains('\')) {
            if ($rel -like $p) { return $true }
        } elseif ($Name -like $p) { return $true }
    }
    if ($Include.Count -gt 0) {
        foreach ($pat in $Include) {
            $p = $pat.Replace('/', '\')
            if ($rel -like $p) { return $false }
        }
        return $true   # include list present and nothing matched -> excluded
    }
    return $false
}

Export-ModuleMember -Function ConvertTo-SafeName, Get-LongPath, Test-PathExcluded
