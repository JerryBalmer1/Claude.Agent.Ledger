# Claude.Agent.Ledger

A PowerShell module that keeps an append-only, tamper-evident log of what an agent container did.
Each entry is one JSON line. Each line carries the hash of the line before it and an HMAC over its own
content, so editing, reordering or deleting a line breaks the chain and `Test-Ledger` names where.

Requires PowerShell 7.4+. No external dependencies.

## Two roles

The party being recorded must not hold the key that authenticates the record, so the module has two sides
that run in different places and share only a spool directory:

- **Writer** (in the agent): `Add-LedgerEntry -Spool <dir>` appends an unsigned line to `<dir>/pending.jsonl`.
  It never reads `key.bin` and never touches `ledger.jsonl`.
- **Keeper** (in a sidecar the agent cannot reach): `Start-LedgerKeeper -Spool <dir> -Ledger <dir>` owns
  `key.bin`, moves pending lines into the chained `ledger.jsonl` with `prev` and `mac`, and truncates what it consumed.

## Functions

| Function | Side | What it does |
| --- | --- | --- |
| `Add-LedgerEntry -Spool <dir> -Kind <string> -Body <hashtable>` | writer | Appends `{stamp, kind, body, seq}` to `<dir>/pending.jsonl` under an exclusive lock. `seq` (kept in `<dir>/seq`) only grows. Throws if given `-Ledger`, or if `<dir>` holds `key.bin` or `ledger.jsonl`. |
| `Start-LedgerKeeper -Spool <dir> -Ledger <dir> [-IntervalMilliseconds 500] [-Once]` | keeper | Runs `New-Ledger`, raises `<Spool>/seq` to the last seq in the ledger or spool (never lowers it), then flushes the spool into the ledger every interval until SIGTERM, and once more on SIGTERM. `-Once` syncs and flushes once and returns the number of lines moved. |
| `Get-AgentSnapshot -At <agent.egress-check\|agent.stop> [-ImageDigest] [-Tools] [-McpConfig]` | writer | Returns the body of an `agent.snapshot` entry: env (secret-named values `<redacted>`), image digest, `/etc/os-release`, packages, executables on `PATH` with their ldd libraries, mounts, uid/gid/groups, the tools, hooks and MCP servers handed to `claude`. Linux parts are null elsewhere. See [docs/stream-contract.md](docs/stream-contract.md#agentsnapshot). |
| `New-Ledger -Path <dir>` | keeper | Creates `<dir>/ledger.jsonl` and `<dir>/key.bin` (32 random bytes) if absent. Never overwrites. Sets both to `0600` on Linux. |
| `Get-Ledger -Path <dir>` | host | Returns the entries, oldest first. Does not verify. |
| `Test-Ledger -Path <dir>` | host | Walks the chain and the seq numbers. Returns `$true`, or throws naming the first bad line and listing any others, each with its reasons: `prev mismatch`, `mac mismatch`, `seq-gap`, or `malformed`. |

`-Path` may be the directory or the `ledger.jsonl` file inside it; the key is always `key.bin` next to it.

```powershell
Import-Module ./src/Claude.Agent.Ledger
# writer (agent container)
Add-LedgerEntry -Spool /spool -Kind 'agent.start' -Body @{ hostname = 'abc' }
# keeper (ledger container)
Start-LedgerKeeper -Spool /spool -Ledger /ledger
# host, after copying the ledger volume out
Test-Ledger -Path ./ledger
Get-Ledger -Path ./ledger
```

The keeper chains each pending line's exact text as the payload; it never re-serialises what the writer sent.
A line that is not a `{stamp, kind, body, seq}` object in that member order, with `stamp` a UTC string in the
writer's format, `kind` a non-empty string, `body` an object and `seq` an integer, is not chained as-is: the
keeper ledgers a `ledger.rejected` entry holding the raw text and the reason. If the keeper dies after chaining
but before truncating, the next flush recognises those lines and skips them: a line chained as-is by exact match
against the ledger's trailing payloads, a rejected line by exact match against their `body.line`, but only if it
carries a stamp (a stampless one may honestly repeat, so it is recorded again rather than dropped; design 5).

## Chain format

One line per entry, UTF-8, `\n`-terminated:

```json
{"stamp":"2026-10-08T12:00:00.0000000Z","kind":"agent.start","body":{"hostname":"abc"},"seq":1,"prev":"<64 hex>","mac":"<64 hex>"}
```

- `stamp`: UTC, `yyyy-MM-ddTHH:mm:ss.fffffffZ`, set by the writer; on `ledger.rejected`, the keeper's clock at flush time.
- `kind`: free-form dotted name, e.g. `agent.start`.
- `body`: the hashtable passed to `Add-LedgerEntry`, as JSON.
- `seq`: the writer's sequence number. Absent on entries the keeper writes itself (`ledger.rejected`) and on
  lines written by 0.1.0, which still verify: `prev` and `mac` are computed exactly as before. Across the lines
  that carry it, `seq` must run 1, 2, 3, ...; `Test-Ledger` reports any other value as `seq-gap` (design 4).
- `prev`: SHA-256 (hex) of the previous line's exact text without its newline. The first line uses 64 zeros.
- `mac`: HMAC-SHA256 with `key.bin` over `prev` followed by the payload. The payload is the line's exact text
  with the keeper's suffix `,"prev":"<64 hex>","mac":"<64 hex>"}` at the end of the line replaced by a closing `}`.
  Match that suffix anchored at the end of the line, never at the first `,"prev":`: a `body` member named `prev`
  would cut the payload short.

Because the MAC covers the exact bytes written, verification never re-serialises JSON. One edited
line shows up as two failures: that line (`mac mismatch`) and the next (`prev mismatch`). A line removed from
the middle shows as one: the line after it (`prev mismatch, seq-gap`). A spooled line dropped before the keeper
chained it leaves a valid chain and shows as `seq-gap` alone.

## How Claude.Agent bakes it in

`Claude.Agent`'s `Modules` task copies `src/Claude.Agent.Ledger` into its `build/modules/`. Two images get it:

- the **agent** image, whose entrypoint calls `Add-LedgerEntry -Spool /spool` for `agent.egress-check`,
  `agent.start`, `agent.run` or `agent.probe`, and `agent.stop`. It mounts only the `spool` volume.
- the **`ledger` sidecar** (`ledger.Dockerfile`, uid 10002, no network), whose entrypoint is
  `Start-LedgerKeeper -Spool /spool -Ledger /ledger`. It is the only container that mounts the `ledger` volume.

The host waits for the spool to drain, stops the keeper, copies the ledger volume out and runs `Test-Ledger`.

## Development

```powershell
Invoke-Build          # runs Pester via pwsh -NoProfile -File tests/Invoke-Tests.ps1
```

See [docs/design.md](docs/design.md) for the decisions behind this, and [docs/stream-contract.md](docs/stream-contract.md)
for the exact line shape readers can rely on.
