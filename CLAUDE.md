# CLAUDE.md — OneDrive for Business Export Tool

Project context for Claude Code sessions. This file records the design brief,
architecture, decisions, and everything learned during the build-and-bring-up
session (2026-07-22). Read alongside `README.md` (operator docs).

## What this project is

A production-grade, Windows-first tool that exports **one** Microsoft 365 /
OneDrive for Business user's entire drive (designed for ~900k files / ~10 TB)
to local storage (e.g. `R:\`), built for multi-day unattended runs.
PowerShell 7 + Microsoft Graph REST + SQLite + a localhost web dashboard. It
is an export, not a migration: it never deletes anything at the destination,
never uses the OneDrive sync client, never uses browser ZIP downloads.

**Live deployment state — read this first:** all deployment-specific details
(tenant/target UPN, certificate thumbprint, app registration, drive id, exact
scale, run history, operator/machine notes) are deliberately kept OUT of this
repository so it stays public-safe. They live next to the project folder,
outside git, in:

    ..\onedrive-export-assets\deployment-details.md
    (i.e. C:\code\onedrive-export-assets\ on the operator's machine)

Any session working on the LIVE export should read that file first, and any
new tenant-identifying detail learned in a session goes THERE, never into
files under this repo. Public-safe summary: the tool passed a small live test
and a full production run was started 2026-07-23 under
`tools\Start-WithAutoRestart.ps1`; a one-time `-FullRescan` was needed after
removing the test include filter (see bug #3).

## Machine/environment quirks (will bite you if forgotten)

- **pwsh 7.6.3 is the winget MSIX build** at
  `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe` — NOT
  `C:\Program Files\PowerShell\7\`. It is not on the default tool-shell PATH.
- The default shell tool here is **Windows PowerShell 5.1**. PSSQLite is only
  installed for pwsh 7 (`Documents\PowerShell\Modules`). Run anything touching
  the DB or the tool via pwsh 7.
- **Inline `pwsh -Command "..."` through the 5.1 shell silently fails** on
  nontrivial quoting (exit 1, no output). Always write a `.ps1` to a file and
  use `pwsh -File`.
- Local console time is BST (UTC+1); logs are local time, `expiresOn`/ISO
  fields are UTC. A token expiry that "looks instant" is usually this offset.
- Syntax is kept 5.1-parser-compatible (no `?:`, `??`, `&&`) so files can be
  parse-validated from the default shell, even though the runtime is PS7-only
  (`-SkipHttpErrorCheck`, `File.Move(src,dst,$true)`, `Start-ThreadJob`).

## Design brief — final architecture

### Component map

```
Start-OneDriveExport.ps1   entry point; phase orchestration; token refresher
                           closure; completion hold-open; summary + failures CSV
src/Config.psm1            JSON config load/validate/defaults; resolves paths
src/Logging.psm1           daily-rolling JSONL (machine) + text (human) logs
src/PathUtils.psm1         Windows-safe name sanitization, \\?\ long paths,
                           include/exclude pattern matching
src/Database.psm1          SQLite layer (PSSQLite): schema, upsert w/ status
                           preservation, batch dispatch, delta cursor persistence
src/GraphAuth.psm1         device-code flow (delegated, DPAPI-cached refresh
                           token) + certificate client-assertion flow (app-only)
src/GraphApi.psm1          REST wrapper: Retry-After, backoff+jitter, global
                           backoff gate, fail-fast 401 handling
src/Discovery.psm1         phase 1: delta enumeration -> manifest; resumable
                           per-page; honours dashboard pause/stop
src/Downloader.psm1        phase 2: worker thread pool; JIT metadata + fresh
                           downloadUrl; .partial + Range resume; result batching;
                           destination health auto-pause; control file
src/Verifier.psm1          phase 3: size/timestamp/QuickXorHash verification
                           (inline C# QuickXorHash — the ODB-native hash);
                           failures re-queued for download
src/StatusReporter.psm1    status.json / failures.json snapshots (atomic,
                           BOM-less UTF-8), throughput EMA, ETA, history ring
src/Dashboard.psm1         HttpListener on localhost: serves web/index.html,
                           /api/status, /api/failures, /api/log tail; POST
                           /api/control writes control.json
web/index.html             self-contained SPA: tiles, canvas charts (throughput/
                           completed/failures), workers, failures, log tail,
                           pause/resume/stop, complete-state banner
tools/Init-Database.ps1    schema pre-create/inspect
tools/Export-Failures.ps1  CSV of failed/retry items
test/Run-OfflineTests.ps1  32 unit checks (no tenant needed)
test/Run-IntegrationTest.ps1 23 integration checks (no tenant needed)
```

### Threading and ownership model (the core invariant)

- **Only the main thread touches SQLite.** Ever.
- N worker threads (`Start-ThreadJob`, default concurrency 4) receive work via
  an in-memory `ConcurrentQueue` and return results via another. The main loop
  drains results and commits them in transactions.
- Shared state is one `[hashtable]::Synchronized` (`$Shared`) passed by
  reference into thread jobs via `-ArgumentList` (same process). Per-worker
  slots (`Workers[$id]`, `WorkerBytes[$id]`) are single-writer, so unsynchronized
  increments are safe; cross-thread counters (throttle counts) tolerate rare
  undercount — display only.
- The dashboard thread **never touches SQLite** — it serves JSON snapshot files
  the main loop writes, so it can never block or corrupt the export.

### Shutdown signals (got this wrong once — see bug #5)

- `$Shared.Stop` — **global**: operator stop, fatal error, final shutdown.
  Watched by the dashboard loop, discovery loop, workers, GraphApi waits.
- `$Shared.PoolStop` — **download-pool-local**: set by `Invoke-DownloadPhase`'s
  `finally` to wind down its own workers at phase end. Reset at phase start.
  This separation is what lets the dashboard and later phases outlive the
  download phase, including the post-run hold-open.
- `UserPaused` (operator) and `SystemPaused` (destination unhealthy) are
  independent; either pauses dispatch and workers.

### Durable state machine (SQLite is the system of record)

`items.status`: `discovered` (folders) → `queued` → `dispatched` →
`downloaded` → `verified`, plus `retry_wait` (transient failure, with
`next_retry_at`), `failed` (retries exhausted), `skipped` (filter/package),
`gone` (deleted in source). Crash rules:

- `dispatched`/`downloading` rows reset to `queued` on every startup
  (`Reset-StaleStatus`) and in the download phase's `finally`.
- Discovery commits each delta page **and its cursor in one transaction** —
  `state.delta_next` mid-enumeration, `state.delta_link` when complete. Crash
  resumes at the exact page; later re-discovery only sees changes.
- Upsert preserves `downloaded`/`verified` **only when the eTag is unchanged**;
  a changed eTag re-queues. `skipped` is deliberately NOT preserved — it is
  recomputed from current include/exclude config every discovery pass, so a
  filter change + `-FullRescan` re-queues previously skipped files (bug #3).
- `retry_wait` backoff: 30s·2^attempts capped at 1h, plus jitter; `maxRetries`
  (default 8) then `failed`. `-Mode RetryFailed` resets `failed` → `queued`.

### Download path

Per file, a worker: (1) GETs fresh item metadata — current size/eTag and a
fresh pre-authenticated `@microsoft.graph.downloadUrl` (expires ~1h, so it is
never stored); (2) if the final file exists with matching size → skip
(`skipped_existing` counts as done); (3) streams to `<file>.partial` with a
1 MB buffer, per-read stall timeout (180s), and a `.partial.meta` sidecar
recording the source eTag; (4) on resume, sends HTTP `Range` **only if the
sidecar eTag matches current** — else discards the partial; (5) verifies final
length == metadata size, `Flush($true)` (fsync), atomic `File.Move` into
place, stamps source created/modified timestamps (UTC). 404/deleted → `gone`;
no downloadUrl (OneNote/package) → `failed_permanent` with a clear reason.
All file I/O uses `\\?\` long-path prefixes.

### Throttling (Microsoft guidance)

`Invoke-GraphApi` retries 429/5xx with `Retry-After` honoured when present,
else exponential backoff + jitter capped at 5 min. A 429/503 sets a **global
backoff gate** (`$Shared.BackoffUntil`) that all workers respect together —
hammering during throttle extends the penalty. Content downloads (downloadUrl)
implement the same 429/503 handling separately in the worker. 401 handling:
one 60-second refresh window, then **fail fast** with an actionable message
distinguishing delegated vs application permission (bug #4).

### Auth (no MSAL/Graph-SDK dependency — deliberate)

- **DeviceCode** (delegated, testing): plain REST device-code flow; sign in as
  the drive owner; refresh token cached DPAPI-encrypted
  (`state\refresh_token.dat`) so restarts are silent.
- **Certificate** (app-only, production): client-credentials with a
  self-signed cert; the client-assertion JWT (RS256, x5t header) is built by
  hand in `GraphAuth.psm1` (~40 lines). Cert looked up in `CurrentUser\My`
  then `LocalMachine\My`; PFX + `ODEXPORT_PFX_PASSWORD` env var also supported.
- The main thread owns refresh via a closure (`$refreshToken`) invoked at the
  top of every phase loop iteration; refreshes 10 min before expiry; retries
  forever on failure (logs every 60s) rather than killing a week-long run.
- **Gotcha that cost us a live failure:** app-only tokens need the
  **APPLICATION** `Files.Read.All` permission with admin consent; the
  delegated consent from device-code testing does not apply. Diagnose by
  decoding the JWT payload — no `roles` claim ⇒ consent missing.

### Dashboard

`http://localhost:8787/` (HttpListener; if non-admin start fails:
`netsh http add urlacl url=http://localhost:8787/ user=%USERNAME%`). Routes:
`/` (index.html), `/api/status`, `/api/failures`, `/api/log?lines=N` (tail via
shared-read handle), POST `/api/control` `{command: pause|resume|stop}` →
writes `state\control.json` `{command, ts}`; the main/discovery loops poll it
and act once per unique `ts`. A stale control file is deleted at startup so a
previous run's `stop` can't kill a new run. The SPA polls every 2s, hand-rolled
canvas line charts (no external assets — CSP-friendly, offline), staleness
banner if `generatedAt` > 60s old, green complete banner + `✔ complete` pill
when `phase == "complete"`. Dark palette follows the dataviz-skill reference
(surface #1a1a19, series blue/aqua/red #3987e5/#199e70/#e66767).

### Completion hold-open

After a completed run (not on error/operator stop), the process keeps the
dashboard alive: console prompt "Press ENTER … to shut down the web server",
also closeable via the dashboard Stop button; snapshot refreshed every 20s so
the page stays "fresh". Skipped automatically when there is no interactive
console; `-ExitOnComplete` disables it explicitly (scheduled tasks — the
README's schtasks example includes it).

### Verification

- `size`: existence + exact size (every file).
- `timestamp`: + last-modified within `timestampToleranceSec`.
- `hash`: size for **all** + QuickXorHash (inline C#, the reference
  implementation from Microsoft's docs; validated: empty-input vector
  `AAAAAAAAAAAAAAAAAAAAAAAAAAA=`, chunking-independence) for all or a
  `hashSpotCheckPercent` sample. **The spot-check percent only applies in
  `hash` mode** — in `size` mode it is ignored (advice corrected mid-session).
- Verify failures are re-queued; `-Mode Full` automatically runs another
  download pass if verification re-queued anything.

### Key decisions and their rationale

1. **PowerShell 7 end-to-end** — workers are thread jobs running .NET
   `HttpClient` streaming, so the hot path is compiled .NET. No second
   language needed; operator experience stays pure PowerShell.
2. **No Microsoft.Graph SDK / MSAL.PS** — the SDK hides tokens and is awkward
   across threads; MSAL.PS is deprecated. ~150 lines of auditable REST.
   Only external dependency: **PSSQLite** (ThreadJob ships with PS7).
3. **SQLite over JSON/CSV state** — 900k rows need indexed status queries,
   transactions, and WAL concurrency (safe to read while running).
4. **Delta API over recursive `/children`** — one flat stream, parents before
   children (folder-path cache `id → rel_path`, DB-rebuilt on resume),
   page-exact resumability, and free incremental re-discovery.
5. **`downloadUrl` over `/content`** — pre-authenticated (no auth header on
   the data path), supports Range, fetched JIT so stale manifests never
   matter.
6. **Snapshot-file decoupling for the dashboard** — the web tier can be dumb,
   crash-proof, and DB-free.

## Bugs found and fixed during this session (regression watch-list)

1. **UTF-8 BOM in status.json** broke strict JSON clients (`Invoke-RestMethod`
   returned raw string; browsers masked it). Fix: BOM-less
   `UTF8Encoding($false)` in `Write-JsonAtomic`. *Lesson:
   `[System.Text.Encoding]::UTF8` writes a BOM.*
2. **Discovery wrote no status snapshots** → dashboard dead for the whole
   (hour-long) enumeration. Fix: snapshot every 5 pages.
3. **`skipped` preserved across re-discovery** (same eTag) → removing the
   include filter would have left ~908k files skipped even with `-FullRescan`.
   Fix: recompute `skipped` every pass; only `downloaded`/`verified` are
   preserved. Unit-tested.
4. **401 dead-wait**: main-thread Graph calls waited 5 min for a token refresh
   only the main thread could perform, then died with a generic error (hit
   live when app-only consent was missing). Fix: one 60s window, then
   fail-fast with the delegated-vs-application guidance.
5. **Single `Stop` flag** shut the dashboard down when the download phase's
   worker pool wound itself down (dashboard died before verify even ran; also
   verify was skipped entirely in `Full` mode because of the same flag). Fix:
   `PoolStop` vs `Stop` separation + hold-open. Integration-tested
   (`Stop` must remain `$false` after pool shutdown).
6. **Stale `control.json`** from a previous run (e.g. its final `stop`) was
   executed at next startup. Fix: delete the control file at startup.
7. **Synchronized-hashtable enumeration race** (crashed the production run
   ~40 min in, 2026-07-23 00:45): enumerating `$Shared.WorkerBytes.Values` /
   `$Shared.Workers.Keys` while workers write invalidates the enumerator —
   synchronization covers individual ops, NOT enumeration, and even value
   updates on existing keys bump the version. Fix: `Get-SyncSnapshot`
   (clone under `SyncRoot` lock, exported from StatusReporter) at every
   cross-thread enumeration site (StatusReporter, `Test-AllWorkersIdle`,
   `Write-ExportSummary`). Regression-covered by the integration suite's
   concurrent-hammer test. *Rule: never enumerate a `$Shared` collection
   directly — always `Get-SyncSnapshot` first.*
8. **Retry starvation** (observed live 2026-07-23: two 503'd files sat in
   `retry_wait` 5+ hours past their due time): `Get-NextBatch`'s combined
   `queued OR retry_wait-due` query satisfied its LIMIT entirely from the
   ~850k-row queued pool, so due retries were never selected until the queue
   drained. Fix: query due `retry_wait` rows first, then top up with `queued`.
   Unit-tested (due retry beats queued backlog at LIMIT 1).
9. **Start-ThreadJob's default ThrottleLimit of 5** silently capped the worker
   pool: dashboard job + workers 1-4 filled the five slots, so with
   `concurrency: 6` workers 5-6 sat `NotStarted` forever (observed live after
   bumping concurrency). Fix: `-ThrottleLimit 32` on every `Start-ThreadJob`
   call. Integration-tested with an 8-worker pool asserting all 8 register.
10. **status.json rename vs. concurrent reader** (killed the run once, live,
    2026-07-24 00:51; watchdog auto-recovered in 61s): `File.Move(tmp, dest,
    overwrite)` fails with access-denied while any reader holds dest open
    without `FileShare.Delete`. Fix on both sides: `Write-JsonAtomic` retries
    5x then SKIPS the cycle (snapshots are telemetry — never fatal), and the
    dashboard reader opens with `ReadWrite|Delete` sharing so renames never
    collide with it. Integration-tested against a hostile non-delete-sharing
    reader.

## Testing

```
pwsh -File test\Run-OfflineTests.ps1       # 32 checks: sanitization, filters,
                                           # QuickXor vectors, DB state machine,
                                           # backoff, logging
pwsh -File test\Run-IntegrationTest.ps1    # 23 checks: verify phase w/ real
                                           # (incl. corrupted) files, pool
                                           # lifecycle + shutdown flags,
                                           # snapshots, dashboard HTTP API
```

Both run with **no tenant** (that was the point). After ANY code change: run
both suites + parse-validate all `.ps1`/`.psm1` with
`[System.Management.Automation.Language.Parser]::ParseFile` (works from 5.1).
The Graph-facing paths (delta paging, real downloads, cert auth) were proven
live in the small-folder test; there is no mock for them — changes there
deserve a live `-Mode Discover` smoke against the tenant.

Live-run monitoring without disturbing the process: read
`state\status\status.json`, tail `logs\export-YYYYMMDD.log`, or query
`state\export.db` (WAL — concurrent reads are safe) via a script file run
under pwsh 7.

## Config quick-reference (`config.json`, gitignored)

tenantId / clientId / userPrincipalName / authMode (`DeviceCode`|`Certificate`)
/ certificateThumbprint / destinationRoot / concurrency (1–16, keep ≤6) /
maxRetries / downloadBufferMB / readStallTimeoutSec / verifyMode
(`size`|`timestamp`|`hash`) / hashSpotCheckPercent (hash mode only) /
include+exclude (bare pattern = name match; pattern with `\` = rel-path match;
non-empty include = allowlist) / dashboardPort / statusIntervalSeconds /
diskMinFreeGB / notifyWebhookUrl + notifyFailureThreshold / paths.{database,
logDir,stateDir}. Production target: `verifyMode: hash`,
`hashSpotCheckPercent: 5`, concurrency 4.

## Known limitations

- OneNote notebooks (package items) have no Graph content stream → `skipped`.
- App-only `Files.Read.All` is tenant-wide; delete the app registration after
  the export.
- Incremental delta doesn't re-path all descendants of a renamed folder →
  after mass reorganizations run `-Mode Discover -FullRescan`.
- Names may be sanitized (illegal chars/reserved names; collisions get a
  `~xxxxxx` suffix); the manifest maps source name ↔ local path.
- Dashboard is localhost-only and unauthenticated by design.
- Live concurrency tuning requires a restart (safe at any time).
