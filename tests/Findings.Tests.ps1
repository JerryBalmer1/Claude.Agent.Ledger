# The 0.2.3 findings (docs/stream-contract.md, Findings), fixed in 0.2.4.
BeforeAll {
    $module = Import-Module (Join-Path $PSScriptRoot '../src/Claude.Agent.Ledger/Claude.Agent.Ledger.psd1') -Force -PassThru
    $okStamp = '2026-10-09T02:50:43.7976027Z'
}

Describe 'Finding 2: a rejected spool line is not ledgered twice after a keeper restart' {
    BeforeEach {
        $dir = Join-Path $TestDrive "ledger-$([guid]::NewGuid())"
        $spool = Join-Path $TestDrive "spool-$([guid]::NewGuid())"
        $pending = Join-Path $spool 'pending.jsonl'
        New-Item -ItemType Directory -Path $spool | Out-Null
    }

    It 'skips a stamped rejected line the previous flush already ledgered but did not truncate' {
        $bad = '{"stamp":"' + $okStamp + '","kind":"agent.run","body":"not an object","seq":1}'
        Set-Content -LiteralPath $pending -Value "$bad`n" -NoNewline
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 1

        # The keeper died after chaining, before truncating: the spool still holds the line. A new keeper starts.
        Set-Content -LiteralPath $pending -Value "$bad`n" -NoNewline
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 0

        $entries = @(Get-Ledger -Path $dir)
        $entries.kind | Should -Be @('ledger.rejected')
        $entries[0].body.line | Should -BeExactly $bad
        (Get-Item $pending).Length | Should -Be 0
        Test-Ledger -Path $dir | Should -BeTrue
    }

    It 'skips it alongside chained lines in the same re-flushed batch' {
        Add-LedgerEntry -Spool $spool -Kind 'good.1' | Out-Null
        Add-Content -LiteralPath $pending -Value ('{"stamp":"' + $okStamp + '","kind":"","body":{},"seq":9}')
        Add-LedgerEntry -Spool $spool -Kind 'good.2' | Out-Null
        $copy = Get-Content -LiteralPath $pending -Raw
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 3
        Set-Content -LiteralPath $pending -Value $copy -NoNewline

        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 0
        @(Get-Ledger -Path $dir).kind | Should -Be @('good.1', 'ledger.rejected', 'good.2')
    }

    It 'still ledgers a new rejected line whose text differs only in its stamp' {
        $first = '{"stamp":"' + $okStamp + '","kind":"x","body":[],"seq":1}'
        $second = '{"stamp":"2026-10-09T02:50:43.7976028Z","kind":"x","body":[],"seq":1}'
        Set-Content -LiteralPath $pending -Value "$first`n" -NoNewline
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 1
        Set-Content -LiteralPath $pending -Value "$second`n" -NoNewline
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 1
        @(Get-Ledger -Path $dir).body.line | Should -Be @($first, $second)
    }

    It 'never skips a rejected line without a stamp: a repeat is over-recorded, not dropped' {
        Set-Content -LiteralPath $pending -Value "not json`n" -NoNewline
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 1
        Set-Content -LiteralPath $pending -Value "not json`n" -NoNewline
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 1
        @(Get-Ledger -Path $dir).kind | Should -Be @('ledger.rejected', 'ledger.rejected')
    }
}

Describe 'Finding 4: stamp and body types are validated on intake' {
    It 'chains a line the writer produced' {
        $spool = Join-Path $TestDrive "spool-$([guid]::NewGuid())"
        Add-LedgerEntry -Spool $spool -Kind 'k' -Body @{ a = 1 } | Out-Null
        $line = Get-Content -LiteralPath (Join-Path $spool 'pending.jsonl')
        & $module { param($l) Test-PendingLine -Line $l } $line | Should -BeNullOrEmpty
    }

    It 'rejects stamp <stamp>' -ForEach @(
        @{ stamp = '5'; json = '5' }
        @{ stamp = 'null'; json = 'null' }
        @{ stamp = 'empty'; json = '""' }
        @{ stamp = 'no fraction'; json = '"2026-10-09T02:50:43Z"' }
        @{ stamp = '3 fraction digits'; json = '"2026-10-09T02:50:43.797Z"' }
        @{ stamp = 'an offset, not Z'; json = '"2026-10-09T02:50:43.7976027+00:00"' }
        @{ stamp = 'month 13'; json = '"2026-13-09T02:50:43.7976027Z"' }
        @{ stamp = 'free text'; json = '"yesterday"' }
    ) {
        $line = '{"stamp":' + $json + ',"kind":"k","body":{},"seq":1}'
        & $module { param($l) Test-PendingLine -Line $l } $line |
            Should -Be 'stamp is not a UTC yyyy-MM-ddTHH:mm:ss.fffffffZ string'
    }

    It 'rejects body <name>' -ForEach @(
        @{ name = 'string'; json = '"s"' }
        @{ name = 'array'; json = '[1]' }
        @{ name = 'number'; json = '1' }
        @{ name = 'null'; json = 'null' }
    ) {
        $line = '{"stamp":"' + $okStamp + '","kind":"k","body":' + $json + ',"seq":1}'
        & $module { param($l) Test-PendingLine -Line $l } $line | Should -Be 'body is not a JSON object'
    }

    It 'the keeper turns the 0.2.3 example {"stamp":5,"kind":"x","body":"s","seq":1} into ledger.rejected' {
        $dir = Join-Path $TestDrive "ledger-$([guid]::NewGuid())"
        $spool = Join-Path $TestDrive "spool-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $spool | Out-Null
        Set-Content -LiteralPath (Join-Path $spool 'pending.jsonl') -Value "{`"stamp`":5,`"kind`":`"x`",`"body`":`"s`",`"seq`":1}`n" -NoNewline
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 1
        $e = @(Get-Ledger -Path $dir)
        $e.kind | Should -Be 'ledger.rejected'
        $e.body.reason | Should -Be 'stamp is not a UTC yyyy-MM-ddTHH:mm:ss.fffffffZ string'
    }
}

Describe 'Finding 1: the payload is everything before the prev/mac suffix at the end of the line' {
    It 'verifies a line whose body has a member named prev' {
        $dir = Join-Path $TestDrive "ledger-$([guid]::NewGuid())"
        $spool = Join-Path $TestDrive "spool-$([guid]::NewGuid())"
        Add-LedgerEntry -Spool $spool -Kind 'k' -Body @{ prev = 'x' } | Out-Null
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $dir 'ledger.jsonl')) | Should -Match '"body":\{"prev":"x"\}'
        Test-Ledger -Path $dir | Should -BeTrue
    }

    It 'the README describes the anchored suffix, not a split at the first ,"prev":' {
        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../README.md') -Raw
        $readme | Should -Not -Match 'up to \(not including\)'
        $readme | Should -Match ([regex]::Escape('`,"prev":"<64 hex>","mac":"<64 hex>"}`'))
        $readme | Should -Match 'end of the line'
    }
}
