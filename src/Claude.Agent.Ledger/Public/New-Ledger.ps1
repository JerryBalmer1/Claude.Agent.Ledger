function New-Ledger {
    <#
    .SYNOPSIS
    Creates a ledger directory with ledger.jsonl and a 32-byte HMAC key, if they are absent.
    .DESCRIPTION
    Idempotent: an existing ledger or key is never overwritten. On Linux both files are set to 0600.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $p = Resolve-LedgerPath -Path $Path
    if (-not (Test-Path -LiteralPath $p.Directory)) {
        New-Item -ItemType Directory -Path $p.Directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $p.Key)) {
        $key = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
        # CreateNew so two racing callers cannot both write a key.
        try {
            $fs = [System.IO.File]::Open($p.Key, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $fs.Write($key, 0, $key.Length) } finally { $fs.Dispose() }
        }
        catch [System.IO.IOException] {
            if (-not (Test-Path -LiteralPath $p.Key)) { throw }
        }
    }

    if (-not (Test-Path -LiteralPath $p.File)) {
        try {
            [System.IO.File]::Open($p.File, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None).Dispose()
        }
        catch [System.IO.IOException] {
            if (-not (Test-Path -LiteralPath $p.File)) { throw }
        }
    }

    if ($IsLinux -or $IsMacOS) {
        $mode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
        [System.IO.File]::SetUnixFileMode($p.Key, $mode)
        [System.IO.File]::SetUnixFileMode($p.File, $mode)
    }

    Get-Item -LiteralPath $p.File
}
