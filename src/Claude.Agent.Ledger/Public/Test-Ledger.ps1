function Test-Ledger {
    <#
    .SYNOPSIS
    Walks the hash chain and checks every MAC. Returns $true or throws naming the first bad line.
    .DESCRIPTION
    Every bad line is listed in the error, so a single edited line shows up as that line (MAC mismatch)
    and the line after it (prev mismatch).

    Writer lines also carry seq, which must run 1, 2, 3, ... with no gap or repeat. A line whose seq is not
    the previous seq + 1 (or not 1, for the first) is bad with reason seq-gap; checking resumes from its seq,
    so one dropped line is one seq-gap. Lines without seq (keeper-written ledger.rejected, 0.1.0 lines) are
    not counted (design.md 4).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Path)

    $p = Resolve-LedgerPath -Path $Path
    if (-not (Test-Path -LiteralPath $p.File)) { throw "Ledger not found at '$($p.File)'." }
    $key = Get-LedgerKey -KeyPath $p.Key
    $lines = Read-LedgerLines -File $p.File

    $bad = [System.Collections.Generic.List[string]]::new()
    $expectedPrev = $script:GenesisPrev
    $lastSeq = 0L
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $n = $i + 1
        $line = $lines[$i]
        $parts = Split-LedgerLine -Line $line
        if (-not $parts) {
            $bad.Add("line $n (malformed)")
        }
        else {
            $reasons = @()
            if ($parts.Prev -ne $expectedPrev) { $reasons += 'prev mismatch' }
            $mac = Get-HmacHex -Key $key -Text ($parts.Prev + $parts.Payload)
            $equal = [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                [System.Text.Encoding]::ASCII.GetBytes($mac), [System.Text.Encoding]::ASCII.GetBytes($parts.Mac))
            if (-not $equal) { $reasons += 'mac mismatch' }
            $seq = Get-PayloadSeq -Payload $parts.Payload
            if ($null -ne $seq) {
                if ($seq -ne $lastSeq + 1) { $reasons += 'seq-gap' }
                $lastSeq = $seq
            }
            if ($reasons) { $bad.Add("line $n ($($reasons -join ', '))") }
        }
        $expectedPrev = Get-Sha256Hex -Text $line
    }

    if ($bad.Count -gt 0) {
        $msg = "Ledger '$($p.File)' failed verification at $($bad[0])"
        if ($bad.Count -gt 1) { $msg += "; also bad: $(($bad | Select-Object -Skip 1) -join '; ')" }
        throw $msg
    }
    $true
}
