BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Claude.Agent.Ledger/Claude.Agent.Ledger.psd1') -Force
}

Describe 'Claude.Agent.Ledger' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'ledger'
        $file = Join-Path $dir 'ledger.jsonl'
        $spool = Join-Path $TestDrive 'spool'
        $pending = Join-Path $spool 'pending.jsonl'
    }

    It 'New-Ledger creates ledger.jsonl and a 32-byte key.bin' {
        New-Ledger -Path $dir | Out-Null
        $file | Should -Exist
        (Get-Item (Join-Path $dir 'key.bin')).Length | Should -Be 32
    }

    It 'New-Ledger does not replace an existing key' {
        $before = [System.IO.File]::ReadAllBytes((Join-Path $dir 'key.bin'))
        New-Ledger -Path $dir | Out-Null
        [System.IO.File]::ReadAllBytes((Join-Path $dir 'key.bin')) | Should -Be $before
    }

    It 'the writer appends unsigned lines to a spool with no key present' {
        1..3 | ForEach-Object { Add-LedgerEntry -Spool $spool -Kind "test.$_" -Body @{ n = $_ } | Out-Null }
        @(Get-ChildItem -Path $spool -Recurse -Filter 'key.bin') | Should -HaveCount 0
        $lines = @(Get-Content -LiteralPath $pending)
        $lines | Should -HaveCount 3
        $entries = $lines | ConvertFrom-Json
        $entries.kind | Should -Be @('test.1', 'test.2', 'test.3')
        $entries.seq | Should -Be @(1, 2, 3)
        $entries[0].PSObject.Properties.Name | Should -Be @('stamp', 'kind', 'body', 'seq')
    }

    It 'the writer throws when given a -Ledger path' {
        { Add-LedgerEntry -Ledger $dir -Kind 'wired.wrong' } | Should -Throw -ExpectedMessage '*spool only*'
        { Add-LedgerEntry -Spool $dir -Kind 'wired.wrong' } | Should -Throw -ExpectedMessage '*ledger directory, not a spool*'
        (Get-Item $file).Length | Should -Be 0
    }

    It 'the keeper moves the spool into a valid chain and empties the spool' {
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 3
        (Get-Item $pending).Length | Should -Be 0
        $entries = @(Get-Ledger -Path $dir)
        $entries.Count | Should -Be 3
        $entries.kind | Should -Be @('test.1', 'test.2', 'test.3')
        $entries.body.n | Should -Be @(1, 2, 3)
        $entries.seq | Should -Be @(1, 2, 3)
        $entries[0].prev | Should -Be ('0' * 64)
        $entries[0].stamp | Should -Not -BeNullOrEmpty
        Test-Ledger -Path $dir | Should -BeTrue
    }

    It 'Test-Ledger names line 2 and line 3 after one byte of line 2 changes' {
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $line2Start = $text.IndexOf("`n") + 1
        $target = $text.IndexOf('"n":2', $line2Start) + 4
        $target | Should -BeGreaterThan $line2Start
        $bytes[$target] = [byte][char]'7'
        [System.IO.File]::WriteAllBytes($file, $bytes)

        { Test-Ledger -Path $dir } | Should -Throw -ExpectedMessage '*at line 2 (mac mismatch)*line 3 (prev mismatch)*'
    }
}

Describe 'Test-Ledger seq continuity' {
    BeforeEach {
        $dir = Join-Path $TestDrive "ledger-$([guid]::NewGuid())"
        $spool = Join-Path $TestDrive "spool-$([guid]::NewGuid())"
        $pending = Join-Path $spool 'pending.jsonl'
        $file = Join-Path $dir 'ledger.jsonl'
    }

    It 'reports seq-gap when a spooled line is dropped before the keeper chains it (chain otherwise valid)' {
        1..3 | ForEach-Object { Add-LedgerEntry -Spool $spool -Kind "test.$_" | Out-Null }
        $lines = @(Get-Content -LiteralPath $pending)
        [System.IO.File]::WriteAllText($pending, (($lines[0], $lines[2]) -join "`n") + "`n")
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 2

        @((Get-Ledger -Path $dir).seq) | Should -Be @(1, 3)
        { Test-Ledger -Path $dir } | Should -Throw -ExpectedMessage '*at line 2 (seq-gap)'
    }

    It 'reports seq-gap alongside prev mismatch when a middle line is removed from the ledger' {
        1..3 | ForEach-Object { Add-LedgerEntry -Spool $spool -Kind "test.$_" | Out-Null }
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 3
        $lines = @(Get-Content -LiteralPath $file)
        [System.IO.File]::WriteAllText($file, (($lines[0], $lines[2]) -join "`n") + "`n")

        { Test-Ledger -Path $dir } | Should -Throw -ExpectedMessage '*at line 2 (prev mismatch, seq-gap)'
    }

    It 'reports seq-gap for a repeat (spool counter reset without a keeper restart)' {
        1..2 | ForEach-Object { Add-LedgerEntry -Spool $spool -Kind "test.$_" | Out-Null }
        Remove-Item -LiteralPath (Join-Path $spool 'seq')
        Add-LedgerEntry -Spool $spool -Kind 'test.again' | Out-Null
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 3

        @((Get-Ledger -Path $dir).seq) | Should -Be @(1, 2, 1)
        { Test-Ledger -Path $dir } | Should -Throw -ExpectedMessage '*at line 3 (seq-gap)'
    }

    It 'does not count lines without seq (ledger.rejected)' {
        Add-LedgerEntry -Spool $spool -Kind 'test.1' | Out-Null
        Add-Content -LiteralPath $pending -Value 'not json'
        Add-LedgerEntry -Spool $spool -Kind 'test.2' | Out-Null
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 3

        @((Get-Ledger -Path $dir).kind) | Should -Be @('test.1', 'ledger.rejected', 'test.2')
        Test-Ledger -Path $dir | Should -BeTrue
    }
}

