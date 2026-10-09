# Changelog

## 0.2.4 - 2026-10-09

- 0.2.4: findings fixes; snapshot entries
- Finding 2: a rejected spool line carrying a stamp is not ledgered twice after a keeper crash between chaining
  and truncating; the flush matches it against the `body.line` of trailing `ledger.rejected` entries. A stampless
  one is still ledgered again, never dropped (design 5).
- Finding 4: the keeper checks `stamp` (UTC `yyyy-MM-ddTHH:mm:ss.fffffffZ`, a real date) and `body` (an object) on
  intake; new `ledger.rejected` reasons `stamp is not a UTC yyyy-MM-ddTHH:mm:ss.fffffffZ string` and
  `body is not a JSON object`. Existing ledgers verify unchanged.
- Findings 1 and 3: the README describes the MAC payload as the line minus its end-anchored `prev`/`mac` suffix,
  and says the keeper stamps `ledger.rejected`. `Start-LedgerKeeper` help updated.
- New `Get-AgentSnapshot -At agent.egress-check|agent.stop`: the body of a new `agent.snapshot` entry (env with
  values `<redacted>` under names containing token, secret, key, password or credential, or a `PAT` segment; image digest, os-release, packages, executables on PATH with ldd libraries,
  mounts, uid/gid/groups, tools, hooks and MCP servers handed to claude). Design 6.
- `docs/stream-contract.md`: `agent.snapshot` section and run rows; `policy.deny` with `reason: "hook-failure"`
  for a failed pre hook (Finding 5); each Finding marked with what 0.2.4 did. Emitting both needs Claude.Agent's
  entrypoint and Claude.Agent.Policy's pre hook to change, which is not done here.
- `tests/fixtures/policy-smoke.ledger.jsonl`: two real `agent.snapshot` lines from `claude-agent:dev`, inserted
  after `agent.egress-check` and before `agent.stop`. seq is now 46..56, `prev` is re-chained from the line-45
  anchor, and every `mac` is recomputed with a 32-zero-byte fixture key (the run's `key.bin` is gone) and now
  checked. New `tests/Findings.Tests.ps1` and `tests/Snapshot.Tests.ps1`; `tests/StreamContract.Tests.ps1` extended.

## 0.2.3 - 2026-10-09

- 0.2.3: stream contract doc; policy-smoke fixture
- `docs/stream-contract.md`: the line shape the keeper writes (members, order, types, which are required), the
  `prev`/`mac` chain, `seq`, what the keeper chains or turns into `ledger.rejected`, how Claude.Agent runs start
  and stop, and how Claude.Agent.Policy decisions and denials appear. Checked against the code; five places
  where the README, the function help or Claude.Agent's entrypoint comment disagree with the code are listed
  as Findings, doc wording otherwise unchanged.
- `tests/fixtures/policy-smoke.ledger.jsonl`: lines 46-54 (the last run) of Claude.Agent's
  `artifacts/ledger/ledger.jsonl`, byte for byte, nothing redacted. `tests/StreamContract.Tests.ps1` parses it under
  the contract, walks the `prev` chain from the SHA-256 of ledger line 45, checks `seq` 46..54 and exactly one
  `policy.deny` naming `rules[2]`.
- `Invoke-Build Report` writes `artifacts/run-report.json` (run-report skill); `tests/Invoke-Tests.ps1` writes
  `artifacts/testResults.xml` for it. No change to the writer or the keeper.

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
