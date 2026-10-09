function Get-AgentSnapshot {
    <#
    .SYNOPSIS
    Writer side: the body of an agent.snapshot entry, what the agent container held and was handed at one point.
    .DESCRIPTION
    Returns a hashtable for Add-LedgerEntry -Kind agent.snapshot -Body. Claude.Agent's entrypoint takes one right
    after agent.egress-check and one right before agent.stop (-At names which), so a run's two snapshots can be
    compared. Members (docs/stream-contract.md, "agent.snapshot"):

      at, env, imageDigest, os, packageManager, packages, executables, mounts, uid, gid, groups, user, tools,
      mcpServers, errors

    env keeps every variable name; a name matching token, secret, key, password or credential shows <redacted>.
    The OS, package, executable, mount and uid parts read Linux sources (/etc/os-release, dpkg-query or apk,
    PATH plus ldd, /proc/self/mounts, /proc/self/status) and are null where those do not exist. A part that fails
    is null and named in errors; the function itself does not throw for one missing part.

    ldd runs as the caller, with a deadline, on the ELF files on PATH. glibc's ldd can run a binary's own loader,
    so this is no safer than executing them; in the agent that buys nothing the agent uid cannot already do
    (design.md 6).
    .PARAMETER ImageDigest
    The image the container runs. A container cannot see its own image digest, so it has to be handed in;
    defaults to $env:CLAUDE_AGENT_IMAGE_DIGEST and is null when that is unset.
    .PARAMETER Tools
    The tool names handed to claude (for example its --allowedTools). Null means none were named, i.e. Claude Code's
    default set for the version in agent.start.
    .PARAMETER McpConfig
    Extra MCP config files handed to claude (--mcp-config), read alongside ~/.claude.json and ./.mcp.json.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('agent.egress-check', 'agent.stop')][string] $At,
        [AllowEmptyString()][string] $ImageDigest = $env:CLAUDE_AGENT_IMAGE_DIGEST,
        [string[]] $Tools,
        [string[]] $McpConfig = @(),
        [string] $ClaudeHome = $HOME,
        [int] $LddTimeoutSeconds = 30
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $part = {
        param([string] $Name, [scriptblock] $Block)
        try { & $Block } catch { $errors.Add("${Name}: $($_.Exception.Message)"); $null }
    }

    $body = @{
        at          = $At
        imageDigest = if ($ImageDigest) { $ImageDigest } else { $null }
        tools       = $null
        mcpServers  = $null
    }

    $body.env = & $part 'env' { , (ConvertTo-RedactedEnvironment -Variables ([Environment]::GetEnvironmentVariables())) }

    $body.os = & $part 'os' {
        if (Test-Path -LiteralPath '/etc/os-release') { , (ConvertFrom-OsRelease -Text ([System.IO.File]::ReadAllText('/etc/os-release'))) }
    }

    $body.packageManager = $null
    $body.packages = & $part 'packages' {
        $text = Invoke-NativeCapture -Command 'dpkg-query' -Arguments '-W', '-f', '${Package}\t${Version}\n'
        if ($null -ne $text) { $body.packageManager = 'dpkg'; return , (ConvertFrom-PackageList -Text $text -Manager dpkg) }
        $text = Invoke-NativeCapture -Command 'apk' -Arguments 'info', '-v'
        if ($null -ne $text) { $body.packageManager = 'apk'; return , (ConvertFrom-PackageList -Text $text -Manager apk) }
    }

    $body.executables = & $part 'executables' {
        if (-not ($IsLinux -or $IsMacOS)) { return }
        $execBits = [System.IO.UnixFileMode]'UserExecute, GroupExecute, OtherExecute'
        $seenDirs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($dir in ($env:PATH -split ':')) {
            if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
            # /bin and /usr/bin are one directory on a merged-/usr system; list it once.
            $real = (Get-Item -LiteralPath $dir).ResolveLinkTarget($true)
            $realDir = if ($real) { $real.FullName } else { (Get-Item -LiteralPath $dir).FullName }
            if (-not $seenDirs.Add($realDir)) { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction Ignore | Sort-Object Name -CaseSensitive)) {
                $link = $f.ResolveLinkTarget($true)
                $target = if ($link) { $link.FullName } else { $f.FullName }
                if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }   # dangling link
                if (-not ([System.IO.File]::GetUnixFileMode($target) -band $execBits)) { continue }
                $entries.Add([ordered]@{
                    path      = $f.FullName
                    target    = if ($link) { $target } else { $null }
                    elf       = Test-ElfFile -File $target
                    libraries = $null
                })
            }
        }
        # One ldd per batch of distinct targets, not one per file.
        $elf = @($entries | Where-Object { $_.elf } | ForEach-Object { if ($_.target) { $_.target } else { $_.path } } | Sort-Object -Unique -CaseSensitive)
        $libs = @{}
        for ($i = 0; $i -lt $elf.Count; $i += 200) {
            $batch = [string[]]$elf[$i..([Math]::Min($i + 199, $elf.Count - 1))]
            $text = Invoke-NativeCapture -Command 'ldd' -Arguments $batch -TimeoutSeconds $LddTimeoutSeconds
            if ($null -eq $text) { $errors.Add("executables: ldd gave no output for $($batch.Count) files (missing or timed out)"); continue }
            $parsed = ConvertFrom-LddOutput -Text $text -Files $batch
            foreach ($k in $parsed.Keys) { $libs[$k] = $parsed[$k] }
        }
        foreach ($e in $entries) {
            if (-not $e.elf) { continue }
            $key = if ($e.target) { $e.target } else { $e.path }
            if ($libs.ContainsKey($key)) { $e.libraries = $libs[$key] }
        }
        , $entries.ToArray()
    }

    $body.mounts = & $part 'mounts' {
        if (Test-Path -LiteralPath '/proc/self/mounts') { , (ConvertFrom-ProcMounts -Text ([System.IO.File]::ReadAllText('/proc/self/mounts'))) }
    }

    $ids = & $part 'uid' {
        if (Test-Path -LiteralPath '/proc/self/status') { ConvertFrom-ProcStatus -Text ([System.IO.File]::ReadAllText('/proc/self/status')) }
    }
    $body.uid = if ($ids) { $ids.uid } else { $null }
    $body.gid = if ($ids) { $ids.gid } else { $null }
    $body.groups = if ($ids) { , [long[]]$ids.groups } else { $null }
    $body.user = [Environment]::UserName

    # What claude is handed: named tools, the permissions and hooks in its user settings, and its MCP servers.
    $body.tools = & $part 'tools' {
        $settingsFile = Join-Path $ClaudeHome '.claude/settings.json'
        $settings = if (Test-Path -LiteralPath $settingsFile) { Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json -AsHashtable } else { $null }
        $hooks = $null
        if ($settings -is [System.Collections.IDictionary] -and $settings['hooks'] -is [System.Collections.IDictionary]) {
            $hooks = [ordered]@{}
            foreach ($hookEvent in ($settings['hooks'].Keys | Sort-Object)) {
                $hooks[$hookEvent] = [string[]]@($settings['hooks'][$hookEvent] | ForEach-Object { @($_['hooks']) } | ForEach-Object { $_['command'] })
            }
        }
        [ordered]@{
            named       = if ($null -ne $Tools) { , [string[]]$Tools } else { $null }
            permissions = if ($settings -is [System.Collections.IDictionary]) { $settings['permissions'] } else { $null }
            hooks       = $hooks
        }
    }

    # Name, where it came from, type and command or url. Never args, env or headers: they are where MCP servers
    # take their tokens. A url keeps scheme, host, port and path only.
    $body.mcpServers = & $part 'mcpServers' {
        $sources = [System.Collections.Generic.List[object]]::new()
        $userFile = Join-Path $ClaudeHome '.claude.json'
        if (Test-Path -LiteralPath $userFile) {
            $user = Get-Content -LiteralPath $userFile -Raw | ConvertFrom-Json -AsHashtable
            if ($user -is [System.Collections.IDictionary]) {
                $sources.Add(@{ source = $userFile; servers = $user['mcpServers'] })
                if ($user['projects'] -is [System.Collections.IDictionary]) {
                    foreach ($proj in ($user['projects'].Keys | Sort-Object)) {
                        $p = $user['projects'][$proj]
                        if ($p -is [System.Collections.IDictionary]) { $sources.Add(@{ source = "$userFile#projects[$proj]"; servers = $p['mcpServers'] }) }
                    }
                }
            }
        }
        foreach ($file in @((Join-Path (Get-Location).ProviderPath '.mcp.json')) + @($McpConfig)) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            $cfg = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
            if ($cfg -is [System.Collections.IDictionary]) { $sources.Add(@{ source = $file; servers = $cfg['mcpServers'] }) }
        }
        $list = foreach ($s in $sources) {
            if ($s.servers -isnot [System.Collections.IDictionary]) { continue }
            foreach ($name in ($s.servers.Keys | Sort-Object)) {
                $def = $s.servers[$name]
                if ($def -isnot [System.Collections.IDictionary]) { continue }
                $url = $null
                if ($def['url'] -is [string] -and [uri]::TryCreate($def['url'], [UriKind]::Absolute, [ref]$url)) {
                    $url = $url.GetComponents([UriComponents]::SchemeAndServer -bor [UriComponents]::Path, [UriFormat]::UriEscaped)
                }
                [ordered]@{
                    name    = [string]$name
                    source  = $s.source
                    type    = if ($def['type']) { [string]$def['type'] } elseif ($def['url']) { 'http' } else { 'stdio' }
                    command = if ($def['command'] -is [string]) { $def['command'] } else { $null }
                    url     = $url
                }
            }
        }
        , @($list)
    }

    $body.errors = [string[]]$errors.ToArray()
    $body
}
