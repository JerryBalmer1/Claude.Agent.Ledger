function Add-LedgerEntry {
    <#
    .SYNOPSIS
    Writer side: appends one unsigned entry {stamp, kind, body, seq} to <Spool>/pending.jsonl.
    .DESCRIPTION
    The writer never sees key.bin and never touches ledger.jsonl. Start-LedgerKeeper, running where the
    writer cannot reach, moves pending lines into the chained ledger and adds prev and mac.

    pending.jsonl is held with an exclusive lock while seq is advanced and the line written, so concurrent
    writers (and the keeper draining the spool) serialise. seq lives in <Spool>/seq and is advanced before
    the line is written: a crash in between leaves a gap in seq, never a reused one.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Spool')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Spool')][string] $Spool,
        # Not a way to write the ledger: it exists so that wiring the writer to the ledger fails loudly.
        [Parameter(Mandatory, ParameterSetName = 'Ledger', DontShow)][string] $Ledger,
        [Parameter(Mandatory)][string] $Kind,
        [hashtable] $Body = @{},
        [int] $LockTimeoutSeconds = 30
    )

    if ($PSCmdlet.ParameterSetName -eq 'Ledger') {
        throw 'Add-LedgerEntry writes to a spool only (-Spool). The ledger and its key belong to Start-LedgerKeeper.'
    }

    $dir = [System.IO.Path]::GetFullPath($Spool)
    foreach ($name in $script:KeyFileName, $script:LedgerFileName) {
        if (Test-Path -LiteralPath (Join-Path $dir $name)) {
            throw "'$dir' contains $name; it is a ledger directory, not a spool. Point -Spool at the spool volume."
        }
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $pendingFile = Join-Path $dir $script:PendingFileName
    $seqFile = Join-Path $dir $script:SeqFileName
    $created = -not (Test-Path -LiteralPath $pendingFile)

    $fs = Open-LockedFile -File $pendingFile -Mode OpenOrCreate -LockTimeoutSeconds $LockTimeoutSeconds
    try {
        if ($created) { Set-GroupSharedMode -File $pendingFile }

        # seq is only read and written while pending.jsonl is locked, so that lock covers it too.
        $last = 0L
        $seqIsNew = -not (Test-Path -LiteralPath $seqFile)
        if (-not $seqIsNew) {
            $text = [System.IO.File]::ReadAllText($seqFile).Trim()
            if ($text -and -not [long]::TryParse($text, [ref]$last)) { throw "Spool sequence file '$seqFile' is corrupt: '$text'." }
        }
        $seq = $last + 1
        [System.IO.File]::WriteAllText($seqFile, "$seq`n", $script:Utf8NoBom)
        if ($seqIsNew) { Set-GroupSharedMode -File $seqFile }

        $line = New-LedgerPayload -Kind $Kind -Body $Body -Seq $seq
        $existing = Read-StreamText -Stream $fs
        $prefix = if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { "`n" } else { '' }
        $bytes = $script:Utf8NoBom.GetBytes($prefix + $line + "`n")
        $fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
    }
    finally {
        $fs.Dispose()
    }

    # -AsHashtable: a body may hold names that differ only in case (an agent.snapshot env has HTTP_PROXY and http_proxy).
    $line | ConvertFrom-Json -AsHashtable
}
