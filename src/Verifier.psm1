# Verifier.psm1 - phase 3: verify downloaded files against the manifest.
#   size      : file exists and size matches (fast, default)
#   timestamp : size + last-modified within tolerance
#   hash      : size + QuickXorHash comparison (OneDrive for Business native hash)
# Files that fail verification are re-queued for download.

$script:QuickXorLoaded = $false

function Initialize-QuickXor {
    if ($script:QuickXorLoaded) { return }
    # Reference QuickXorHash implementation (Microsoft OneDrive documentation).
    $cs = @'
using System;
using System.Security.Cryptography;

public class QuickXorHash : HashAlgorithm
{
    private const int BitsInLastCell = 32;
    private const byte Shift = 11;
    private const byte WidthInBits = 160;

    private UInt64[] _data;
    private Int64 _lengthSoFar;
    private int _shiftSoFar;

    public QuickXorHash()
    {
        this.Initialize();
    }

    protected override void HashCore(byte[] array, int ibStart, int cbSize)
    {
        unchecked
        {
            int vectorArrayIndex = this._shiftSoFar / 64;
            int vectorOffset = this._shiftSoFar % 64;
            int iterations = Math.Min(cbSize, (int)QuickXorHash.WidthInBits);

            for (int i = 0; i < iterations; i++)
            {
                bool isLastCell = vectorArrayIndex == this._data.Length - 1;
                int bitsInVectorCell = isLastCell ? QuickXorHash.BitsInLastCell : 64;

                if (vectorOffset <= bitsInVectorCell - 8)
                {
                    for (int j = ibStart + i; j < cbSize + ibStart; j += QuickXorHash.WidthInBits)
                    {
                        this._data[vectorArrayIndex] ^= (ulong)array[j] << vectorOffset;
                    }
                }
                else
                {
                    int index1 = vectorArrayIndex;
                    int index2 = isLastCell ? 0 : (vectorArrayIndex + 1);
                    byte low = (byte)(bitsInVectorCell - vectorOffset);

                    for (int j = ibStart + i; j < cbSize + ibStart; j += QuickXorHash.WidthInBits)
                    {
                        this._data[index1] ^= (ulong)array[j] << vectorOffset;
                        this._data[index2] ^= (ulong)array[j] >> low;
                    }
                }

                vectorOffset += QuickXorHash.Shift;
                while (vectorOffset >= bitsInVectorCell)
                {
                    vectorArrayIndex = isLastCell ? 0 : vectorArrayIndex + 1;
                    vectorOffset -= bitsInVectorCell;
                }
            }
        }

        this._shiftSoFar = (this._shiftSoFar + QuickXorHash.Shift * (cbSize % QuickXorHash.WidthInBits)) % QuickXorHash.WidthInBits;
        this._lengthSoFar += cbSize;
    }

    protected override byte[] HashFinal()
    {
        byte[] rgb = new byte[(QuickXorHash.WidthInBits - 1) / 8 + 1];

        for (Int32 i = 0; i < this._data.Length - 1; i++)
        {
            Buffer.BlockCopy(BitConverter.GetBytes(this._data[i]), 0, rgb, i * 8, 8);
        }

        Buffer.BlockCopy(BitConverter.GetBytes(this._data[this._data.Length - 1]), 0,
            rgb, (this._data.Length - 1) * 8, rgb.Length - (this._data.Length - 1) * 8);

        var lengthBytes = BitConverter.GetBytes(this._lengthSoFar);
        for (int ii = 0; ii < lengthBytes.Length; ii++)
        {
            rgb[(QuickXorHash.WidthInBits / 8) - lengthBytes.Length + ii] ^= lengthBytes[ii];
        }

        return rgb;
    }

    public override sealed void Initialize()
    {
        this._data = new ulong[(QuickXorHash.WidthInBits - 1) / 64 + 1];
        this._lengthSoFar = 0;
        this._shiftSoFar = 0;
    }

    public override int HashSize
    {
        get { return (int)QuickXorHash.WidthInBits; }
    }
}
'@
    Add-Type -TypeDefinition $cs -ErrorAction Stop
    $script:QuickXorLoaded = $true
}

function Get-QuickXorHash {
    param([Parameter(Mandatory)][string]$Path)
    Initialize-QuickXor
    $algo = [QuickXorHash]::new()
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $hash = $algo.ComputeHash($fs)
        return [Convert]::ToBase64String($hash)
    } finally {
        $fs.Dispose()
        $algo.Dispose()
    }
}

