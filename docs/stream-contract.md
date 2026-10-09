# Ledger stream contract

The exact shape of `ledger.jsonl` as the keeper (`Start-LedgerKeeper`) writes it, for anything that reads the
stream: `Test-Ledger`, Claude.Agent's Smoke and Alerts tasks, Claude.Agent.Alerts, Claude.Agent.Runner.
Each statement below was checked against the code at 0.2.4; the source is named in brackets. At 0.2.3 this
repo's other docs disagreed with the code in five places, listed under [Findings](#findings) with what 0.2.4
did about each.

`tests/fixtures/policy-smoke.ledger.jsonl` is a real run plus two real snapshots, re-chained (see [Fixture](#fixture)), and
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
| 1 | `stamp` | string | yes | writer (keeper for `ledger.rejected`) | `yyyy-MM-ddTHH:mm:ss.fffffffZ`: UTC, 7 fractional digits, `Z`. Checked on intake. [New-LedgerPayload, Test-PendingLine] |
| 2 | `kind` | string | yes | writer (keeper for `ledger.rejected`) | Non-empty. Dotted by convention; the keeper does not check the format. [Test-PendingLine] |
| 3 | `body` | object | yes | writer | Any JSON object, `{}` when empty; checked on intake. Member order is **not meaningful** (see below). |
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
A line that does not match is `malformed`. Do not split at the first `,"prev":`: a `body` member named `prev`
would end the payload early (Finding 1). [Split-LedgerLine]

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
4. `stamp` is a string in the writer's format, `yyyy-MM-ddTHH:mm:ss.fffffffZ`, naming a real date (since 0.2.4).
5. `kind` is a non-empty string.
6. `body` is a JSON object (since 0.2.4).
7. `seq` is an integer.

Nothing else is checked: not what `body` holds, not the format of `kind`, not whether `seq` is the next one.

Any other non-empty pending line becomes a keeper-written entry instead. [Invoke-LedgerFlush]

```json
{"stamp":"<keeper's clock>","kind":"ledger.rejected","body":{"reason":"<why>","line":"<raw pending text>"},"prev":"…","mac":"…"}
```

- It has no `seq`, so a rejected line that carried one shows up as a `seq-gap` at the next writer line.
- `reason` is the first of these that applies: `not a JSON object`; `not valid JSON: <parser message>`;
  `members are '<got>', expected 'stamp,kind,body,seq'`; `stamp is not a UTC yyyy-MM-ddTHH:mm:ss.fffffffZ string`;
  `kind is not a non-empty string`; `body is not a JSON object`; `seq is not an integer`.
- Its `stamp` is the keeper's clock at flush time, not the writer's (Finding 3).
- Empty pending lines are dropped silently. A trailing pending line with no LF yet is left for the next flush.

Before chaining, a flush looks at the last *N* ledger lines, where *N* is the number of pending lines, so that a
crash between the append and the spool truncation does not ledger a line twice. [Invoke-LedgerFlush]

- A pending line whose exact text equals one of those payloads was chained as-is, and is skipped.
- A pending line the keeper would reject is skipped if its exact text equals the `body.line` of one of those
  `ledger.rejected` entries **and** it starts with a `stamp` string member. The stamp makes it the same line: a
  writer line's text is unique to 100 ns. A rejected line without a stamp (`not json`) can honestly repeat, so it
  is never skipped. A crash can record it twice but never drops it (design 5, Finding 2).

## What the keeper does not write

- Nothing for its own start, its flushes or SIGTERM: those go to stdout (`Write-Host`) only. The only kind the
  keeper itself writes is `ledger.rejected`. [Start-LedgerKeeper]
- No run marker. Runs are delimited by the writer's kinds, below.

## Run start and stop (Claude.Agent `entrypoint.ps1`)

One container run writes, in order:

| kind | body members | when |
|---|---|---|
| `agent.egress-check` | `directBlocked` (bool), `curlExit` (int), `detail` (string) | Always first. |
| `agent.snapshot` | see [agent.snapshot](#agentsnapshot), `at`: `agent.egress-check` | Right after `agent.egress-check`, whatever `directBlocked` says. |
| `agent.start` | `claudeVersion`, `hostname`, `user`, `mode` (`run`/`probe`), `auth` (`oauth`/`apikey`/null), `policySha256` | Only if `directBlocked` is true. |
| `policy.*` | see below | Zero or more, during `claude -p`. |
| `agent.run` | `auth`, `exitCode` (int), `output` (string), `smokeFile`, `smokeExists` (bool) | `mode` = `run` (a credential is present). |
| `agent.probe` | `url`, `status` (string), `curlExit` (int) | `mode` = `probe` (no credential). |
| `agent.snapshot` | `at`: `agent.stop` | Right before `agent.stop`. |
| `agent.stop` | `{}` | Last, on a normal exit. |

The two `agent.snapshot` rows are the contract from 0.2.4 on. Claude.Agent's `entrypoint.ps1` does not emit them
yet; until it does, runs have neither.

- **Start of a run** = an `agent.egress-check` line. Claude.Agent's Smoke and Alerts tasks find the last run this way.
- **Stop of a run** = `agent.stop`. A run can end without one:
  - an `agent.egress-check` with `directBlocked: false` is followed by nothing (exit 3);
  - any thrown error ends the script early, because it runs with `$ErrorActionPreference = 'Stop'`.
  - A refusal because both credentials are set (exit 2) writes nothing at all.
- `auth` records which credential type was present. No credential value is ever in the stream.

## agent.snapshot

What the agent container held and was handed, taken twice per run so the two can be compared: what changed
between them changed during the run. The body is `Get-AgentSnapshot -At <point>`, spooled with
`Add-LedgerEntry -Kind agent.snapshot`. [Get-AgentSnapshot]

| member | JSON type | content |
|---|---|---|
| `at` | string | `agent.egress-check` or `agent.stop`: the entry this snapshot goes with. |
| `env` | object | Every environment variable, name to value. A name containing `token`, `secret`, `key`, `password` or `credential` (any case), or with `PAT` as a whole `_`/`-`/`.`-separated segment (`AZDO_PAT`, not `PATH`), has the value `"<redacted>"`, empty or not. Names are case-sensitive, sorted ordinally. |
| `imageDigest` | string or null | The image the container runs, as handed in (`-ImageDigest`, default `$env:CLAUDE_AGENT_IMAGE_DIGEST`). A container cannot read its own digest, so it is null unless the runner passes it. |
| `os` | object or null | `/etc/os-release`, key to unquoted value (`ID`, `VERSION_ID`, `PRETTY_NAME`, ...). |
| `packageManager` | string or null | `dpkg` or `apk`, whichever answered. |
| `packages` | array or null | `[{name, version}]`, sorted by name. |
| `executables` | array or null | Every executable regular file in each `PATH` directory, a directory reached twice (`/bin` -> `/usr/bin`) listed once: `[{path, target, elf, libraries}]`. `target` is the resolved symlink target or null. `libraries` is null for a non-ELF file (a script), `[]` for a static one, else ldd's lines without load addresses: `name => path`, `name => not found`, or a bare path. |
| `mounts` | array or null | `/proc/self/mounts` in order: `[{source, target, type, options}]`. |
| `uid`, `gid` | integer or null | Effective ids from `/proc/self/status`. |
| `groups` | array of integer or null | Supplementary groups. |
| `user` | string | User name. |
| `tools` | object | `named`: tool names handed to `claude` (`-Tools`), or null for its default set; `permissions`: `permissions` from `~/.claude/settings.json`, or null; `hooks`: event to hook commands from that file, or null. |
| `mcpServers` | array | `[{name, source, type, command, url}]` from `~/.claude.json` (top level and per project), `./.mcp.json` and any `-McpConfig` file. Never `args`, `env` or `headers`, where servers take their tokens; `url` keeps scheme, host, port and path only. |
| `errors` | array of string | `"<part>: <message>"` for each part that failed and was left null. Empty normally. |

- Null means not available here (not Linux, no `/etc/os-release`, no package manager), or failed and named in `errors`.
- Only names are redacted. A value under an innocent name (a token in `HTTPS_PROXY`'s userinfo, say) is kept.
- A snapshot line is large: about 105 KB in Claude.Agent's image (408 executables, 109 packages).
- ldd runs as the agent, with a deadline. A planted binary can run code under ldd at `agent.stop`; it gets
  nothing the agent uid does not already have (design 6).

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

- A `policy.deny` with `phase: "post"` means a call ran that the policy refuses. Nothing should produce one.

### Hook failure

If the pre hook itself fails (no policy, an unreadable payload, Claude.Agent.Policy failing to load or to
decide), it still denies with exit 2.
From 0.2.4 the contract is that it first spools one `policy.deny` line with `reason: "hook-failure"`, so a denial
is never missing from the stream:

| member | value |
|---|---|
| `phase` | `"pre"` |
| `tool` | `tool_name` from the hook payload if it was read, else null |
| `kindAction`, `path`, `rule` | null: no decision was made |
| `reason` | `"hook-failure"`, exactly. Readers tell a failure from a policy denial by this value. |
| `error` | the exception message |

```json
{"stamp":"2026-10-09T02:50:53.6154994Z","kind":"policy.deny","body":{"reason":"hook-failure","rule":null,"path":null,"error":"Cannot find path '/opt/agent/policy/policy.json' because it does not exist.","phase":"pre","tool":"Bash","kindAction":null},"seq":52}
```

The hook writes that line inside its failure handler, and denies with exit 2 whether the write succeeds or not.
What still leaves no line: the spool write itself failing (unwritable or locked spool), or the Ledger module
failing to load. Then the only traces are the hook's stderr and, if the writer had already taken a `seq`, a
`seq-gap` at the next line.

Claude.Agent.Policy's `hooks/pre-tool-use.ps1` does not write this line yet. Until it does, a failed hook
denies without a line (Finding 5).

## Fixture

`tests/fixtures/policy-smoke.ledger.jsonl` (11 lines, 212896 bytes, SHA-256
`252c40e06d18332d6261c59b380f346fd9824ce13433c7520810079c7005856f`) is one run as it would read with
`agent.snapshot` emitted:

- **Nine real lines.** Lines 46 to 54 of `C:\__Code\Claude.Agent\artifacts\ledger\ledger.jsonl`, the last run
  (hostname `ed543aff0ee7`): read `/etc/hostname`, write `/work/policy-smoke.txt`, delete denied by `rules[2]`.
  Claude.Agent's Smoke task copied that ledger out and `Test-Ledger` passed on it (`smoke-report.json`
  `ledger.valid: true`). 0.2.3 kept those 9 lines byte for byte (3477 bytes, SHA-256
  `8a6a6941ffdd7fecbde72daca03a2d9d69b9e814fc01b427afff876a91130e5a`). Their payloads are unchanged except `seq`.
- **Two snapshot lines**, inserted after `agent.egress-check` and before `agent.stop`, are real `Get-AgentSnapshot`
  output from Claude.Agent's `claude-agent:dev` image (`sha256:51a8cf59…`). They were taken as `agent` (uid 10001)
  with `/spool` and `/ca` volumes mounted and the run's hostname set, and the policy hook fragment was merged in
  between them as the entrypoint does. They come from a separate container started for the purpose, not from
  that run. `CLAUDE_CODE_OAUTH_TOKEN` was set to a placeholder and shows as `<redacted>`. Their stamps are
  midway between their neighbours.
- **Re-chained.** Inserting lines moves `seq` (now 46 to 56) and every later `prev`. The first `prev` is still
  the SHA-256 of ledger line 45, `00a198bc39ddaa86daafd334bdf24865c84cf9c840412281446c7ab730ec405f`, and the tests
  anchor on it. Smoke deleted the run's `key.bin`, so every `mac` is recomputed with a **fixture key of 32 zero
  bytes**, and the tests check each `mac` against that key.

Nothing in the run lines was redacted: no token appears there; `"auth":"oauth"` is only the credential type.

## Findings

Places where the code and this repo's other docs (README, design.md, function help) disagreed at 0.2.3, and what
0.2.4 did about each.

1. **Payload boundary.** The README says the payload is the text "up to (not including) `,"prev":`, plus a
   closing `}`". The code takes the `,"prev":"<64 hex>","mac":"<64 hex>"}` suffix anchored at the end of the line.
   These differ when `body` contains a member named `prev`, e.g. `{"a":1,"prev":"x"}`. A reader that splits at
   the first `,"prev":` then gets the wrong payload and a false `mac mismatch`.
   **0.2.4:** README now describes the anchored suffix. No code change.
2. **Rejected lines are not idempotent across a crash.** The README and the `Start-LedgerKeeper` help say lines
   already chained are recognised and skipped on the next flush. That holds only for lines chained as-is. A
   rejected line's ledger payload is its `ledger.rejected` wrapper, not its raw text. If the keeper dies after
   chaining but before truncating, the next flush rejects the line again and writes a second `ledger.rejected`.
   Reproduced in a scratch run against 0.2.2.
   **0.2.4:** fixed for any rejected line carrying a `stamp` string (see "What the keeper chains"). A stampless
   one can still be recorded twice by a crash, by design (design 5).
3. **`stamp` is not always the writer's.** The README says `stamp` is "set by the writer". On `ledger.rejected`,
   the keeper sets it from its own clock at flush time.
   **0.2.4:** README wording fixed. No code change.
4. **"Exactly a {stamp, kind, body, seq} object" is looser than it reads.** The keeper checks member names and
   order, that `kind` is a non-empty string, and that `seq` is an integer. It does not check that `stamp` is a
   UTC string or that `body` is an object: `{"stamp":5,"kind":"x","body":"s","seq":1}` is chained as-is.
   **0.2.4:** `stamp` and `body` are checked on intake; that line is now `ledger.rejected`.
5. **Not every denial is ledgered.** Claude.Agent's `entrypoint.ps1` header says every tool call passes the
   PreToolUse hook, "which spools policy.allow / policy.deny / policy.witness". When the hook fails it denies
   (exit 2) without spooling.
   **0.2.4:** the `hook-failure` line is now in the contract (see "Hook failure"). It needs a change in
   Claude.Agent.Policy's `hooks/pre-tool-use.ps1`, which is not made here; open until that lands.
