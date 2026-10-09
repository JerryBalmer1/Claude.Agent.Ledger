# agent.snapshot (docs/stream-contract.md): the parsers on canned Linux text, and Get-AgentSnapshot on this host.
BeforeAll {
    $module = Import-Module (Join-Path $PSScriptRoot '../src/Claude.Agent.Ledger/Claude.Agent.Ledger.psd1') -Force -PassThru
    $members = @('at', 'env', 'errors', 'executables', 'gid', 'groups', 'imageDigest', 'mcpServers', 'mounts', 'os',
        'packageManager', 'packages', 'tools', 'uid', 'user')
}

Describe 'env redaction' {
    It '<name> is <expect>' -ForEach @(
        @{ name = 'CLAUDE_CODE_OAUTH_TOKEN'; expect = 'redacted' }
        @{ name = 'ANTHROPIC_API_KEY'; expect = 'redacted' }
        @{ name = 'aws_secret_access_key'; expect = 'redacted' }
        @{ name = 'DB_PASSWORD'; expect = 'redacted' }
        @{ name = 'GIT_CREDENTIAL_HELPER'; expect = 'redacted' }
        @{ name = 'Some_Secret'; expect = 'redacted' }
        @{ name = 'AZDO_PAT'; expect = 'redacted' }
        @{ name = 'GITHUB_PAT_RO'; expect = 'redacted' }
        @{ name = 'pat'; expect = 'redacted' }
        @{ name = 'PATH'; expect = 'kept' }
        @{ name = 'PATHEXT'; expect = 'kept' }
        @{ name = 'XPATH_HOME'; expect = 'kept' }
        @{ name = 'HOME'; expect = 'kept' }
        @{ name = 'NODE_EXTRA_CA_CERTS'; expect = 'kept' }
    ) {
        $out = & $module { param($v) ConvertTo-RedactedEnvironment -Variables $v } @{ $name = 'value-123' }
        $out[$name] | Should -BeExactly ($expect -eq 'redacted' ? '<redacted>' : 'value-123')
    }

    It 'keeps names that differ only in case apart, sorted ordinally, and redacts an empty secret too' {
        $out = & $module { param($v) ConvertTo-RedactedEnvironment -Variables $v } ([System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal) |
            ForEach-Object { $_['b'] = '1'; $_['B'] = '2'; $_['MY_TOKEN'] = ''; , $_ })
        @($out.Keys) | Should -Be @('B', 'MY_TOKEN', 'b')
        $out['MY_TOKEN'] | Should -Be '<redacted>'
    }
}

