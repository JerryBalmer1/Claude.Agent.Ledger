# Design decisions

## 1. PowerShell, not Go

The agent image already carries PowerShell 7.4 for its entrypoint, and the host side (Invoke-Build, Pester)
is PowerShell too. A PowerShell module means one language across the container and the host, no binary to
cross-compile per platform, and the same functions for writing in the container and verifying on the host.
.NET gives us SHA-256, HMAC, fixed-time comparison, exclusive file locks and Unix file modes without
dependencies. Go would buy speed and a static binary we do not need at a few entries per run.

## 2. Hash chain, not signatures (signing deferred)

Each line carries `prev` (SHA-256 of the previous line) and `mac` (HMAC-SHA256 over prev + payload with a
32-byte key on the ledger volume). This detects edits, deletions, insertions and reordering by anyone who
does not hold the key, and needs no PGP, no key management and no external tools.

It does not prove *who* wrote an entry, and anyone holding `key.bin` can rewrite the whole chain consistently.
Asymmetric signatures (the agent signs, the host holds only the public key) would close that, but need key
distribution we do not have yet. Deferred until there is a reason to distrust the agent's own writes; at that
point the format gets a version field and a `sig` member.

## 3. The agent never holds the key; the keeper is an authority it cannot reach

The module has two roles. The writer (`Add-LedgerEntry -Spool`) runs in the agent and appends unsigned
`{stamp, kind, body, seq}` lines to a spool. The keeper (`Start-LedgerKeeper`) runs in a separate `ledger`
container, owns `key.bin`, and moves spooled lines into the chained ledger. The two share only the spool
volume. The ledger volume, and the key on it, are mounted into the keeper alone; the keeper has no network,
so the agent has no route to it at all; and the agent image contains no `key.bin`. Claude.Agent's Smoke task
checks the last two on every build.

What that buys: once a line is in the ledger, the agent cannot rewrite or delete it, cannot recompute the
chain, and cannot forge a valid entry, because it has neither the file nor the key. The 0.1.0 limit (an agent
that could read `key.bin` could recompute everything) is gone.

What it does not buy: the agent still decides what to write. It can lie in a line, omit one, or tamper with
lines still sitting in the spool before the keeper takes them; the keeper flushes every 500 ms, so that window
is short but real. `seq` makes a deleted spooled line visible as a gap (checked by `Test-Ledger` since 0.2.1, decision 4). The keeper chains the writer's exact
bytes and, for anything that is not a well-formed entry, ledgers a `ledger.rejected` entry with the raw text
instead of dropping it, so a malformed or forged line (one carrying its own `prev`/`mac`) is recorded, not trusted.

Signing stays deferred (decision 2). The keeper's HMAC proves the ledger has not changed since the keeper
wrote it; it does not prove to a third party who wrote it, and whoever holds `key.bin` (the keeper, or the host
copying the volume out) can still rewrite the chain. Asymmetric signatures held by the keeper would close that
when there is a reason to distrust the host side.

## 4. seq is checked, and the ledger, not the spool, says where it stands

Decision 3 relied on `seq` to expose a spooled line deleted before the keeper took it, but nothing checked it:
the chain is built over whatever arrives, so a dropped line left a valid chain. `Test-Ledger` now requires the
`seq` values in the ledger to run 1, 2, 3, ... and reports any line that breaks that as `seq-gap`, then
resumes from that line's seq, so one dropped line is one finding. Gaps, repeats and decreases all count.

Only lines that carry `seq` are counted. `ledger.rejected` entries are written by the keeper and have none;
0.1.0 lines predate it. A rejected line that carried a seq therefore shows as a gap at the next writer line,
which is right: something reached the spool that the writer did not write.

The counter lives on the spool (`<Spool>/seq`), where the writer can advance it under the spool lock. If it
is lost (spool volume recreated while the ledger volume is kept, or the file deleted), the writer would start
again at 1, and every later run would fail `seq-gap`. So the keeper, on start, reads the last `seq` in
`ledger.jsonl` and the highest still pending, and raises the counter to the larger of the two. The writer then
continues the ledger's sequence, and an idempotent re-flush (lines chained but not yet truncated, which the
keeper skips) adds nothing and leaves no gap.

The keeper never lowers the counter. A counter ahead of everything in the ledger and the spool means a line
was taken a number and never arrived: a writer crash between advancing `seq` and writing, or a deleted
trailing spool line. Lowering it would let the next line reuse that number and hide the loss; keeping it makes
the loss a `seq-gap`. The cost is a false alarm after a writer crash, which is rare and worth looking at anyway.

Not closed: the keeper syncs only when it starts. If the spool counter is lost and the writer appends before
the keeper starts, those lines repeat earlier numbers and fail `seq-gap`. In Claude.Agent the keeper starts
first, and `Invoke-Build Clean` drops spool and ledger together.
