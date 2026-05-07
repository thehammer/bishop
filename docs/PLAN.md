# Implement Bishop — Claude Code budget-posture producer

> Note: this plan lives at `docs/PLAN.md` (not the repo root) because the
> author's environment forbids creating non-allowlisted top-level `.md`
> files. Treat `docs/PLAN.md` as the canonical plan path. A future
> implementation commit may add a thin pointer `README.md` referencing it.

## Context

Claude Code enforces rolling rate limits across two windows: a 5-hour and a
7-day bucket. Both are visible to the statusline hook as percent-used and
reset-at-epoch values. Today, no consumer derives a *posture* from those
numbers — agents, scripts, and humans either ignore the data or eyeball it.

Bishop is a small, standalone shell tool that turns the rolling rate-limit
data into a single normalized JSON file (`~/.claude/budget-posture.json`)
any consumer can read in one syscall. It computes a per-window "pace"
(used vs. elapsed window time) and rolls the two windows up to a
top-level posture (`conservative` / `normal` / `elevated` / `flush`).
Mother will read the posture to bias model/effort selection at job spawn;
Claudia will read it at startup to tune recommendations.

Bishop is named after the synthetic from *Aliens* — the same franchise as
Mother. It is **not** an agent: it is a non-interactive CLI plus an
optional launchd heartbeat. It never crashes, never blocks, and degrades
silently to "posture: normal" when input is missing.

The data source already exists:
`~/Code/mother/plugins/mother/statusline/segment.sh` defines
`mother_capture_rate_limits` which writes `~/.mother/rate-limits.json` on
every Claude Code render. Verified shape (live):

```json
{"five_hour":{"used_percentage":23,"resets_at":1778172600},"seven_day":{"used_percentage":65,"resets_at":1778205600}}
```

No ticket; this is greenfield tooling.

## Target

- **Repo:** `bishop` (new, standalone — not a Mother plugin)
- **Branch:** `main` (initial implementation lands directly on the seeded
  `main` branch the planning step created)
- **Base:** initial commit already contains this PLAN.md plus empty
  directory scaffolding (`bin/`, `launchd/`, `tests/`, `scripts/`,
  `docs/`)

## Files to change

All paths are absolute from the repo root `~/Code/bishop/`.

- `bin/bishop` — main CLI (executable shell script,
  `#!/usr/bin/env bash`, `set -euo pipefail`). Implements all
  subcommands: `--refresh`, `status`, `status --json`, `get <field>`,
  `install-agent`, `uninstall-agent`, `--help`. Single file, no library
  split — Bishop is small enough.
- `launchd/com.user.bishop.refresh.plist` — launchd plist that runs
  `bishop --refresh` every 60 seconds. Uses `StartInterval`. Logs to
  `~/.claude/budget-posture.errors.log`.
- `tests/bishop.bats` — bats-core unit tests (10 cases enumerated below).
- `scripts/install.sh` — symlinks `bin/bishop` to `~/.local/bin/bishop`
  (configurable via `PREFIX` env var). Idempotent.
- `scripts/doctor.sh` — checks for `jq`, `flock`, `bats` on PATH, prints
  a green/red summary, exits non-zero if any required dep missing
  (`jq`, `flock` required; `bats` advisory).