Describe 'parsers' {
    It 'reads /etc/os-release with quoted and bare values' {
        $text = "PRETTY_NAME=`"Debian GNU/Linux 12 (bookworm)`"`nNAME=`"Debian GNU/Linux`"`nVERSION_ID=`"12`"`nID=debian`n# comment`n`nHOME_URL='https://www.debian.org/'`n"
        $os = & $module { param($t) ConvertFrom-OsRelease -Text $t } $text
        $os['ID'] | Should -Be 'debian'
        $os['VERSION_ID'] | Should -Be '12'
        $os['PRETTY_NAME'] | Should -Be 'Debian GNU/Linux 12 (bookworm)'
        $os['HOME_URL'] | Should -Be 'https://www.debian.org/'
        $os.Count | Should -Be 5
    }

    It 'reads dpkg-query and apk package lists, sorted by name' {
        $dpkg = & $module { param($t) ConvertFrom-PackageList -Text $t -Manager dpkg } "zlib1g`t1:1.2.13.dfsg-1`napt`t2.6.1`n"
        @($dpkg | ForEach-Object { "$($_.name)=$($_.version)" }) | Should -Be @('apt=2.6.1', 'zlib1g=1:1.2.13.dfsg-1')
        $apk = & $module { param($t) ConvertFrom-PackageList -Text $t -Manager apk } "musl-1.2.4-r2`nca-certificates-bundle-20240226-r0`n"
        @($apk | ForEach-Object { "$($_.name)=$($_.version)" }) | Should -Be @('ca-certificates-bundle=20240226-r0', 'musl=1.2.4-r2')
    }

    It 'reads /proc/self/mounts and decodes octal escapes' {
        $text = "overlay / overlay rw,relatime 0 0`n/dev/sda1 /spool ext4 rw,relatime 0 0`n/dev/sda1 /ca ext4 ro,relatime 0 0`n/dev/sda1 /a\040b ext4 rw 0 0`n"
        $m = & $module { param($t) ConvertFrom-ProcMounts -Text $t } $text
        $m | Should -HaveCount 4
        $m[1].target | Should -Be '/spool'
        $m[2].options | Should -Be 'ro,relatime'
        $m[3].target | Should -Be '/a b'
    }

    It 'reads the effective uid, gid and groups from /proc/self/status' {
        $text = "Name:`tpwsh`nUmask:`t0022`nUid:`t10001`t10001`t10001`t10001`nGid:`t10001`t10001`t10001`t10001`nGroups:`t10001 10100 `n"
        $s = & $module { param($t) ConvertFrom-ProcStatus -Text $t } $text
        $s.uid | Should -Be 10001
        $s.gid | Should -Be 10001
        $s.groups | Should -Be @(10001, 10100)
    }

    It 'reads multi-file ldd output without load addresses' {
        $text = @"
/usr/bin/a:
`tlinux-vdso.so.1 (0x00007ffd5a9e5000)
`tlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f1a2b000000)
`tlibgone.so.1 => not found
`t/lib64/ld-linux-x86-64.so.2 (0x00007f1a2b400000)
/usr/bin/b:
`tnot a dynamic executable
"@
        $l = & $module { param($t, $f) ConvertFrom-LddOutput -Text $t -Files $f } $text @('/usr/bin/a', '/usr/bin/b')
        $l['/usr/bin/a'] | Should -Be @('linux-vdso.so.1', 'libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6', 'libgone.so.1 => not found', '/lib64/ld-linux-x86-64.so.2')
        $l['/usr/bin/b'] | Should -HaveCount 0
    }

    It 'reads single-file ldd output (no header line)' {
        $l = & $module { param($t, $f) ConvertFrom-LddOutput -Text $t -Files $f } "`tlibc.so.6 => /lib/libc.so.6 (0x1)`n" @('/x')
        $l['/x'] | Should -Be @('libc.so.6 => /lib/libc.so.6')
    }
}

Describe 'Get-AgentSnapshot on this host' {
    BeforeAll {
        $claudeHome = Join-Path $TestDrive 'home'
        New-Item -ItemType Directory -Path (Join-Path $claudeHome '.claude') -Force | Out-Null
        @{ hooks = @{ PreToolUse = @(@{ matcher = '*'; hooks = @(@{ type = 'command'; command = 'pwsh -File /opt/agent/policy/hooks/pre-tool-use.ps1' }) }) }
           permissions = @{ deny = @('WebFetch') } } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $claudeHome '.claude/settings.json')
        @{ mcpServers = @{
                remote = @{ type = 'http'; url = 'https://user:pw@mcp.example.test:8443/v1/sse?token=abc#x'; headers = @{ Authorization = 'Bearer abc' } }
                local  = @{ command = 'npx'; args = @('-y', 'srv', '--token', 'abc'); env = @{ API_TOKEN = 'abc' } } } } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $claudeHome '.claude.json')
        $work = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $work | Out-Null
        @{ mcpServers = @{ proj = @{ command = '/usr/bin/proj-mcp' } } } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $work '.mcp.json')

        $env:LEDGER_TEST_API_KEY = 'must-not-appear'
        $env:LEDGER_TEST_PLAIN = 'plain-value'
        Push-Location $work
        try { $snap = Get-AgentSnapshot -At agent.stop -ImageDigest 'sha256:abc' -Tools Read, Write -ClaudeHome $claudeHome }
        finally {
            Pop-Location
            Remove-Item Env:LEDGER_TEST_API_KEY, Env:LEDGER_TEST_PLAIN
        }
        $json = $snap | ConvertTo-Json -Compress -Depth 32
    }

    It 'returns a hashtable with exactly the contract members' {
        $snap | Should -BeOfType [hashtable]
        @($snap.Keys | Sort-Object) | Should -Be $members
        $snap.at | Should -Be 'agent.stop'
        $snap.imageDigest | Should -Be 'sha256:abc'
    }

    # Assertions here never print $json or $snap.env: on failure they would put this host's real environment
    # into the test output and artifacts/testResults.xml.
    It 'redacts by variable name and never carries the value' {
        $snap.env['LEDGER_TEST_API_KEY'] | Should -Be '<redacted>'
        $snap.env['LEDGER_TEST_PLAIN'] | Should -Be 'plain-value'
        $json.Contains('must-not-appear') | Should -BeFalse
    }

    It 'records the named tools and the hooks and permissions from the settings' {
        $snap.tools.named | Should -Be @('Read', 'Write')
        $snap.tools.hooks['PreToolUse'] | Should -Be @('pwsh -File /opt/agent/policy/hooks/pre-tool-use.ps1')
        $snap.tools.permissions['deny'] | Should -Be @('WebFetch')
    }

    It 'records MCP servers by name, source, type, command and url only: no args, env, headers, userinfo or query' {
        @($snap.mcpServers | ForEach-Object { "$($_.name) $($_.type) $($_.command) $($_.url)" }) | Should -Be @(
            'local stdio npx ', 'remote http  https://mcp.example.test:8443/v1/sse', 'proj stdio /usr/bin/proj-mcp ')
        $mcpJson = ConvertTo-Json -InputObject $snap.mcpServers -Compress -Depth 8
        $mcpJson | Should -Not -Match 'abc|Bearer|user:pw|--token|API_TOKEN|-y'
    }

    It 'only accepts the two documented points' {
        { Get-AgentSnapshot -At agent.start } | Should -Throw
    }

    It 'leaves the Linux-only parts null off Linux, without errors' -Skip:$IsLinux {
        $snap.os | Should -BeNullOrEmpty
        $snap.executables | Should -BeNullOrEmpty
        $snap.mounts | Should -BeNullOrEmpty
        $snap.uid | Should -BeNullOrEmpty
        $snap.errors | Should -HaveCount 0
    }

    It 'fills the Linux parts on Linux' -Skip:(-not $IsLinux) {
        $snap.os['ID'] | Should -Not -BeNullOrEmpty
        $snap.uid | Should -BeOfType [long]
        @($snap.mounts | Where-Object { $_.target -eq '/' }) | Should -HaveCount 1
        @($snap.executables | Where-Object { $_.elf -and $null -ne $_.libraries }).Count | Should -BeGreaterThan 0
    }

    It 'goes through the writer and the keeper as a chained agent.snapshot line' {
        $spool = Join-Path $TestDrive 'spool'
        $dir = Join-Path $TestDrive 'ledger'
        Add-LedgerEntry -Spool $spool -Kind 'agent.snapshot' -Body $snap | Out-Null
        Start-LedgerKeeper -Spool $spool -Ledger $dir -Once | Should -Be 1
        (Get-Ledger -Path $dir).kind | Should -Be 'agent.snapshot'
        Test-Ledger -Path $dir | Should -BeTrue
    }
}
