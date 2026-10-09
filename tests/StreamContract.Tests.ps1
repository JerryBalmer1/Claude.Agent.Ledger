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
    $snapshots = @($parsed | Where-Object { $_.Obj.kind -eq 'agent.snapshot' })
    $fixtureKey = [byte[]]::new(32)   # docs/stream-contract.md, Fixture: macs recomputed with 32 zero bytes
    $contract = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../docs/stream-contract.md') -Raw
}

Describe 'policy-smoke fixture under the stream contract' {
    It 'is the 11-line fixture (ledger lines 46-54 plus two agent.snapshot lines): UTF-8, no BOM, LF only, final LF' {
        [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() |
            Should -Be '252c40e06d18332d6261c59b380f346fd9824ce13433c7520810079c7005856f'
        $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        $text | Should -Not -Match "`r"
        $text[-1] | Should -Be "`n"
        $lines | Should -HaveCount 11
    }

    It 'line <_> splits into payload, prev and mac (not malformed)' -ForEach (1..11) {
        $parsed[$_ - 1].Parts | Should -Not -BeNullOrEmpty
    }

    It 'line <_> has members stamp, kind, body, seq, prev, mac in that order' -ForEach (1..11) {
        @($parsed[$_ - 1].Obj.Keys) | Should -Be @('stamp', 'kind', 'body', 'seq', 'prev', 'mac')
    }

    It 'line <_> has a 7-digit UTC stamp, a non-empty kind, an object body and an integer seq' -ForEach (1..11) {
        $p = $parsed[$_ - 1]
        # stamp read from the raw text: ConvertFrom-Json would turn it into a local DateTime.
        $p.Line | Should -Match '^\{"stamp":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z","kind":"[^"]+","body":\{'
        $p.Obj.kind | Should -BeOfType [string]
        $p.Obj.body | Should -BeOfType [System.Collections.IDictionary]
        $p.Obj.seq.GetType().Name | Should -BeIn @('Int32', 'Int64')
    }

    It 'line <_> payload is one the keeper chains as-is (not ledger.rejected)' -ForEach (1..11) {
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

    It 'every mac is 64 lowercase hex and verifies under the fixture key' {
        foreach ($p in $parsed) {
            $p.Parts.Mac | Should -MatchExactly '^[0-9a-f]{64}$'
            $mac = & $module { param($k, $t) Get-HmacHex -Key $k -Text $t } $fixtureKey ($p.Parts.Prev + $p.Parts.Payload)
            $p.Parts.Mac | Should -Be $mac
        }
    }

    It 'seq runs 46..56 with no gap' {
        $seqs = @($parsed | ForEach-Object { [long]$_.Obj.seq })
        $seqs | Should -Be @(46..56)
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

    It 'is one run: starts with agent.egress-check, ends with agent.stop, a snapshot after the first and before the last' {
        @($parsed | ForEach-Object { $_.Obj.kind }) | Should -Be @(
            'agent.egress-check', 'agent.snapshot', 'agent.start', 'policy.allow', 'policy.allow', 'policy.allow',
            'policy.allow', 'policy.deny', 'agent.run', 'agent.snapshot', 'agent.stop')
        $parsed[0].Obj.body.directBlocked | Should -BeTrue
        $parsed[2].Obj.body.hostname | Should -Be 'ed543aff0ee7'
        $parsed[10].Obj.body.Count | Should -Be 0
    }
}

Describe 'agent.snapshot lines in the fixture' {
    It 'there are two, at agent.egress-check then agent.stop' {
        @($snapshots | ForEach-Object { $_.Obj.body.at }) | Should -Be @('agent.egress-check', 'agent.stop')
    }

    It 'snapshot <_> has exactly the contract members, with their types' -ForEach (0, 1) {
        $b = $snapshots[$_].Obj.body
        @($b.Keys | Sort-Object) | Should -Be @('at', 'env', 'errors', 'executables', 'gid', 'groups', 'imageDigest',
            'mcpServers', 'mounts', 'os', 'packageManager', 'packages', 'tools', 'uid', 'user')
        $b.env | Should -BeOfType [System.Collections.IDictionary]
        $b.imageDigest | Should -Match '^sha256:[0-9a-f]{64}$'
        $b.os['ID'] | Should -Be 'debian'
        $b.os['VERSION_ID'] | Should -Be '12'
        $b.packageManager | Should -Be 'dpkg'
        $b.packages.Count | Should -BeGreaterThan 50
        foreach ($p in $b.packages) { @($p.Keys) | Should -Be @('name', 'version') }
        $b.uid | Should -Be 10001
        $b.gid | Should -Be 10001
        $b.groups | Should -Be @(10001, 10100)
        $b.user | Should -Be 'agent'
        @($b.errors) | Should -HaveCount 0
        @($b.mcpServers) | Should -HaveCount 0
    }

    It 'snapshot <_> redacts the credential by name and lists claude with its libraries' -ForEach (0, 1) {
        $b = $snapshots[$_].Obj.body
        $b.env['CLAUDE_CODE_OAUTH_TOKEN'] | Should -Be '<redacted>'
        foreach ($name in $b.env.Keys) {
            if ($name -match 'token|secret|key|password|credential') { $b.env[$name] | Should -Be '<redacted>' -Because $name }
        }
        $claude = @($b.executables | Where-Object { $_.path -eq '/usr/local/bin/claude' })
        $claude | Should -HaveCount 1
        $claude[0].elf | Should -BeTrue
        $claude[0].libraries | Should -Contain 'libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6'
        foreach ($e in $b.executables) {
            @($e.Keys) | Should -Be @('path', 'target', 'elf', 'libraries')
            if (-not $e.elf) { $e.libraries | Should -BeNullOrEmpty }
            foreach ($l in @($e.libraries)) { $l | Should -Not -Match '\(0x' }
        }
    }

    It 'snapshot <_> shows the agent mounts spool rw and ca ro, and neither ledger nor capture' -ForEach (0, 1) {
        $m = $snapshots[$_].Obj.body.mounts
        @($m | Where-Object { $_.target -eq '/spool' }).options | Should -Match '^rw,'
        @($m | Where-Object { $_.target -eq '/ca' }).options | Should -Match '^ro,'
        @($m | Where-Object { $_.target -match '^/(ledger|capture)' }) | Should -HaveCount 0
    }

    It 'the policy hooks appear only in the agent.stop snapshot (the entrypoint merges them after egress-check)' {
        $snapshots[0].Obj.body.tools.hooks | Should -BeNullOrEmpty
        $snapshots[1].Obj.body.tools.hooks['PreToolUse'] | Should -Match '/opt/agent/policy/hooks/pre-tool-use.ps1'
        $snapshots[1].Obj.body.tools.named | Should -BeNullOrEmpty
    }
}

Describe 'policy.deny for a failed pre hook' {
    It 'the contract example is a line the keeper chains as-is, with reason hook-failure and no rule' {
        $m = [regex]::Match($contract, '(?s)### Hook failure.*?```json\r?\n(?<line>\{.*?\})\r?\n```')
        $m.Success | Should -BeTrue
        $line = $m.Groups['line'].Value
        & $module { param($l) Test-PendingLine -Line $l } $line | Should -BeNullOrEmpty
        $obj = $line | ConvertFrom-Json -AsHashtable
        $obj.kind | Should -Be 'policy.deny'
        @($obj.body.Keys | Sort-Object) | Should -Be @('error', 'kindAction', 'path', 'phase', 'reason', 'rule', 'tool')
        $obj.body.reason | Should -Be 'hook-failure'
        $obj.body.phase | Should -Be 'pre'
        $obj.body.rule | Should -BeNullOrEmpty
    }
}
