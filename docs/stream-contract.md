# Ledger stream contract

The exact shape of `ledger.jsonl` as the keeper (`Start-LedgerKeeper`) writes it, for anything that reads the
stream: `Test-Ledger`, Claude.Agent's Smoke and Alerts tasks, Claude.Agent.Alerts, Claude.Agent.Runner.
Each statement below was checked against the code at 0.2.3 (the writer and keeper are unchanged since 0.2.1);
the source is named in brackets. Where this repo's other docs say something different, the code wins and the
difference is listed under [Findings](#findings).

`tests/fixtures/policy-smoke.ledger.jsonl` is a real stream (see [Fixture](#fixture)) and
`tests/StreamContract.Tests.ps1` checks it against this document.

## File

- One file, `<ledger>/ledger.jsonl`, created empty by `New-Ledger` next to a 32-byte `key.bin` (`0600` on Linux). [New-Ledger.ps1]
- UTF-8 without BOM. Every line ends in `\n` (LF). Lines are split on LF only; a `\r` is part of the line. [Write-LedgerLines, Read-LedgerLines]
- Append-only. The keeper writes under an exclusive lock and never rewrites or truncates the ledger. [Invoke-LedgerFlush, Write-LedgerLines]
- If the file does not end in LF (a torn write), the keeper starts its next append with an LF. That partial line stays in the file and `Test-Ledger` reports it `malformed`. [Write-LedgerLines]

## Line shape

Every line is one JSON object whose members appear in exactly this order:

| # | Member | JSON type | Required | Set by | Notes |
|---|---|---|---|---|---|
| 1 | `stamp` | string | yes | writer (keeper for `ledger.rejected`) | `yyyy-MM-ddTHH:mm:ss.fffffffZ`: UTC, 7 fractional digits, `Z`. [New-LedgerPayload] |
| 2 | `kind` | string | yes | writer (keeper for `ledger.rejected`) | Non-empty. Dotted by convention; the keeper does not check the format. [Test-PendingLine] |
| 3 | `body` | object | yes | writer | Any JSON object, `{}` when empty. Member order is **not meaningful** (see below). |
| 4 | `seq` | integer | writer lines only | writer | Absent on `ledger.rejected` and on 0.1.0 lines. [New-LedgerPayload, Invoke-LedgerFlush] |
| 5 | `prev` | string, 64 lowercase hex | yes | keeper | SHA-256 of the previous line. |
| 6 | `mac` | string, 64 lowercase hex | yes | keeper | HMAC-SHA256 with `key.bin`. |

```json
{"stamp":"2026-10-09T02:50:56.0568733Z","kind":"agent.stop","body":{},"seq":54,"prev":"faef2496…","mac":"bc3479d1…"}
```

### Payload

The **payload** is members 1 to 4 (or 1 to 3): the exact text the writer spooled. Members 5 and 6 are the keeper's
suffix. A line is therefore `payload` with its closing `}` replaced by
`,"prev":"<64 hex>","mac":"<64 hex>"}`. [Write-LedgerLines]

To recover the payload, match the suffix **anchored at the end of the line**:
`^(?<payload>\{.*),"prev":"(?<prev>[0-9a-f]{64})","mac":"(?<mac>[0-9a-f]{64})"\}$`, then payload = group + `}`.
A line that does not match is `malformed`. Do not split at the first `,"prev":` (Finding 1). [Split-LedgerLine]

### Serialisation

- Writer payloads are `ConvertTo-Json -Compress -Depth 32` of an ordered `{stamp, kind, body, seq}`, so there is
  no whitespace between tokens. [New-LedgerPayload]
- `body` comes from a `[hashtable]` parameter. Its member order is hashtable order. That order differs between
  lines with the same members, and passing `[ordered]` does not preserve it. Read `body` by member name only. [Add-LedgerEntry]
- The bytes are not canonical JSON. Never re-serialise a parsed line to check `prev` or `mac`: hash the line's
  exact text. [Test-Ledger; CLAUDE.md]
- Readers using `ConvertFrom-Json` get `stamp` as a `[DateTime]` by default, converted to the reader's local
  time. Use `-DateKind String`, or read the raw text, when the exact stamp matters.

## Hash chain

For line *n* (1-based), with *text(n)* = the line's exact UTF-8 text without its LF:

- `prev(1)` = 64 zeros. `prev(n)` = lowercase hex SHA-256 of *text(n−1)*. [Write-LedgerLines, Test-Ledger]
- `mac(n)` = lowercase hex HMAC-SHA256(`key.bin`, UTF-8 of `prev(n)` + `payload(n)`), where `prev(n)` is the
  64-character hex string itself. [Write-LedgerLines, Get-HmacHex]
- `Test-Ledger` compares `mac` in fixed time. Each line gets zero or more of these reasons: `malformed` (no
  suffix match, no other checks), `prev mismatch`, `mac mismatch`, `seq-gap`. The next line's expected `prev` is
  always the hash of this line's text, good or bad. [Test-Ledger]
- `prev` verifies with the stream alone. `mac` needs `key.bin`, which only the keeper and whoever copies the
  ledger volume hold.

## seq

- The writer owns it. It is kept in `<spool>/seq`, advanced under the `pending.jsonl` lock **before** the line
  is written, and carried in the payload bytes. The keeper never renumbers it. [Add-LedgerEntry]
- Across the lines that carry `seq`, it runs 1, 2, 3, … over the whole ledger, not per run. A line whose `seq` is
  not the previous `seq` + 1 (or 1, for the first) is `seq-gap`. Checking resumes from that line's value. Lines
  without `seq` are skipped by this check. [Test-Ledger]
- The keeper accepts any JSON integer for `seq` (including 0 and negatives); `1.0` or a string is rejected.
  [Test-PendingLine]
- On start, the keeper raises `<spool>/seq` to the highest `seq` in the ledger or the spool, and never lowers it. [Sync-SpoolSeq]

## What the keeper chains, and `ledger.rejected`

The keeper chains a pending line as-is only if all of these hold. [Test-PendingLine]

1. It starts with `{` and ends with `}` (so a CRLF-terminated line fails).
2. It parses as a JSON object.
3. Its members are exactly `stamp,kind,body,seq` in that order, compared case-sensitively.
4. `kind` is a non-empty string.
5. `seq` is an integer.

Nothing else is checked: `stamp` may be any type or format, and `body` any JSON value (Finding 4).

Any other non-empty pending line becomes a keeper-written entry instead. [Invoke-LedgerFlush]

```json
{"stamp":"<keeper's clock>","kind":"ledger.rejected","body":{"reason":"<why>","line":"<raw pending text>"},"prev":"…","mac":"…"}
```

- It has no `seq`, so a rejected line that carried one shows up as a `seq-gap` at the next writer line.
- `reason` is one of: `not a JSON object`; `not valid JSON: <parser message>`;
  `members are '<got>', expected 'stamp,kind,body,seq'`; `kind is not a non-empty string`; `seq is not an integer`.
- Empty pending lines are dropped silently. A trailing pending line with no LF yet is left for the next flush.

Before chaining, a flush skips a pending line whose exact text equals the payload of one of the last *N* ledger
lines, where *N* is the number of pending lines. This avoids double-chaining after a crash between the append
and the spool truncation. [Invoke-LedgerFlush]

## What the keeper does not write

- Nothing for its own start, its flushes or SIGTERM: those go to stdout (`Write-Host`) only. The only kind the
  keeper itself writes is `ledger.rejected`. [Start-LedgerKeeper]
- No run marker. Runs are delimited by the writer's kinds, below.

## Run start and stop (Claude.Agent `entrypoint.ps1`)

One container run writes, in order:

| kind | body members | when |
|---|---|---|
| `agent.egress-check` | `directBlocked` (bool), `curlExit` (int), `detail` (string) | Always first. |
| `agent.start` | `claudeVersion`, `hostname`, `user`, `mode` (`run`/`probe`), `auth` (`oauth`/`apikey`/null), `policySha256` | Only if `directBlocked` is true. |
| `policy.*` | see below | Zero or more, during `claude -p`. |
| `agent.run` | `auth`, `exitCode` (int), `output` (string), `smokeFile`, `smokeExists` (bool) | `mode` = `run` (a credential is present). |
| `agent.probe` | `url`, `status` (string), `curlExit` (int) | `mode` = `probe` (no credential). |
| `agent.stop` | `{}` | Last, on a normal exit. |

- **Start of a run** = an `agent.egress-check` line. Claude.Agent's Smoke and Alerts tasks find the last run this way.
- **Stop of a run** = `agent.stop`. A run can end without one:
  - an `agent.egress-check` with `directBlocked: false` is followed by nothing (exit 3);
  - any thrown error ends the script early, because it runs with `$ErrorActionPreference = 'Stop'`.
  - A refusal because both credentials are set (exit 2) writes nothing at all.
- `auth` records which credential type was present. No credential value is ever in the stream.

## Policy decisions (Claude.Agent.Policy `hooks/`)

Each tool call `claude` makes produces up to two lines. The kind is `policy.<effect>`, where effect is `allow`,
`deny` or `witness` (`policy.schema.json`).

| member | pre hook (`phase: "pre"`) | post hook (`phase: "post"`) |
|---|---|---|
| `phase` | `"pre"` | `"post"` |
| `tool` | Claude Code tool name (`Read`, `Write`, `Bash`, …) | same |
| `kindAction` | `Kind.action`, e.g. `File.delete`, or `null` when the tool maps to none | same |
| `path` | the target path, or `null` | same |
| `rule` | `rules[<n>]` (index into `policy.json` `rules`) or `default` | same |
| `reason` | human-readable decision, e.g. `File.delete /work/policy-smoke.txt denied by policy rules[2]` | **absent** |
| `command` | the Bash command; present only for `Bash` | same |

A **denial** is one `policy.deny` line with `phase: "pre"`. The hook then exits 2, Claude Code blocks the call, and
**no `post` line follows**. An allowed or witnessed call that ran has a `pre` and a `post` line with the same
effect and `rule`.

From the policy-smoke fixture:

```json
{"stamp":"2026-10-09T02:50:53.6154994Z","kind":"policy.deny","body":{"reason":"File.delete /work/policy-smoke.txt denied by policy rules[2]","rule":"rules[2]","path":"/work/policy-smoke.txt","command":"rm /work/policy-smoke.txt","phase":"pre","tool":"Bash","kindAction":"File.delete"},"seq":52,"prev":"…","mac":"…"}
```

Two cases leave a mark that is not a `policy.deny` line:

- If the pre hook itself fails (no policy, bad payload, the spool write throws), it still denies with exit 2, but
  writes **no line**. A blocked call can be missing from the stream (Finding 5).
- A `policy.deny` with `phase: "post"` means a call ran that the policy refuses. Nothing should produce one.

## Fixture

`tests/fixtures/policy-smoke.ledger.jsonl` contains lines 46 to 54 of `C:\__Code\Claude.Agent\artifacts\ledger\ledger.jsonl`,
copied byte for byte (3477 bytes, SHA-256 `8a6a6941ffdd7fecbde72daca03a2d9d69b9e814fc01b427afff876a91130e5a`).
Claude.Agent's Smoke task copied that ledger out after the run and `Test-Ledger` passed on it
(`smoke-report.json` `ledger.valid: true`). Those lines are the last run (hostname `ed543aff0ee7`): read
`/etc/hostname`, write `/work/policy-smoke.txt`, delete denied by `rules[2]`. Nothing was redacted: no token
appears; `"auth":"oauth"` is only the credential type.

Because the fixture is a slice, its first `prev` is not genesis. It is the SHA-256 of ledger line 45,
`00a198bc39ddaa86daafd334bdf24865c84cf9c840412281446c7ab730ec405f`, and the tests anchor on it.
Smoke deletes `key.bin` after verifying, so `mac` cannot be rechecked here. The tests check the `prev` chain and
the `mac` format only.

## Findings

Places where the code and this repo's other docs (README, design.md, function help) disagree. The code is
described above; the doc wording is left unchanged in 0.2.3.

1. **Payload boundary.** The README says the payload is the text "up to (not including) `,"prev":`, plus a
   closing `}`". The code takes the `,"prev":"<64 hex>","mac":"<64 hex>"}` suffix anchored at the end of the line.
   These differ when `body` contains a member named `prev`, e.g. `{"a":1,"prev":"x"}`. A reader that splits at
   the first `,"prev":` then gets the wrong payload and a false `mac mismatch`.
2. **Rejected lines are not idempotent across a crash.** The README and the `Start-LedgerKeeper` help say lines
   already chained are recognised and skipped on the next flush. That holds only for lines chained as-is. A
   rejected line's ledger payload is its `ledger.rejected` wrapper, not its raw text. If the keeper dies after
   chaining but before truncating, the next flush rejects the line again and writes a second `ledger.rejected`.
   Reproduced in a scratch run against 0.2.2.
3. **`stamp` is not always the writer's.** The README says `stamp` is "set by the writer". On `ledger.rejected`,
   the keeper sets it from its own clock at flush time.
4. **"Exactly a {stamp, kind, body, seq} object" is looser than it reads.** The keeper checks member names and
   order, that `kind` is a non-empty string, and that `seq` is an integer. It does not check that `stamp` is a
   UTC string or that `body` is an object: `{"stamp":5,"kind":"x","body":"s","seq":1}` is chained as-is.
5. **Not every denial is ledgered.** Claude.Agent's `entrypoint.ps1` header says every tool call passes the
   PreToolUse hook, "which spools policy.allow / policy.deny / policy.witness". When the hook fails it denies
   (exit 2) without spooling. This is Claude.Agent's and Policy's wording, recorded here, not changed.
