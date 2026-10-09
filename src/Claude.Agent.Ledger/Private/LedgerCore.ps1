# Shared helpers for the ledger. Not exported.

$script:LedgerFileName = 'ledger.jsonl'
$script:KeyFileName    = 'key.bin'
$script:GenesisPrev    = '0' * 64
$script:Utf8NoBom      = [System.Text.UTF8Encoding]::new($false)
$script:PendingFileName = 'pending.jsonl'
$script:SeqFileName     = 'seq'
$script:PayloadMembers  = 'stamp', 'kind', 'body', 'seq'

# Opens a file with FileShare.None (an advisory flock on Linux, shared across containers on one volume),
# retrying while another writer or the keeper holds it.
function Open-LockedFile {
    param(
        [Parameter(Mandatory)][string] $File,
        [System.IO.FileMode] $Mode = [System.IO.FileMode]::Open,
        [int] $LockTimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSeconds)
    while ($true) {
        try {
            return [System.IO.File]::Open($File, $Mode, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -gt $deadline) { throw "Timed out waiting for the lock on '$File'." }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Read-StreamText {
    param([Parameter(Mandatory)][System.IO.FileStream] $Stream)

    $Stream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
    $reader = [System.IO.StreamReader]::new($Stream, $script:Utf8NoBom, $false, 4096, $true)
    try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function New-LedgerPayload {
    param(
        [Parameter(Mandatory)][string] $Kind,
        [hashtable] $Body = @{},
        [Nullable[long]] $Seq
    )

    $payload = [ordered]@{
        stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        kind  = $Kind
        body  = $Body
    }
    if ($null -ne $Seq) { $payload.seq = $Seq }
    $payload | ConvertTo-Json -Compress -Depth 32
}

# Returns $null for a pending line the keeper may chain as-is, or the reason it must not.
function Test-PendingLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Line)

    if (-not ($Line.StartsWith('{') -and $Line.EndsWith('}'))) { return 'not a JSON object' }
    try { $obj = $Line | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { return "not valid JSON: $($_.Exception.Message)" }
    if ($obj -isnot [System.Collections.IDictionary]) { return 'not a JSON object' }
    $names = @($obj.Keys)
    if (($names -join ',') -cne ($script:PayloadMembers -join ',')) {
        return "members are '$($names -join ',')', expected '$($script:PayloadMembers -join ',')'"
    }
    if ($obj.kind -isnot [string] -or $obj.kind.Length -eq 0) { return 'kind is not a non-empty string' }
    if ($obj.seq -isnot [long] -and $obj.seq -isnot [int]) { return 'seq is not an integer' }
    $null
}

# The writer's seq in a payload (a pending line, or a ledger line's payload), or $null when it has none.
function Get-PayloadSeq {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Payload)

    try { $obj = $Payload | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { return $null }
    if ($obj -isnot [System.Collections.IDictionary] -or -not $obj.Contains('seq')) { return $null }
    if ($obj.seq -is [long] -or $obj.seq -is [int]) { return [long]$obj.seq }
    $null
}

# Appends payloads to an open, locked ledger stream, each chained to the line before it.
function Write-LedgerLines {
    param(
        [Parameter(Mandatory)][System.IO.FileStream] $Stream,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][string[]] $Payloads
    )

    $existing = Read-StreamText -Stream $Stream
    $trimmed = $existing.TrimEnd("`n")
    $prevLine = if ($trimmed.Length -eq 0) { $null } else { $trimmed.Substring($trimmed.LastIndexOf("`n") + 1) }

    $sb = [System.Text.StringBuilder]::new()
    if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { [void]$sb.Append("`n") }
    $lines = foreach ($payload in $Payloads) {
        $prev = if ($null -eq $prevLine) { $script:GenesisPrev } else { Get-Sha256Hex -Text $prevLine }
        $mac = Get-HmacHex -Key $Key -Text ($prev + $payload)
        $line = $payload.Substring(0, $payload.Length - 1) + ',"prev":"' + $prev + '","mac":"' + $mac + '"}'
        [void]$sb.Append($line).Append("`n")
        $prevLine = $line
        $line
    }

    $bytes = $script:Utf8NoBom.GetBytes($sb.ToString())
    $Stream.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush($true)
    $lines
}

function Set-GroupSharedMode {
    param([Parameter(Mandatory)][string] $File)
    if ($IsLinux -or $IsMacOS) {
        $mode = [System.IO.UnixFileMode]'UserRead, UserWrite, GroupRead, GroupWrite'
        [System.IO.File]::SetUnixFileMode($File, $mode)
    }
}

# Accepts either the ledger directory or the ledger.jsonl file and returns both paths plus the key path.
function Resolve-LedgerPath {
    param([Parameter(Mandatory)][string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if ((Test-Path -LiteralPath $full -PathType Leaf) -or $full.EndsWith('.jsonl')) {
        $dir = Split-Path -Parent $full
        $file = $full
    }
    else {
        $dir = $full
        $file = Join-Path $dir $script:LedgerFileName
    }
    [pscustomobject]@{
        Directory = $dir
        File      = $file
        Key       = Join-Path $dir $script:KeyFileName
    }
}

function Get-LedgerKey {
    param([Parameter(Mandatory)][string] $KeyPath)

    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
        throw "Ledger key not found at '$KeyPath'. Run New-Ledger first."
    }
    $key = [System.IO.File]::ReadAllBytes($KeyPath)
    if ($key.Length -ne 32) { throw "Ledger key at '$KeyPath' is $($key.Length) bytes, expected 32." }
    , $key
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($script:Utf8NoBom.GetBytes($Text))
    ).ToLowerInvariant()
}

function Get-HmacHex {
    param(
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][string] $Text
    )
    [System.Convert]::ToHexString(
        [System.Security.Cryptography.HMACSHA256]::HashData($Key, $script:Utf8NoBom.GetBytes($Text))
    ).ToLowerInvariant()
}

# A line is the payload object {stamp,kind,body} with prev and mac appended as its last two members.
# The MAC covers prev + the exact payload bytes, so verification never depends on re-serialising JSON.
function Split-LedgerLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Line)

    $m = [regex]::Match($Line, '^(?<payload>\{.*),"prev":"(?<prev>[0-9a-f]{64})","mac":"(?<mac>[0-9a-f]{64})"\}$')
    if (-not $m.Success) { return $null }
    [pscustomobject]@{
        Payload = $m.Groups['payload'].Value + '}'
        Prev    = $m.Groups['prev'].Value
        Mac     = $m.Groups['mac'].Value
    }
}

function Read-LedgerLines {
    param([Parameter(Mandatory)][string] $File)

    $text = [System.IO.File]::ReadAllText($File, $script:Utf8NoBom)
    if ($text.Length -eq 0) { return , [string[]]@() }
    $lines = $text -split "`n"
    # A well-formed ledger ends with a newline, which leaves one empty trailing element.
    if ($lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    , [string[]]$lines
}
