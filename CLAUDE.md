# CLAUDE.md

PowerShell 7.4+ module: hash-chained, HMAC-authenticated JSONL ledger. Two roles: the writer
(`Add-LedgerEntry -Spool`, runs in the agent, never sees `key.bin`) and the keeper (`Start-LedgerKeeper`, runs
in Claude.Agent's `ledger` sidecar, owns the key and the chain). Never give the writer a way to reach the
ledger directory or the key. One of four sibling repos:

- `Claude.Agent` builds the agent and `ledger` images and runs the end-to-end check; it copies `src/Claude.Agent.Ledger` from here.
- `Claude.Agent.Ledger` (this repo).
- `Claude.Agent.Network` is the mitmproxy capture sidecar.
- `Claude.Agent.Policy` is the tool policy and its Claude Code hooks, which spool `policy.*` entries through this
  module's writer side; its `ledger-writer` skill is copied from this README and pinned to this module's version.

All four are expected side by side (e.g. `C:\__Code\`).

## Layout

- `src/Claude.Agent.Ledger/` module. `Public/*.ps1` are exported (list them in the `.psd1` too), `Private/*.ps1` are helpers.
- `tests/` Pester 5+. Run through `tests/Invoke-Tests.ps1`.
- `docs/design.md` numbered decisions. Add an entry when you make a decision someone could reasonably reverse.

## Commands

- `Invoke-Build` runs the Pester task (default).
- Run Pester only as `pwsh -NoProfile -File tests/Invoke-Tests.ps1`.

## Rules

- The line format is a contract: Claude.Agent's ledgers on existing volumes must keep verifying. Changing how
  `prev` or `mac` is computed needs a format version and a design entry.
- The MAC is over exact bytes. Never verify by re-serialising parsed JSON.
- `seq` is the writer's, carried in its exact bytes; the keeper never renumbers. The keeper may only raise the
  spool's counter, never lower it (design 4).
- Keep the module dependency-free; it runs inside a slim container.