- `CLAUDE.md` — short project notes (layout cheatsheet, shell
  conventions matching Mother's style, test command).
- `README.md` — user-facing overview, install instructions, posture
  levels table, env-var reference, consumer examples.

## Approach

### Step 1 — Implement `bin/bishop`

Skeleton:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${BISHOP_SOURCE_PATH:=$HOME/.mother/rate-limits.json}"
: "${BISHOP_OUTPUT_PATH:=$HOME/.claude/budget-posture.json}"
: "${BISHOP_SOURCE_STALE_SECONDS:=600}"

LOCK_PATH="${BISHOP_OUTPUT_PATH}.lock"
ERR_LOG="${HOME}/.claude/budget-posture.errors.log"
STATE_PATH="${BISHOP_OUTPUT_PATH}.state"   # holds last-seen source mtime
```

Subcommand dispatch via a `case` on `$1`. All errors (set -e trap or
explicit) route to `_bishop_log_err` which appends timestamped lines to
`$ERR_LOG`, rotates at 100 KB (rename to `.1`, truncate), and exits 0
unless we're in `status` mode (where stderr is acceptable).

#### `--refresh`

1. If `${BISHOP_DISABLED:-}` is non-empty, exit 0 immediately.
2. Acquire `flock -n 9` on `$LOCK_PATH` via `exec 9>"$LOCK_PATH"`. If
   the lock fails, exit 0 (someone else is refreshing).
3. Stat `$BISHOP_SOURCE_PATH`. If missing, log and exit 0 without
   writing.
4. Read source mtime (`stat -f %m` on macOS). Compare to mtime stored
   in `$STATE_PATH`. If equal, exit 0 (idempotent skip).
5. Read source via `jq` and compute the output JSON in a single `jq`
   invocation passing `--argjson now "$(date +%s)"`. The `jq` program
   computes both windows, levels, top-level posture, freshness fields.
6. Write to `${BISHOP_OUTPUT_PATH}.tmp.$$`, then `mv` to final path
   (atomic same-filesystem rename).
7. Write source mtime into `$STATE_PATH` (also via tmp+mv).
8. Exit 0.

Override hooks for testing (must be honored by the script): if
`BISHOP_NOW_OVERRIDE` is set, use it instead of `date +%s`; if
`BISHOP_MTIME_OVERRIDE` is set, use it instead of stat'ing source.
Tests rely on these.

#### Single-pass `jq` program (the heart of Bishop)

```jq
def window_seconds(key): if key == "five_hour" then 18000 else 604800 end;

def compute_window(key; now):
  .[key] as $w
  | window_seconds(key) as $ws
  | ($w.used_percentage // 0) as $used
  | ($w.resets_at // 0) as $resets
  | ([0, [($ws - ($resets - now)) / $ws * 100, 100] | min] | max) as $elapsed
  | (if $elapsed < 2 then null
     else ($used / (if $elapsed < 1 then 1 else $elapsed end))
     end) as $pace
  | {
      used_pct: $used,
      elapsed_pct: ($elapsed | . * 10 | round / 10),
      pace: (if $pace == null then null else ($pace * 100 | round / 100) end),
      resets_at: $resets,
      level: (
        if $pace == null then "normal"
        elif key == "five_hour" then
          (if $pace > 1.2 then "conservative"
           elif $pace >= 0.85 then "normal"
           elif $pace >= 0.6 then "elevated"
           else "flush" end)
        else
          (if $pace > 1.1 then "conservative"
           elif $pace >= 0.9 then "normal"
           elif $pace >= 0.7 then "elevated"
           else "flush" end)
        end
      )
    };
```

Compose top-level result (all `$now`, `$source_mtime`, `$stale_seconds`
passed via `--argjson`):

```jq
. as $src
| compute_window("five_hour"; $now) as $fh
| compute_window("seven_day"; $now) as $sd
| (["conservative","normal","elevated","flush"]) as $rank
| (
    [$fh.level, $sd.level]
    | map({l: ., r: ($rank | index(.))})
    | min_by(.r) | .l
  ) as $posture
| {
    ts: ($now | todateiso8601),
    posture: $posture,
    five_hour: $fh,
    seven_day: $sd,
    source_mtime: ($source_mtime | todateiso8601),
    source_age_seconds: ($now - $source_mtime),
    stale_input: ($now - $source_mtime > $stale_seconds)
  }
| if .stale_input then .posture = "normal" else . end
```

`jq`'s `todateiso8601` produces `Z`-suffixed ISO at second precision.
The design spec shows microsecond precision; second precision is
acceptable. Document this in the README.

#### `status` (human-readable)

Read output file. Print one line:
`"<posture> (5h: <level> · 7d: <level> · age <N>s)"`. If file missing
or unparseable, print `"unknown (no posture file)"` to stdout and
exit 0.

#### `status --json`

`cat` the output file. If missing, print an empty JSON object `{}` and
exit 0. Do not refresh — read-only command. Callers needing freshness
should call `--refresh` first.

#### `get <field>`

Use `jq -r ".${field} // empty"` against the output file. Supports
dotted paths (`get five_hour.level`). If file missing or field absent,
print nothing and exit 0.

#### `install-agent` / `uninstall-agent`

`install-agent`: render
`launchd/com.user.bishop.refresh.plist` to
`~/Library/LaunchAgents/com.user.bishop.refresh.plist`, substituting
`__BISHOP_BIN__` (absolute path to `bin/bishop` resolved via
`readlink`/`pwd`) and `__HOME__` (`$HOME`). Then
`launchctl bootout gui/$(id -u)/com.user.bishop.refresh 2>/dev/null
|| true` followed by
`launchctl bootstrap gui/$(id -u) <plist>` for idempotency. Print one
line on success.

`uninstall-agent`: `launchctl bootout` and remove the plist.
Idempotent.

#### `--help`

Print usage block matching the CLI surface in this plan.

### Step 2 — Implement `launchd/com.user.bishop.refresh.plist`

Template with placeholders `__BISHOP_BIN__` and `__HOME__`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.user.bishop.refresh</string>
  <key>ProgramArguments</key>
  <array>
    <string>__BISHOP_BIN__</string>
    <string>--refresh</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key>
  <string>__HOME__/.claude/budget-posture.errors.log</string>
  <key>StandardOutPath</key><string>/dev/null</string>
</dict>
</plist>
```

### Step 3 — Tests (`tests/bishop.bats`)

Bats `setup()` writes a fixture `rate-limits.json` to a `BATS_TMPDIR`
subdir and sets `BISHOP_SOURCE_PATH` and `BISHOP_OUTPUT_PATH` to point
into that tmpdir. Tests override `BISHOP_NOW_OVERRIDE` /
`BISHOP_MTIME_OVERRIDE` to make the math deterministic.

Cases (all 10 from spec):

1. **fresh source writes output** — fixture with current `resets_at`,
   run `bishop --refresh`, assert output file exists and `posture`
   field is one of the four levels.
2. **idempotent on unchanged mtime** — run `--refresh` twice, capture
   output mtime between runs, assert unchanged on second run.
3. **`BISHOP_DISABLED` short-circuits** — set var, delete output file,
   run `--refresh`, assert output file still missing.
4. **stale input flags `stale_input: true`** — fixture mtime older
   than `BISHOP_SOURCE_STALE_SECONDS`, run, assert
   `.stale_input == true` and `.posture == "normal"`.
5. **`get posture` returns level** — assert exit 0 and stdout one of
   the four levels.
6. **`status` includes age** — assert stdout matches the regex
   `^[a-z]+ \(5h: [a-z]+ · 7d: [a-z]+ · age [0-9]+s\)$`.
7. **just-reset window → `normal`** — fixture `resets_at` ≈ now +
   window_seconds (so elapsed < 2%), assert that window's level is
   `normal` regardless of used_percentage.
8. **past `resets_at` → elapsed treated as 100** — fixture
   `resets_at` in the past, assert `elapsed_pct == 100` and pace
   computed against 100.
9. **conservative wins over flush** — fixture where 5h is `flush` and
   7d is `conservative`, assert top-level
   `posture == "conservative"`.
10. **concurrent refreshes don't tear** — spawn two `--refresh &` in
    background, wait, assert output file is valid JSON
    (`jq -e . < output`).

### Step 4 — `scripts/install.sh` and `scripts/doctor.sh`

`install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
PREFIX="${PREFIX:-$HOME/.local/bin}"
mkdir -p "$PREFIX"
ln -sf "$(cd "$(dirname "$0")/.." && pwd)/bin/bishop" "$PREFIX/bishop"
echo "Installed bishop -> $PREFIX/bishop"
```

`doctor.sh`: check `jq`, `flock`, `bats` via `command -v`. Red X for
missing required (`jq`, `flock`), yellow ! for missing advisory
(`bats`). Exit 1 if any required missing.

### Step 5 — `CLAUDE.md` and `README.md`

`CLAUDE.md` (short — mirror Mother's tone):
- layout cheatsheet
- shell conventions (`set -u`, `${VAR:-default}` for any env-var
  reference, bash 3.2 macOS compatibility, atomic writes)
- test command
- "Bishop never crashes — log and exit 0" discipline

`README.md`:
- one-paragraph what-it-is
- install (`scripts/install.sh`)
- "what it produces" with sample output JSON
- posture levels table (copy from this plan)
- env-var table
- consumer examples (one shell, one note about Mother integration)

## Acceptance criteria

- `bin/bishop --refresh` produces a well-formed
  `~/.claude/budget-posture.json` when `~/.mother/rate-limits.json`
  exists. Verify manually with the live source file.
- All 10 bats tests pass: `bats tests/bishop.bats`.
- `bishop --refresh` completes in under 50ms on a warm filesystem
  (verify with `time bishop --refresh` after one warm-up run).
- `bishop --refresh` is safe to run concurrently (test #10 covers).
- `bishop --refresh` writes nothing when `BISHOP_DISABLED` is set.
- `bishop status` and `bishop get posture` both work without
  refreshing.
- `scripts/doctor.sh` exits 0 on a healthy machine (jq + flock
  present).
- `scripts/install.sh` symlinks to `~/.local/bin/bishop` and the
  symlinked binary works.
- `git log` shows the seeded commit (PLAN + scaffolding) plus one or
  more implementation commits with conventional `feat:` / `test:` /
  `docs:` subjects.
- `bishop install-agent` registers the launchd job and
  `launchctl list | grep com.user.bishop` shows it loaded.
  `bishop uninstall-agent` cleanly removes it.

## Out of scope

- **Mother integration.** All Mother-side work is documented below in
  the "Mother integration" section but **must not be implemented in
  this repo**. Mother changes happen in `~/Code/mother/` in a separate
  job.
- **Statusline hook edit.** Same: documented in Mother integration,
  not changed here.
- **Claudia agent edit.** Same.
- **Cross-platform support.** Bishop targets macOS only (uses
  `stat -f %m`, launchd). Linux support can come later; do not add
  `stat -c %Y` fallbacks now.
- **Anything fancier than a single `jq` invocation.** Resist
  refactoring into multiple files; Bishop must stay small.
- **Persisting historical posture.** This is a "now" snapshot tool.
  Time series belong elsewhere.
- **Network calls of any kind.** Bishop is purely local file I/O.

## Mother integration (separate work — do NOT implement here)

These changes belong in `~/Code/mother/` and will be picked up in a
separate Mother repo plan. Recorded here so the consumer contract is
visible alongside Bishop.

### M1 — `mother-run-job`: read posture at spawn time

Before invoking Claude Code, call `bishop --refresh` (best-effort —
ignore failure), then `bishop get posture`. Map posture to a tier
adjustment relative to the resolved tier from
`current_tier`/`suggested_config`:

- `conservative` → clamp to `tier_0` (sonnet/medium); log a one-line
  warning if the resolved tier was higher.
- `normal` → no change.
- `elevated` → bump +1 tier, capped at `tier_2`.
- `flush` → bump +1 tier, capped at `tier_3` (opus/high).

**Failure-escalation interaction:** posture bias applies first, then
`escalation_count` from prior failures applies on top. Escalation
always wins (i.e. escalation can override a downward posture clamp).

Record in the metrics line:
- `posture_at_spawn` (the level)
- `posture_bias_applied` (signed integer or `"clamp"`)

Kill switch: `MOTHER_POSTURE_ENABLED` (default `1`). If set to `0`, or
if `bishop` is not on `PATH`, skip the bias entirely and proceed with
the resolved tier as-is.

### M2 — `mother-run-job`: adherence review uses same bias

When spawning the Archie adherence-review agent for
`adherence_pending` jobs, apply the same posture bias to the
model/effort selection. Same kill switch.

### M3 — Statusline hook fires Bishop

Edit `~/.claude/statusline.sh`. After the existing
`mother_capture_rate_limits "$input"` call, add:

```bash
command -v bishop >/dev/null 2>&1 && bishop --refresh &
```

Fire-and-forget. Bishop's lock + idempotency guards prevent thundering
herd.

### M4 — Claudia reads posture at startup

Edit `~/.claude/agents/claudia.md`. Add startup instruction: read
`~/.claude/budget-posture.json` (or run `bishop status --json`). If
posture is `conservative`, surface it to the user and prefer
sonnet-tier suggestions. If `flush`, freely recommend opus for hard
problems. If `normal`, file missing, or `stale_input: true`, behave as
today.

### M5 — Document the consumer relationship

Update `~/Code/mother/CLAUDE.md` with a section:
- Mother reads `~/.claude/budget-posture.json` (produced by Bishop)
- the `MOTHER_POSTURE_ENABLED` kill switch
- how posture bias interacts with the tier ladder and failure
  escalation (bias first, escalation overrides)

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Greenfield shell tool with single-pass jq math, atomic writes, flock concurrency, launchd integration, and 10 bats tests — multiple subtle correctness paths."
  redd:
    model: sonnet
    effort: high
    rationale: "Test suite is the contract for posture math; boundary cases (just-reset, past resets_at, conservative-wins, concurrent writes) need careful fixtures and time overrides."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard refactor pass — keep bishop a single file, look for duplicated jq fragments or shell idioms."
  perri:
    model: sonnet
    effort: high
    rationale: "Bishop's output drives Mother's routing; a wrong level silently miscalibrates every future job. Reviewer needs to scrutinize the math and degradation paths."
```