function Invoke-VerifyPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)][hashtable]$Shared
    )

    $Shared.Phase = 'verify'
    $mode = [string]$Config.verifyMode
    $spotPct = [double]$Config.hashSpotCheckPercent
    $tolSec = [double]$Config.timestampToleranceSec
    Write-Log -Level INFO -Console -Message "Verify phase started" -Data @{ mode = $mode; hashSpotCheckPercent = $spotPct }

    $verified = [int64]0; $requeued = [int64]0; $hashed = [int64]0
    $lastId = ''
    $lastStatus = [datetime]::MinValue

    while ($true) {
        if ($Shared.Stop) { break }
        $rows = @(Invoke-Db -Conn $Conn -Query @'
SELECT id, rel_path, local_path, size, last_modified, quickxor
FROM items
WHERE is_folder = 0 AND status = 'downloaded' AND id > @last
ORDER BY id
LIMIT 500
'@ -Params @{ last = $lastId })
        if ($rows.Count -eq 0) { break }

        $updates = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $rows) {
            $lastId = [string]$row.id
            $local = [string](Get-DbValue $row.local_path)
            $rel = [string](Get-DbValue $row.rel_path)
            $expectedSize = [int64](Get-DbValue $row.size)
            $problem = $null

            $lpath = Get-LongPath -Path $local
            if (-not [System.IO.File]::Exists($lpath)) {
                $problem = 'verify: local file missing'
            } else {
                $fi = [System.IO.FileInfo]::new($lpath)
                if ($fi.Length -ne $expectedSize) {
                    $problem = "verify: size mismatch (local $($fi.Length), manifest $expectedSize)"
                } elseif ($mode -eq 'timestamp') {
                    $lm = Get-DbValue $row.last_modified
                    if ($lm) {
                        try {
                            $expected = ([datetime]::Parse([string]$lm, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal))
                            $delta = [math]::Abs(($fi.LastWriteTimeUtc - $expected).TotalSeconds)
                            if ($delta -gt $tolSec) { $problem = "verify: timestamp mismatch (off by $([math]::Round($delta,1))s)" }
                        } catch { }
                    }
                } elseif ($mode -eq 'hash') {
                    $expectedHash = [string](Get-DbValue $row.quickxor)
                    $doHash = $true
                    if ($spotPct -gt 0 -and $spotPct -lt 100) {
                        $doHash = ((Get-Random -Minimum 0.0 -Maximum 100.0) -lt $spotPct)
                    }
                    if ($expectedHash -and $doHash) {
                        $actual = Get-QuickXorHash -Path $lpath
                        $hashed++
                        if ($actual -ne $expectedHash) { $problem = 'verify: QuickXorHash mismatch' }
                    }
                }
            }

            if ($problem) {
                $updates.Add(@{ id = $row.id; ok = $false; err = $problem })
                Write-Log -Level WARN -Message 'verification failed - re-queued for download' -Data @{ file = $rel; reason = $problem }
            } else {
                $updates.Add(@{ id = $row.id; ok = $true; err = $null })
            }
        }

        Start-DbTransaction -Conn $Conn
        try {
            $now = [datetime]::UtcNow.ToString('o')
            foreach ($u in $updates) {
                if ($u.ok) {
                    Invoke-Db -Conn $Conn -Query "UPDATE items SET status='verified', verified_at=@now WHERE id=@id" -Params @{ id = $u.id; now = $now } | Out-Null
                    $verified++
                } else {
                    Invoke-Db -Conn $Conn -Query "UPDATE items SET status='queued', error=@err, verified_at=NULL, completed_at=NULL WHERE id=@id" -Params @{ id = $u.id; err = $u.err; now = $now } | Out-Null
                    $requeued++
                }
            }
            Complete-DbTransaction -Conn $Conn
        } catch {
            Undo-DbTransaction -Conn $Conn
            throw
        }

        if (([datetime]::UtcNow - $lastStatus).TotalSeconds -ge [int]$Config.statusIntervalSeconds) {
            $lastStatus = [datetime]::UtcNow
            Write-StatusSnapshot -Conn $Conn -Shared $Shared -Config $Config
            Write-Log -Level INFO -Console -Message "Verify progress" -Data @{ verified = $verified; requeued = $requeued; hashed = $hashed }
        }
    }

    Write-Log -Level INFO -Console -Message 'Verify phase finished' -Data @{ verified = $verified; requeuedForRedownload = $requeued; hashChecked = $hashed }
    return [pscustomobject]@{ Verified = $verified; Requeued = $requeued; Hashed = $hashed }
}

Export-ModuleMember -Function Invoke-VerifyPhase, Get-QuickXorHash
