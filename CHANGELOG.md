# Changelog

## 0.2.2 - 2026-10-08

- 0.2.2: git-guard hook; run-report 0.2.2; graph-node 0.2.1
- Skills git-guard 0.1.0, run-report 0.2.2 and graph-node 0.2.1 copied from Graph HEAD; git-guard's PreToolUse hook merged into `.claude/settings.json`. `tests/Skills.Tests.ps1` checks each copy's version and full text against `git show HEAD:` in Graph, and the hook's exit codes (0, 0, 2, 2, 2, 2 for git status, git add, git commit, git push, git tag, gh pr merge).
- `artifacts/` gitignored. No change to the module's code; Policy's and Alerts' `ledger-writer` copies move to 0.2.2.

## 0.2.1 - 2026-10-08

- `Test-Ledger` checks seq continuity: across lines that carry `seq`, it must start at 1 and rise by exactly 1.
  A gap, repeat or decrease marks that line bad with reason `seq-gap`, alongside `prev mismatch` /
  `mac mismatch`, and the ledger fails. Lines without `seq` (`ledger.rejected`, 0.1.0 lines) are not counted.
  Closes the gap noted in design 3: a spooled line deleted before the keeper chained it used to verify.
- `Start-LedgerKeeper`, on start (also with `-Once`), raises `<Spool>/seq` to the highest seq in the ledger or the
  spool, so a lost or reset spool counter continues the ledger's sequence instead of restarting at 1. It never
  lowers the counter.
- Design 4.

## 0.2.0 - 2026-10-08

- Two roles. Writer: `Add-LedgerEntry -Spool <dir>` appends unsigned `{stamp, kind, body, seq}` lines to
  `pending.jsonl` and never reads `key.bin`; it throws if given `-Ledger` or a directory that holds a ledger.
  **Breaking:** `Add-LedgerEntry -Path` is gone.
- Keeper: new `Start-LedgerKeeper -Spool -Ledger [-IntervalMilliseconds] [-Once]` creates the ledger and key,
  chains pending lines (exact bytes, adding `prev` and `mac`), truncates the spool, flushes on an interval and
  on SIGTERM. Malformed lines become `ledger.rejected` entries; lines already chained are not chained twice.
- Ledger lines gain `seq` in the payload. `prev`/`mac` are unchanged, so 0.1.0 ledgers still verify.
- Design 3 rewritten: the agent never holds the key.

## 0.1.0 - 2026-10-08

- `New-Ledger`, `Add-LedgerEntry`, `Get-Ledger`, `Test-Ledger`.
- JSONL format with `stamp`, `kind`, `body`, `prev` (SHA-256 of previous line), `mac` (HMAC-SHA256 over prev + payload).
- Exclusive file lock around each append; `0600` on the ledger and key on Linux.
- Pester suite: create, append three, read in order, verify, detect a one-byte edit on line 2 (names lines 2 and 3).
