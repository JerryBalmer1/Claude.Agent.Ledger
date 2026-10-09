# agent.snapshot helpers: parsers over text (so they are testable anywhere) and a bounded native-command runner.
# Not exported. Get-AgentSnapshot (Public) does the reading.

# PAT (personal access token) only as a whole name segment, so PATH and PATHEXT are kept.
$script:SecretNamePattern = '(?i)token|secret|key|password|credential|(^|[_.-])pat($|[_.-])'
$script:Redacted          = '<redacted>'
$script:ElfMagic          = [byte[]](0x7F, 0x45, 0x4C, 0x46)

# Environment variables as a name-sorted, case-sensitive map (Linux has FOO and foo as two variables).
# A name containing token, secret, key, password or credential (any case), or with PAT as a whole _-. separated
# segment, keeps its name and shows <redacted> for its value, empty or not.
function ConvertTo-RedactedEnvironment {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary] $Variables)

    $out = [System.Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Variables.Keys) {
        $out[[string]$name] = if ([string]$name -match $script:SecretNamePattern) { $script:Redacted } else { [string]$Variables[$name] }
    }
    , $out
}

# /etc/os-release: KEY=value lines, value optionally in single or double quotes. Comments and blanks skipped.
function ConvertFrom-OsRelease {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $out = [System.Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($line in ($Text -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*(?<k>[A-Za-z_][A-Za-z0-9_]*)=(?<v>.*?)\s*$')
        if (-not $m.Success) { continue }
        $v = $m.Groups['v'].Value
        if ($v.Length -ge 2 -and ($v[0] -eq '"' -or $v[0] -eq "'") -and $v[-1] -eq $v[0]) {
            $v = $v.Substring(1, $v.Length - 2)
            if ($m.Groups['v'].Value[0] -eq '"') { $v = [regex]::Replace($v, '\\(["\\$`])', '$1') }
        }
        $out[$m.Groups['k'].Value] = $v
    }
    , $out
}

# `dpkg-query -W -f '${Package}\t${Version}\n'` or `apk info -v` output, as [{name, version}] sorted by name.
function ConvertFrom-PackageList {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)][ValidateSet('dpkg', 'apk')][string] $Manager
    )

    $list = foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Trim().Length -eq 0) { continue }
        if ($Manager -eq 'dpkg') {
            $name, $version = $line -split "`t", 2
        }
        else {
            # apk: name-version-rRELEASE; the version starts at the last '-' followed by a digit before -r.
            $m = [regex]::Match($line.Trim(), '^(?<n>.+?)-(?<v>\d[^-]*-r\d+)$')
            if (-not $m.Success) { continue }
            $name = $m.Groups['n'].Value; $version = $m.Groups['v'].Value
        }
        [ordered]@{ name = $name.Trim(); version = "$version".Trim() }
    }
    , @($list | Sort-Object { $_.name } -CaseSensitive)
}

# /proc/self/mounts as [{source, target, type, options}], in file order. Octal escapes (\040 for a space) decoded.
function ConvertFrom-ProcMounts {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $decode = { param($s) [regex]::Replace($s, '\\([0-7]{3})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 8) }) }
    $list = foreach ($line in ($Text -split "`n")) {
        $f = $line -split ' '
        if ($f.Count -lt 4) { continue }
        [ordered]@{ source = & $decode $f[0]; target = & $decode $f[1]; type = $f[2]; options = $f[3] }
    }
    , @($list)
}

# /proc/self/status Uid/Gid/Groups lines: effective uid and gid, and the supplementary groups.
function ConvertFrom-ProcStatus {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $out = [ordered]@{ uid = $null; gid = $null; groups = @() }
    foreach ($line in ($Text -split "`n")) {
        $name, $rest = $line -split ':', 2
        if ($null -eq $rest -or $name -notin 'Uid', 'Gid', 'Groups') { continue }
        $ids = @($rest.Trim() -split '\s+' | Where-Object { $_ } | ForEach-Object { [long]$_ })
        switch ($name) {
            'Uid'    { if ($ids.Count -ge 2) { $out.uid = $ids[1] } }
            'Gid'    { if ($ids.Count -ge 2) { $out.gid = $ids[1] } }
            'Groups' { $out.groups = $ids }
        }
    }
    $out
}

# glibc `ldd f1 f2 ...` output: with more than one file, each block starts with "<file>:" and its libraries follow
# indented. Returns @{ <file> = [string[]] libraries } where a library is "name => path", "name => not found" or a
# bare path, with the load address dropped (it changes per run under ASLR). A file ldd calls "not a dynamic
# executable" or "statically linked" gets an empty list.
function ConvertFrom-LddOutput {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)][string[]] $Files
    )

    $out = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $current = if ($Files.Count -eq 1) { $Files[0] } else { $null }
    if ($current) { $out[$current] = [System.Collections.Generic.List[string]]::new() }
    foreach ($line in ($Text -split "`n")) {
        if ($line.Trim().Length -eq 0) { continue }
        if ($Files.Count -gt 1 -and $line -notmatch '^\s' -and $line.EndsWith(':') -and $Files -ccontains $line.Substring(0, $line.Length - 1)) {
            $current = $line.Substring(0, $line.Length - 1)
            $out[$current] = [System.Collections.Generic.List[string]]::new()
            continue
        }
        if (-not $current) { continue }
        $lib = $line.Trim()
        if ($lib -match 'not a dynamic executable|statically linked') { continue }
        $out[$current].Add(($lib -replace '\s*\(0x[0-9a-fA-F]+\)$', ''))
    }
    $result = @{}
    foreach ($k in $out.Keys) { $result[$k] = [string[]]$out[$k].ToArray() }
    $result
}

# True when the file starts with the ELF magic. Unreadable files are not ELF.
function Test-ElfFile {
    param([Parameter(Mandatory)][string] $File)
    try {
        $fs = [System.IO.File]::OpenRead($File)
        try {
            $head = [byte[]]::new(4)
            ($fs.Read($head, 0, 4) -eq 4) -and [System.Linq.Enumerable]::SequenceEqual($head, $script:ElfMagic)
        }
        finally { $fs.Dispose() }
    }
    catch { $false }
}

# Runs a native command with a deadline and returns its stdout, or $null if it is not installed, cannot start or
# runs past the deadline (it is then killed). Exit code is ignored: ldd exits 1 if any one file is not dynamic.
function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string] $Command,
        [string[]] $Arguments = @(),
        [int] $TimeoutSeconds = 20
    )

    $exe = Get-Command -Name $Command -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if (-not $exe) { return $null }
    $psi = [System.Diagnostics.ProcessStartInfo]::new($exe.Source)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return $null }
    try {
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill($true) } catch { }
            return $null
        }
        $stdout.GetAwaiter().GetResult()
    }
    finally { $proc.Dispose() }
}
