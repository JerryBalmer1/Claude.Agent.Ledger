# Keeper internals: SIGTERM flag and one spool-to-ledger flush. Not exported.

function Register-KeeperSignal {
    # A PowerShell scriptblock cannot run on the signal thread (no runspace), so the handler is a C# lambda
    # that only sets a flag; the loop polls it. Cancel = true stops .NET's default terminate-on-SIGTERM.
    if (-not ('ClaudeAgentLedger.KeeperSignal' -as [type])) {
        Add-Type -TypeDefinition @'
namespace ClaudeAgentLedger {
    public static class KeeperSignal {
        public static volatile bool Stop;
        static System.Runtime.InteropServices.PosixSignalRegistration registration;
        public static void Register() {
            if (registration != null) return;
            registration = System.Runtime.InteropServices.PosixSignalRegistration.Create(
                System.Runtime.InteropServices.PosixSignal.SIGTERM, c => { c.Cancel = true; Stop = true; });
        }
    }
}
'@
    }
    [ClaudeAgentLedger.KeeperSignal]::Register()
}

# On keeper start: the ledger, not the spool, says where seq stands. Raises <Spool>/seq to the highest seq in
# the ledger or still pending, so a lost or reset spool counter (spool volume recreated, seq file deleted)
# continues the chain instead of restarting at 1. Never lowers it: a counter ahead of everything seen means a
# line was lost before it reached the ledger, and lowering would let the next line hide that gap (design.md 4).
function Sync-SpoolSeq {
    param(
        [Parameter(Mandatory)][string] $SpoolDir,
        [Parameter(Mandatory)][string] $LedgerFile,
        [int] $LockTimeoutSeconds = 30
    )

    if (-not (Test-Path -LiteralPath $SpoolDir)) { New-Item -ItemType Directory -Path $SpoolDir -Force | Out-Null }
    $pendingFile = Join-Path $SpoolDir $script:PendingFileName
    $seqFile = Join-Path $SpoolDir $script:SeqFileName
    $created = -not (Test-Path -LiteralPath $pendingFile)

    # The writer reads and advances seq only under the pending.jsonl lock; so does this.
    $spool = Open-LockedFile -File $pendingFile -Mode OpenOrCreate -LockTimeoutSeconds $LockTimeoutSeconds
    try {
        if ($created) { Set-GroupSharedMode -File $pendingFile }

        $ledgerSeq = 0L
        $lines = Read-LedgerLines -File $LedgerFile
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $parts = Split-LedgerLine -Line $lines[$i]
            $seq = if ($parts) { Get-PayloadSeq -Payload $parts.Payload } else { $null }
            if ($null -ne $seq) { $ledgerSeq = $seq; break }
        }

        $pendingSeq = 0L
        foreach ($line in ((Read-StreamText -Stream $spool) -split "`n")) {
            $seq = Get-PayloadSeq -Payload $line
            if ($null -ne $seq -and $seq -gt $pendingSeq) { $pendingSeq = $seq }
        }

        $spoolSeq = 0L
        $seqIsNew = -not (Test-Path -LiteralPath $seqFile)
        if (-not $seqIsNew) { [void][long]::TryParse([System.IO.File]::ReadAllText($seqFile).Trim(), [ref]$spoolSeq) }

        $resume = [Math]::Max($spoolSeq, [Math]::Max($ledgerSeq, $pendingSeq))
        if ($resume -ne $spoolSeq -or $seqIsNew) {
            [System.IO.File]::WriteAllText($seqFile, "$resume`n", $script:Utf8NoBom)
            if ($seqIsNew) { Set-GroupSharedMode -File $seqFile }
        }
        [pscustomobject]@{ Ledger = $ledgerSeq; Pending = $pendingSeq; Spool = $spoolSeq; Resume = $resume }
    }
    finally {
        $spool.Dispose()
    }
}

function Invoke-LedgerFlush {
    param(
        [Parameter(Mandatory)][string] $PendingFile,
        [Parameter(Mandatory)][string] $LedgerFile,
        [Parameter(Mandatory)][byte[]] $Key,
        [int] $LockTimeoutSeconds = 30
    )

    if (-not (Test-Path -LiteralPath $PendingFile) -or (Get-Item -LiteralPath $PendingFile).Length -eq 0) { return 0 }

    # Lock order is always spool then ledger; writers only ever take the spool lock.
    $spool = Open-LockedFile -File $PendingFile -LockTimeoutSeconds $LockTimeoutSeconds
    try {
        $text = Read-StreamText -Stream $spool
        $end = $text.LastIndexOf("`n")
        if ($end -lt 0) { return 0 }   # only a partial line; the writer has not finished it
        $pending = [string[]]($text.Substring(0, $end) -split "`n")
        $rest = $text.Substring($end + 1)

        $ledger = Open-LockedFile -File $LedgerFile -LockTimeoutSeconds $LockTimeoutSeconds
        try {
            # Lines a previous flush already chained but did not get to truncate.
            $tail = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $chained = Read-StreamText -Stream $ledger
            if ($chained.Length -gt 0) {
                $all = $chained.TrimEnd("`n") -split "`n"
                foreach ($line in ($all | Select-Object -Last $pending.Count)) {
                    $parts = Split-LedgerLine -Line $line
                    if ($parts) { [void]$tail.Add($parts.Payload) }
                }
            }

            $payloads = @(foreach ($line in $pending) {
                if ($line.Length -eq 0) { continue }
                if ($tail.Contains($line)) { continue }
                $reason = Test-PendingLine -Line $line
                if ($reason) { New-LedgerPayload -Kind 'ledger.rejected' -Body @{ reason = $reason; line = $line } }
                else { $line }
            })
            if ($payloads.Count) { Write-LedgerLines -Stream $ledger -Key $Key -Payloads $payloads | Out-Null }
        }
        finally {
            $ledger.Dispose()
        }

        # Only now drop what was consumed; a partial trailing line (if any) stays for the next flush.
        $spool.SetLength(0)
        if ($rest.Length -gt 0) {
            $bytes = $script:Utf8NoBom.GetBytes($rest)
            $spool.Write($bytes, 0, $bytes.Length)
        }
        $spool.Flush($true)
        $payloads.Count
    }
    finally {
        $spool.Dispose()
    }
}
