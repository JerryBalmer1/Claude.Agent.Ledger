BeforeAll {
    $module = Import-Module (Join-Path $PSScriptRoot '../src/Claude.Agent.Ledger/Claude.Agent.Ledger.psd1') -Force -PassThru
    $fixture = Join-Path $PSScriptRoot 'fixtures/policy-smoke.ledger.jsonl'
    $bytes = [System.IO.File]::ReadAllBytes($fixture)
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $lines = [string[]]($text.Substring(0, $text.Length - 1) -split "`n")

    # The keeper's own parsing (docs/stream-contract.md), not a copy of it.
    $parsed = foreach ($line in $lines) {
        $parts = & $module { param($l) Split-LedgerLine -Line $l } $line
        $obj = if ($parts) { $line | ConvertFrom-Json -AsHashtable } else { $null }
        [pscustomobject]@{ Line = $line; Parts = $parts; Obj = $obj }
    }
    $policyDenials = @($parsed | Where-Object { $_.Obj.kind -eq 'policy.deny' })
}

Describe 'policy-smoke fixture under the stream contract' {
    It 'is the verbatim 9-line slice (ledger lines 46-54): UTF-8, no BOM, LF only, final LF' {
        [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() |
            Should -Be '8a6a6941ffdd7fecbde72daca03a2d9d69b9e814fc01b427afff876a91130e5a'
        $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        $text | Should -Not -Match "`r"
        $text[-1] | Should -Be "`n"
        $lines | Should -HaveCount 9
    }

    It 'line <_> splits into payload, prev and mac (not malformed)' -ForEach (1..9) {
        $parsed[$_ - 1].Parts | Should -Not -BeNullOrEmpty
    }

    It 'line <_> has members stamp, kind, body, seq, prev, mac in that order' -ForEach (1..9) {
        @($parsed[$_ - 1].Obj.Keys) | Should -Be @('stamp', 'kind', 'body', 'seq', 'prev', 'mac')
    }

    It 'line <_> has a 7-digit UTC stamp, a non-empty kind, an object body and an integer seq' -ForEach (1..9) {
        $p = $parsed[$_ - 1]
        # stamp read from the raw text: ConvertFrom-Json would turn it into a local DateTime.
        $p.Line | Should -Match '^\{"stamp":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z","kind":"[^"]+","body":\{'
        $p.Obj.kind | Should -BeOfType [string]
        $p.Obj.body | Should -BeOfType [System.Collections.IDictionary]
        $p.Obj.seq.GetType().Name | Should -BeIn @('Int32', 'Int64')
    }

    It 'line <_> payload is one the keeper chains as-is (not ledger.rejected)' -ForEach (1..9) {
        $payload = $parsed[$_ - 1].Parts.Payload
        & $module { param($l) Test-PendingLine -Line $l } $payload | Should -BeNullOrEmpty
        $parsed[$_ - 1].Line | Should -BeExactly ($payload.Substring(0, $payload.Length - 1) +
            ',"prev":"' + $parsed[$_ - 1].Parts.Prev + '","mac":"' + $parsed[$_ - 1].Parts.Mac + '"}')
    }

    It 'the hash chain verifies end to end from the anchor (SHA-256 of ledger line 45)' {
        $parsed[0].Parts.Prev | Should -Be '00a198bc39ddaa86daafd334bdf24865c84cf9c840412281446c7ab730ec405f'
        for ($i = 1; $i -lt $parsed.Count; $i++) {
            $expected = & $module { param($t) Get-Sha256Hex -Text $t } $parsed[$i - 1].Line
            $parsed[$i].Parts.Prev | Should -Be $expected -Because "line $($i + 1) must chain to line $i"
        }
    }

    It 'every mac is 64 lowercase hex (key.bin is not kept, so the HMAC itself is not rechecked)' {
        foreach ($p in $parsed) { $p.Parts.Mac | Should -MatchExactly '^[0-9a-f]{64}$' }
    }

    It 'seq runs 46..54 with no gap' {
        $seqs = @($parsed | ForEach-Object { [long]$_.Obj.seq })
        $seqs | Should -Be @(46..54)
    }

    It 'has exactly one denial, a pre-phase policy.deny naming rules[2], with no post line after it' {
        $policyDenials | Should -HaveCount 1
        @($parsed | Where-Object { $_.Obj.body['rule'] -eq 'rules[2]' }) | Should -HaveCount 1
        $d = $policyDenials[0].Obj.body
        $d.rule | Should -Be 'rules[2]'
        $d.phase | Should -Be 'pre'
        $d.kindAction | Should -Be 'File.delete'
        $d.path | Should -Be '/work/policy-smoke.txt'
        $d.tool | Should -Be 'Bash'
        $d.command | Should -Be 'rm /work/policy-smoke.txt'
        $d.reason | Should -Be 'File.delete /work/policy-smoke.txt denied by policy rules[2]'
        @($parsed | Where-Object { $_.Obj.kind -like 'policy.*' -and $_.Obj.body.phase -eq 'post' -and $_.Obj.body.tool -eq 'Bash' }) |
            Should -HaveCount 0
    }

    It 'allowed calls come in pre/post pairs; only pre lines carry reason' {
        $allow = @($parsed | Where-Object { $_.Obj.kind -eq 'policy.allow' } | ForEach-Object { $_.Obj.body })
        @($allow | ForEach-Object { "$($_.phase) $($_.tool) $($_.rule)" }) |
            Should -Be @('pre Read rules[3]', 'post Read rules[3]', 'pre Write rules[4]', 'post Write rules[4]')
        foreach ($b in $allow) { $b.Contains('reason') | Should -Be ($b.phase -eq 'pre') }
    }

    It 'is one run: starts with agent.egress-check, ends with agent.stop' {
        @($parsed | ForEach-Object { $_.Obj.kind }) | Should -Be @(
            'agent.egress-check', 'agent.start', 'policy.allow', 'policy.allow', 'policy.allow', 'policy.allow',
            'policy.deny', 'agent.run', 'agent.stop')
        $parsed[0].Obj.body.directBlocked | Should -BeTrue
        $parsed[1].Obj.body.hostname | Should -Be 'ed543aff0ee7'
        $parsed[8].Obj.body.Count | Should -Be 0
    }
}
