# Bishop

Bishop is a small macOS shell tool that turns Claude Code's rolling rate-limit
data into a single, machine-readable JSON snapshot — the *budget posture* —
that any consumer (Mother, Claudia, scripts) can read in one syscall.

Named after the synthetic from *Aliens*, the same franchise as Mother. Bishop
is not an agent; it is a non-interactive CLI and an optional launchd heartbeat.
It never crashes, never blocks, and degrades silently to `posture: normal` when
input is missing.

## Install

```bash
bash scripts/install.sh        # symlinks bin/bishop to ~/.local/bin/bishop
bishop install-agent           # loads the launchd job (runs every 60s)
```

Verify dependencies:

```bash
bash scripts/doctor.sh
```

Required: `jq`, `flock` (`brew install jq flock`). Optional for tests: `bats`
(`brew install bats-core`).

## What it produces

`bishop --refresh` reads `~/.mother/rate-limits.json` and writes
`~/.claude/budget-posture.json`:

```json
{
  "ts": "2024-11-14T22:13:20Z",
  "posture": "normal",
  "five_hour": {
    "used_pct": 50,
    "elapsed_pct": 50.0,
    "pace": 1.0,
    "resets_at": 1700009000,
    "level": "normal"
  },
  "seven_day": {
    "used_pct": 50,
    "elapsed_pct": 50.0,
    "pace": 1.0,
    "resets_at": 1700302400,
    "level": "normal"
  },
  "source_mtime": "2024-11-14T22:12:50Z",
  "source_age_seconds": 30,
  "stale_input": false
}
```

> **Note:** timestamps are second-precision ISO 8601 (`Z`-suffixed), not
> microsecond. This is a `jq` `todateiso8601` constraint.

## Posture levels

| Level          | Meaning                                                       |
|----------------|---------------------------------------------------------------|
| `conservative` | Pace exceeds budget. Use cheaper models; avoid heavy tasks.   |
| `normal`       | On track. No change to model selection.                       |
| `elevated`     | Below expected pace. Some headroom available.                 |
| `flush`        | Well under pace. Budget is ample; expensive models are fine.  |

The top-level `posture` is the *most conservative* level across both windows.
`stale_input: true` (source older than `BISHOP_SOURCE_STALE_SECONDS`) forces
`posture` to `"normal"` as a safe default.

## CLI reference

```
bishop --refresh          Compute posture and write budget-posture.json
bishop status             Human-readable summary
bishop status --json      Raw budget-posture.json to stdout
bishop get <field>        Single field (dot-path: bishop get five_hour.level)
bishop install-agent      Register launchd heartbeat
bishop uninstall-agent    Remove launchd heartbeat
bishop --help             Full usage
```

## Environment variables

| Variable                      | Default                              | Purpose                           |
|-------------------------------|--------------------------------------|-----------------------------------|
| `BISHOP_SOURCE_PATH`          | `~/.mother/rate-limits.json`         | Rate-limits input file            |
| `BISHOP_OUTPUT_PATH`          | `~/.claude/budget-posture.json`      | Posture output file               |
| `BISHOP_SOURCE_STALE_SECONDS` | `600`                                | Age threshold for stale input     |
| `BISHOP_DISABLED`             | (unset)                              | Set to any value to skip refresh  |
| `BISHOP_NOW_OVERRIDE`         | (unset)                              | Override current epoch (testing)  |
| `BISHOP_MTIME_OVERRIDE`       | (unset)                              | Override source mtime (testing)   |

## Consumer examples

**Shell:**
```bash
bishop --refresh
posture="$(bishop get posture)"
echo "Current posture: $posture"
```

**Mother integration (separate repo):**  
Mother reads `~/.claude/budget-posture.json` at job spawn time to bias
model/effort selection. See `docs/PLAN.md` §"Mother integration" for the
full contract. The kill switch is `MOTHER_POSTURE_ENABLED=0`.

## Run tests

```bash
bats tests/bishop.bats
```