Describe 'Start-LedgerKeeper edge cases' {
    BeforeEach {
        $dir = Join-Path $TestDrive "ledger-$([guid]::NewGuid())"
        $spool = Join-Path $TestDrive "spool-$([guid]::NewGuid())"
        $pending = Join-Path $spool 'pending.jsonl'
    }

    It 'does not chain a line twice if the spool was not truncated (keeper died mid-flush)' {
        Add-LedgerEntry -Spool $spool -Kind 'once' | Out-Null
        $copy = Get-Content -LiteralPath $pending -Raw
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 1
        Set-Content -LiteralPath $pending -Value $copy -NoNewline
        Add-LedgerEntry -Spool $spool -Kind 'twice' | Out-Null

        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 1
        @(Get-Ledger -Path $dir).kind | Should -Be @('once', 'twice')
        Test-Ledger -Path $dir | Should -BeTrue
    }

    It 'ledgers a malformed or prev/mac-carrying line as ledger.rejected instead of chaining it' {
        New-Item -ItemType Directory -Path $spool | Out-Null
        $forged = '{"stamp":"x","kind":"agent.run","body":{},"seq":1,"prev":"' + ('0' * 64) + '","mac":"' + ('0' * 64) + '"}'
        Set-Content -LiteralPath $pending -Value "not json`n$forged`n" -NoNewline

        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 2
        $entries = @(Get-Ledger -Path $dir)
        $entries.kind | Should -Be @('ledger.rejected', 'ledger.rejected')
        $entries[1].body.line | Should -Be $forged
        Test-Ledger -Path $dir | Should -BeTrue
    }

    It 'resumes seq from the ledger after a restart mid-spool with the spool counter lost, leaving a contiguous ledger' {
        1..3 | ForEach-Object { Add-LedgerEntry -Spool $spool -Kind "before.$_" | Out-Null }
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 3
        $before = @((Get-Ledger -Path $dir).seq)
        $before | Should -Be @(1, 2, 3)

        # Mid-spool: 4 and 5 are chained, then the keeper dies before truncating, and the spool's counter is lost.
        4..5 | ForEach-Object { Add-LedgerEntry -Spool $spool -Kind "mid.$_" | Out-Null }
        $copy = Get-Content -LiteralPath $pending -Raw
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 2
        Set-Content -LiteralPath $pending -Value $copy -NoNewline
        Remove-Item -LiteralPath (Join-Path $spool 'seq')

        # Restart: the already-chained 4 and 5 are skipped, and the counter comes back from the ledger.
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $spool 'seq')).Trim() | Should -Be '5'
        6..7 | ForEach-Object { Add-LedgerEntry -Spool $spool -Kind "after.$_" | Out-Null }
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 2

        $after = @((Get-Ledger -Path $dir).seq)
        $after | Should -Be @(1, 2, 3, 4, 5, 6, 7)
        Test-Ledger -Path $dir | Should -BeTrue
        Write-Host "restart test seq: before $($before[0])..$($before[-1]), after $($after[0])..$($after[-1])"
    }

    It 'never lowers the spool counter (a line lost before the ledger stays a gap)' {
        1..2 | ForEach-Object { Add-LedgerEntry -Spool $spool -Kind "n.$_" | Out-Null }
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 2
        Set-Content -LiteralPath (Join-Path $spool 'seq') -Value "5`n" -NoNewline
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $spool 'seq')).Trim() | Should -Be '5'
    }

    It 'refuses a spool that is the ledger directory' {
        { Start-LedgerKeeper -Spool $dir -Ledger $dir -Once } | Should -Throw -ExpectedMessage '*different directories*'
    }
}

Describe 'names that differ only in case' {
    # An agent.snapshot env holds HTTP_PROXY and http_proxy; 0.2.4 returned PSCustomObjects and threw on it.
    It 'Add-LedgerEntry returns and Get-Ledger reads a body with HTTP_PROXY and http_proxy' {
        $dir = Join-Path $TestDrive 'case-ledger'
        $spool = Join-Path $TestDrive 'case-spool'
        $env = [System.Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::Ordinal)
        $env['HTTP_PROXY'] = 'http://mitm:8080'
        $env['http_proxy'] = 'http://mitm:8080/'
        $line = Add-LedgerEntry -Spool $spool -Kind 'agent.snapshot' -Body @{ env = $env } -ErrorAction Stop
        @($line.body.env.Keys) | Should -Be @('HTTP_PROXY', 'http_proxy')
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 1
        $e = @(Get-Ledger -Path $dir -ErrorAction Stop)
        $e | Should -HaveCount 1
        $e[0].body.env['HTTP_PROXY'] | Should -BeExactly 'http://mitm:8080'
        $e[0].body.env['http_proxy'] | Should -BeExactly 'http://mitm:8080/'
        Test-Ledger -Path $dir | Should -BeTrue
    }
}
