function Start-LedgerKeeper {
    <#
    .SYNOPSIS
    Keeper side: moves pending lines from <Spool>/pending.jsonl into the chained <Ledger>/ledger.jsonl.
    .DESCRIPTION
    Creates the ledger and key.bin (New-Ledger) if absent, then flushes every -IntervalMilliseconds until
    SIGTERM, and flushes once more before returning. With -Once it flushes a single time and returns the
    number of lines it moved.

    On start (with or without -Once) the spool's seq counter is raised to the last seq in the ledger or the
    spool, whichever is higher, so the writer continues the ledger's sequence even if the spool's counter was
    lost; it is never lowered (design.md 4).

    Each pending line's exact text becomes the payload of a ledger line; the keeper appends prev and mac.
    A line that is not a {stamp, kind, body, seq} object (stamp a UTC yyyy-MM-ddTHH:mm:ss.fffffffZ string, kind
    a non-empty string, body an object, seq an integer) is not chained as-is: the keeper ledgers a
    `ledger.rejected` entry carrying the raw text instead, so nothing the writer sent is silently dropped.
    Consumed lines are then truncated from the spool. If the keeper dies between the two steps, the next
    flush skips what it already handled: a line chained as-is by exact match on the trailing entries' payloads,
    a rejected line by exact match on their body.line, if it carries a stamp. A stampless rejected line may
    repeat honestly, so it is ledgered again rather than dropped (design.md 5).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Spool,
        [Parameter(Mandatory)][string] $Ledger,
        [int] $IntervalMilliseconds = 500,
        [int] $LockTimeoutSeconds = 30,
        [switch] $Once
    )

    $spoolDir = [System.IO.Path]::GetFullPath($Spool)
    $p = Resolve-LedgerPath -Path $Ledger
    if ($spoolDir.TrimEnd('/', '\') -eq $p.Directory.TrimEnd('/', '\')) {
        throw 'The spool and the ledger must be different directories: the writer can reach the spool.'
    }
    New-Ledger -Path $p.Directory | Out-Null
    $key = Get-LedgerKey -KeyPath $p.Key
    $sync = Sync-SpoolSeq -SpoolDir $spoolDir -LedgerFile $p.File -LockTimeoutSeconds $LockTimeoutSeconds

    $flush = {
        Invoke-LedgerFlush -PendingFile (Join-Path $spoolDir $script:PendingFileName) -LedgerFile $p.File -Key $key -LockTimeoutSeconds $LockTimeoutSeconds
    }

    if ($Once) { return (& $flush) }

    Register-KeeperSignal
    Write-Host "ledger keeper: $spoolDir -> $($p.File), every $IntervalMilliseconds ms; seq resumes after $($sync.Resume) (ledger $($sync.Ledger), pending $($sync.Pending), spool counter $($sync.Spool))"
    while (-not [ClaudeAgentLedger.KeeperSignal]::Stop) {
        $moved = & $flush
        if ($moved) { Write-Host "ledger keeper: moved $moved" }
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
    $moved = & $flush
    Write-Host "ledger keeper: SIGTERM; final flush moved $moved"
}
