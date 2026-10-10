function Get-Ledger {
    <#
    .SYNOPSIS
    Returns the ledger entries, oldest first, as ordered hashtables. Does not verify the chain; use Test-Ledger for that.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $p = Resolve-LedgerPath -Path $Path
    if (-not (Test-Path -LiteralPath $p.File)) { throw "Ledger not found at '$($p.File)'." }

    foreach ($line in (Read-LedgerLines -File $p.File)) {
        # -AsHashtable: a body may hold names that differ only in case (an agent.snapshot env has HTTP_PROXY and http_proxy).
        $line | ConvertFrom-Json -AsHashtable
    }
}
