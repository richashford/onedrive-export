# OneDrive for Business → Local Export Tool

Production-grade, resumable export of a **single OneDrive for Business user**
(designed for ~9.6 TB / ~900,000 files) to local storage (`R:\`), built on
PowerShell 7 + Microsoft Graph + SQLite, with a localhost web dashboard.

```
onedrive-export\
├── Start-OneDriveExport.ps1     # entry point (all modes)
├── config.sample.json           # copy to config.json and edit
├── src\
│   ├── Config.psm1              # config load/validate
│   ├── Logging.psm1             # JSONL + text logs, daily rotation
│   ├── PathUtils.psm1           # Windows-safe names, \\?\ long paths, filters
│   ├── Database.psm1            # SQLite manifest (system of record)
│   ├── GraphAuth.psm1           # device-code + certificate auth (no MSAL dependency)
│   ├── GraphApi.psm1            # REST wrapper: 429/503 handling, Retry-After, backoff+jitter
│   ├── Discovery.psm1           # phase 1: delta enumeration -> manifest
│   ├── Downloader.psm1          # phase 2: worker pool, partial-resume downloads
│   ├── Verifier.psm1            # phase 3: size/timestamp/QuickXorHash verification
│   ├── StatusReporter.psm1      # status.json / failures.json snapshots
│   └── Dashboard.psm1           # HttpListener web server (localhost)
├── web\index.html               # dashboard SPA (no external assets)
├── tools\
│   ├── Init-Database.ps1        # pre-create/inspect the DB (optional)
│   └── Export-Failures.ps1      # CSV export of failed items
├── state\                       # created at runtime: export.db, status\, control.json, refresh_token.dat
└── logs\                        # created at runtime: export-YYYYMMDD.log/.jsonl, failures-*.csv
```

---

## 1. Architecture in one page

- **SQLite is the system of record.** Every item Graph returns is upserted into
  `state\export.db` with a status
  (`discovered → queued → dispatched → downloaded → verified`, plus
  `retry_wait`, `failed`, `skipped`, `gone`). Every download/verify result is
  committed in a transaction. Restart at any time; the DB says what's left.
- **Discovery uses the Graph delta API** — one flat stream of all items, parents
  before children, with the page cursor committed *with* each page. A crash
  mid-enumeration of 900k items resumes at the exact page. Re-running discovery
  later uses the stored `deltaLink` and only sees changes.
- **Downloads run on N worker threads** (default 4). Only the main thread
  touches SQLite; workers get work via an in-memory queue and report results
  via another. Each worker fetches fresh item metadata (fresh pre-authenticated
  `@microsoft.graph.downloadUrl`, current size/eTag), streams to `<file>.partial`,
  fsyncs, then atomically renames into place and stamps source timestamps.
  Interrupted large files resume via HTTP `Range` if the source eTag is unchanged.
- **Throttling:** every Graph call honours `Retry-After`, retries 429/5xx with
  exponential backoff + jitter, and a 429/503 raises a **global backoff gate**
  that pauses *all* workers (per Microsoft guidance, hammering during throttle
  extends the penalty).
- **Dashboard is decoupled:** the main loop writes `status.json` / `failures.json`
  snapshots; a background HttpListener serves them plus the log tail on
  `http://localhost:8787/`. Pause/Resume/Stop buttons write `control.json`,
  which the main loop polls. The dashboard never touches SQLite, so it can
  never block or corrupt the export.
- **Fail-safe behaviors:** R:\ disappearing or filling up auto-pauses (and
  auto-resumes); token expiry refreshes proactively and retries forever rather
  than crashing; Ctrl+C runs the `finally` blocks (state flushed, workers
  drained, `dispatched` rows re-queued).

Why these choices:

- **PowerShell 7 end-to-end** — workers are thread jobs running .NET
  `HttpClient` streaming, so the hot path is .NET code, not interpreted
  pipeline. Nothing here needs another language.
- **No Microsoft.Graph SDK / MSAL.PS dependency** — the SDK hides tokens and is
  awkward across threads; device-code and certificate flows are ~150 lines of
  plain REST that you can read and audit. Only external dependency: **PSSQLite**
  (plus ThreadJob, which ships with PS7).
- **downloadUrl over /content** — `@microsoft.graph.downloadUrl` is a short-lived
  pre-authenticated URL: no auth header on the data path, supports `Range`, and
  is fetched just-in-time per file so week-old manifests never hold dead links.

---

## 2. Prerequisites

On the export machine (Windows 10/11 or Server):

```bash
winget install Microsoft.PowerShell
```

Then in **pwsh** (the tool auto-installs these too):

```bash
pwsh -Command "Install-Module PSSQLite -Scope CurrentUser -Force"
```

Optional (only if the dashboard reports *access denied* when starting as a
non-admin — run once from an elevated prompt):

```bash
netsh http add urlacl url=http://localhost:8787/ user=%USERNAME%
```

Make sure long path support is enabled (Windows 10 1607+; usually already on):

```bash
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
```

(The tool also uses `\\?\` prefixes everywhere, so this is belt-and-braces.)

## 3. Graph app registration

Entra admin center → **App registrations → New registration**
(single tenant, no redirect URI needed).

Record the **Application (client) ID** and **Directory (tenant) ID** into
`config.json`.

### 3a. Delegated test mode (device code)

1. App → **Authentication** → *Advanced settings* → **Allow public client
   flows = Yes**.
2. App → **API permissions** → *Microsoft Graph → Delegated* →
   `Files.Read.All` → **Grant admin consent**.
   (`Files.Read` is enough if you only ever sign in as the drive owner, but
   `Files.Read.All` also covers drives shared to that account.)
3. `config.json`: `"authMode": "DeviceCode"`.
4. First run prints a code + URL; **sign in as the target user**. The refresh
   token is cached DPAPI-encrypted in `state\refresh_token.dat`, so subsequent
   runs are silent until the refresh token expires or is revoked.

### 3b. Unattended production mode (certificate)

1. Create a certificate (self-signed is fine; 2-year validity shown):

   ```bash
   pwsh -Command "$c = New-SelfSignedCertificate -Subject 'CN=OneDriveExport' -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 -NotAfter (Get-Date).AddYears(2); Export-Certificate -Cert $c -FilePath .\odexport.cer; $c.Thumbprint"
   ```

2. App → **Certificates & secrets → Upload certificate** → `odexport.cer`.
3. App → **API permissions** → *Microsoft Graph → **Application*** →
   `Files.Read.All` → **Grant admin consent**.
4. `config.json`:
   `"authMode": "Certificate"`, `"certificateThumbprint": "<thumbprint>"`.
   (Alternative: `certificatePfxPath` + password in env var `ODEXPORT_PFX_PASSWORD`.)
5. If running as a service account / SYSTEM, put the cert in
   `LocalMachine\My` instead — the tool checks both stores.

> ⚠ **Scope note:** application-permission `Files.Read.All` can read *every*
> drive in the tenant, not just the one user. This is how Graph app-only OneDrive
> access works; there is no supported per-OneDrive `Sites.Selected` equivalent.
> Protect the certificate accordingly, and delete the app registration when the
> export is done.

## 4. Configure

```bash
copy config.sample.json config.json
```

| Key | Meaning |
|---|---|
| `userPrincipalName` | The OneDrive owner to export |
| `authMode` | `DeviceCode` (testing) or `Certificate` (unattended) |
| `destinationRoot` | e.g. `R:\\OneDriveExport` |
| `concurrency` | worker threads, 1–16. **Default 4; keep ≤6** — Graph throttles per user+app, more workers mostly buys more 429s |
| `maxRetries` | attempts per file before `failed` (default 8, backoff 1–60 min between) |
| `verifyMode` | `size` (fast), `timestamp`, or `hash` (QuickXorHash, reads every byte back) |
| `hashSpotCheckPercent` | with `hash` mode: only hash this % of files (0 = hash all) |
| `include` / `exclude` | wildcard patterns; bare patterns match names (`*.tmp`, `~$*`), patterns with `\` match relative paths (`Recordings\*`) |
| `dashboardPort` | default 8787 |
| `diskMinFreeGB` | auto-pause threshold for R:\ free space |
| `notifyWebhookUrl` | optional; POSTs JSON `{text, subject, body}` on completion/abort/failure-threshold (Slack/Teams-compatible) |

## 5. Running

### Interactive console

```bash
pwsh -File C:\code\onedrive-export\Start-OneDriveExport.ps1 -Mode Discover
```

```bash
pwsh -File C:\code\onedrive-export\Start-OneDriveExport.ps1 -Mode Full
```

Modes:

| Mode | Does |
|---|---|
| `Discover` | discovery only = **dry run** (manifest, no downloads) |
| `Full` | discovery → download → verify (default) |
| `Download` | download only, from existing manifest |
| `Verify` | **verify-only** pass; bad files are re-queued but not downloaded |
| `RetryFailed` | reset permanently-failed items, then download |

Flags: `-FullRescan` (drop the delta cursor, re-enumerate everything),
`-NoDashboard`, `-ExitOnComplete`, `-ConfigPath <path>`.

When a run completes in a console, the process **stays alive with the dashboard
still served** so you can review the final result (the page shows a green
"complete" banner). Press ENTER at the console — or the dashboard's Stop
button — to confirm shutting the web server down. Use `-ExitOnComplete` for
unattended/scheduled runs where the process should just end.

Dashboard: **http://localhost:8787/** — overview tiles, throughput/completed/
failures charts, per-worker activity, failure browser, live log tail, and
Pause / Resume / Stop buttons. Stop is always safe: state is committed
continuously and the run resumes where it left off.

Pause/resume/stop without the dashboard: write `state\control.json`, e.g.
`{"command":"pause","ts":"2026-07-22T12:00:00Z"}` (the `ts` must change each time).

### Unattended / scheduled task

Use certificate auth. Register a task that starts at boot and restarts on failure:

```bash
schtasks /Create /TN "OneDriveExport" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "\"C:\Program Files\PowerShell\7\pwsh.exe\" -NoProfile -ExecutionPolicy Bypass -File C:\code\onedrive-export\Start-OneDriveExport.ps1 -Mode Full -ExitOnComplete -ConfigPath C:\code\onedrive-export\config.json"
```

Notes for SYSTEM: certificate must be in `LocalMachine\My`, and R:\ must be
visible to SYSTEM (mounted drive letters usually are for local RAID; verify with
`psexec -s cmd /c dir R:\` if unsure). Start it manually with
`schtasks /Run /TN OneDriveExport`; watch via the dashboard. Because every phase
is idempotent, "restart the task" is always the correct recovery action.

## 6. Recovery guide

| Situation | What happens / what to do |
|---|---|
| **Throttling (429/503)** | Automatic: Retry-After honoured, all workers back off together, counters visible on the dashboard. Persistent heavy throttling → lower `concurrency`. No action needed. |
| **Expired access token** | Refreshed automatically ~10 min before expiry. On unexpected 401, workers pause up to 5 min while the main loop re-authenticates. |
| **Expired refresh token (DeviceCode mode)** | The run logs token errors and retries every 60 s. Restart in a console and re-do the device-code sign-in (or switch to Certificate mode — recommended for anything multi-day). |
| **Machine reboot / process crash** | Just run the same command again. `dispatched` rows re-queue, discovery resumes from its saved page cursor, finished files are skipped by manifest status, and `.partial` files resume via Range if the source file is unchanged (else restart cleanly). |
| **R:\ disconnected or full** | Auto-pause with reason shown on dashboard + log; auto-resume within ~15 s of the drive returning. If the process was killed while R:\ was gone, just restart it. |
| **Partial downloads** | `<name>.partial` + `.partial.meta` sidecar (records source eTag). Resumed only when eTags match; deleted and restarted otherwise. A final size check guards every completed file before it's renamed into place. |
| **Files changed during export** | Workers re-read metadata just-in-time; changed files download the current version and the manifest is updated. Deleted files become status `gone` (not an error). |
| **Failed items** | After `maxRetries`, status `failed`. Review: dashboard → Failures, or `tools\Export-Failures.ps1`. Re-run with `-Mode RetryFailed`. |
| **Source got reorganized mid-export (mass renames/moves)** | Incremental delta updates renamed folders but not every descendant path. Run `-Mode Discover -FullRescan` to rebuild paths, then `-Mode Download`. Already-downloaded content at old paths is not deleted (this tool never deletes exported data). |

Auditability: `logs\export-*.jsonl` has one structured record per state
transition; the `items` table holds id, path, size, eTag/cTag, QuickXorHash,
timestamps, attempts and error per file; `runs` records each run. Query it any
time: `Invoke-SqliteQuery -DataSource state\export.db -Query "SELECT status, COUNT(*) FROM items GROUP BY status"`.

## 7. Verification options

- `size` (default): existence + exact size — cheap enough for 900k files.
- `timestamp`: size + last-modified within `timestampToleranceSec`.
- `hash`: size + **QuickXorHash** (OneDrive for Business' native hash, computed
  locally and compared to the manifest value from Graph). Reads every exported
  byte — budget a full extra pass over 9.6 TB, or set
  `hashSpotCheckPercent` (e.g. `5`) for a statistical check.

In `-Mode Full`, files failing verification are automatically re-queued and a
second download pass runs.

## 8. First-test checklist (do this before the 9.6 TB run)

**Offline tests** (no tenant needed — already passing on this machine) live in
`test\`: `Run-OfflineTests.ps1` (sanitization, filters, QuickXorHash vectors,
DB state machine, backoff) and `Run-IntegrationTest.ps1` (verify phase against
real files incl. corruption, worker-pool lifecycle, status snapshots, dashboard
HTTP API + controls). Run them after any code change:

```bash
pwsh -File C:\code\onedrive-export\test\Run-OfflineTests.ps1
```

```bash
pwsh -File C:\code\onedrive-export\test\Run-IntegrationTest.ps1
```

**Live test against your tenant:**

1. ☐ App registration done; `config.json` filled in; `authMode: DeviceCode`.
2. ☐ Point `destinationRoot` at a scratch folder (even `C:\odx-test`) and set
   `include` to one small folder, e.g. `"include": ["TestFolder\\*"]`.
3. ☐ `-Mode Discover` → confirm counts/bytes on the dashboard look sane and
   `state\export.db` exists.
4. ☐ `-Mode Full` → files appear with correct folder structure, names and
   timestamps; dashboard charts move.
5. ☐ Kill the process (X the window) mid-download → rerun → confirm it resumes
   without re-downloading completed files (watch "kept existing"/session counters).
6. ☐ Pause + Resume + Stop from the dashboard.
7. ☐ Pull R:\ (or rename the folder) mid-run → confirm auto-pause, then auto-resume.
8. ☐ `-Mode Verify` with `verifyMode: hash` on the test set → 0 mismatches.
9. ☐ Switch to Certificate auth, run `-Mode Download` unattended (no prompts).
10. ☐ Remove `include` filter, reset scratch (delete `state\export.db` and the
    test destination or just point at R:\), and start the production run with
    `-Mode Full`.

Sizing expectations: at 4 workers you'll typically see 100–400 Mbps depending on
file-size mix and tenant throttling — plan for roughly **3–10 days** of transfer
for 9.6 TB. Many-small-files phases are request-bound (~5–20 files/s), large
files are bandwidth-bound. The manifest DB will be ~500 MB–1 GB for 900k rows.

## 9. Known limitations & risks

- **OneNote notebooks** (package items) have no downloadable content stream via
  Graph and are marked `skipped`. Export those separately from the OneNote app
  if needed.
- **App-only permission breadth** — see the scope note in §3b.
- Filename sanitization can rename items (illegal Windows chars, trailing
  dots/spaces, reserved names, collisions get a `~xxxxxx` suffix). The manifest
  maps original name ↔ local path for the audit trail.
- Timestamps preserved: created + last-modified. NTFS ACLs/sharing metadata are
  not part of a OneDrive export.
- The delta-based incremental rescan tracks adds/edits/deletes; a *mass folder
  reorganization* mid-export should be followed by `-FullRescan` (see recovery
  table).
- Dashboard binds localhost only; it is unauthenticated by design — anyone on
  the machine can see progress and pause the job.
