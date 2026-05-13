# Bishop

Bishop is a small macOS shell tool that turns Claude Code budget data into a
single, machine-readable JSON snapshot — the *budget posture* — that any
consumer (Mother, Claudia, scripts) can read in one syscall.

Named after the synthetic from *Aliens*, the same franchise as Mother. Bishop
is not an agent; it is a non-interactive CLI and an optional launchd heartbeat.
It never crashes, never blocks, and degrades silently to `posture: normal` when
input is missing.

## Install

```bash
bash scripts/install.sh        # symlinks bin/bishop + bin/bishop-fetch-usage to ~/.local/bin/
bishop install-agent           # loads the launchd job (runs every 60s)
```

Verify dependencies:

```bash
bash scripts/doctor.sh
```

Required: `jq`, `flock` (`brew install jq flock`). Optional for tests: `bats`
(`brew install bats-core`).

## Data sources

Bishop tries two sources in order, falling back gracefully:

### Primary — Anthropic OAuth `/api/oauth/usage`

`bishop-fetch-usage` pulls proactive per-model utilization from the same
endpoint that powers Claude Code's `/usage` UI:

```
https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <token>
anthropic-beta: oauth-2025-04-20
```

The OAuth token is read from the macOS keychain (service: `Claude Code-credentials`).
**This is macOS only.** On Linux or where the keychain entry is absent, Bishop
falls back to the Mother aggregate source automatically.

Bishop caches the OAuth response for `BISHOP_USAGE_CACHE_TTL_SECONDS` (default
55 seconds — one tick under the 60-second launchd cadence). On HTTP 429
(rate-limited) the previous cached response is preserved and reused; the cache
file is never corrupted by a failed fetch.

### Fallback — Mother aggregate (`~/.mother/rate-limits.json`)

Mother streams Claude Code rate-limit events into this file. It provides
aggregate 5h and 7d utilization but no per-model breakdowns. When Bishop
successfully reads the OAuth endpoint, this file is not consulted for the
main posture computation (but it remains on disk as a backstop).

## What it produces

`bishop --refresh` writes `~/.claude/budget-posture.json`:

```json
{
  "ts": "2024-11-14T22:13:20Z",
  "source": "oauth_usage",
  "posture": "normal",
  "five_hour": {
    "used_pct": 12,
    "elapsed_pct": 50.0,
    "pace": 0.24,
    "resets_at": 1700009000,
    "level": "flush"
  },
  "seven_day": {
    "used_pct": 71,
    "elapsed_pct": 50.0,
    "pace": 1.42,
    "resets_at": 1700302400,
    "level": "conservative"
  },
  "models": {
    "sonnet": { "status": "exhausted", "used_pct": 100, "resets_at": 1700302400 },
    "opus":   null,
    "haiku":  null
  },
  "exhausted_models": ["sonnet"],
  "extra_usage": {
    "is_enabled": true,
    "used_credits": 15650,
    "currency": "USD",
    "monthly_limit": null,
    "utilization": null
  },
  "source_mtime": "2024-11-14T22:12:50Z",
  "source_age_seconds": 30,
  "stale_input": false
}
```

When falling back to the Mother aggregate, `source` is `"mother_aggregate"`,
`models` is `{"sonnet": null, "opus": null, "haiku": null}`, and
`exhausted_models` is `[]`.

> **Note:** timestamps are second-precision ISO 8601 (`Z`-suffixed), not
> microsecond. This is a `jq` `todateiso8601` constraint.

### Per-model fields

| Field | Meaning |
|-------|---------|
| `models.sonnet` | Plan-specific 7-day Sonnet bucket. `null` if plan has no separate Sonnet cap. |
| `models.opus`   | Plan-specific 7-day Opus bucket. `null` if plan has no separate Opus cap. |
| `models.haiku`  | Plan-specific 7-day Haiku bucket. `null` if plan has no separate Haiku cap. |
| `exhausted_models` | Array of model names where `status == "exhausted"`. |
| `extra_usage` | Overage / pay-per-use block. `null` when source is Mother aggregate. |

A model entry is `null` when either: the OAuth response has `seven_day_<name>: null`
(plan doesn't have that bucket), or the bucket's `resets_at` is already in the past
(window already rolled over).

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
bishop status             Human-readable summary (includes per-model line)
bishop status --json      Raw budget-posture.json to stdout
bishop get <field>        Single field (dot-path: bishop get five_hour.level)
                          Examples: bishop get models.sonnet.status
                                    bishop get exhausted_models
bishop install-agent      Register launchd heartbeat
bishop uninstall-agent    Remove launchd heartbeat
bishop --help             Full usage
```

## Environment variables

| Variable                        | Default                              | Purpose                                        |
|---------------------------------|--------------------------------------|------------------------------------------------|
| `BISHOP_SOURCE_PATH`            | `~/.mother/rate-limits.json`         | Mother aggregate fallback input                |
| `BISHOP_OUTPUT_PATH`            | `~/.claude/budget-posture.json`      | Posture output file                            |
| `BISHOP_SOURCE_STALE_SECONDS`   | `600`                                | Age threshold for stale input                  |
| `BISHOP_DISABLED`               | (unset)                              | Set to any value to skip --refresh entirely    |
| `BISHOP_NOW_OVERRIDE`           | (unset)                              | Override current epoch (testing)               |
| `BISHOP_MTIME_OVERRIDE`         | (unset)                              | Override source mtime (testing, legacy path)   |
| `BISHOP_USAGE_FETCH_CMD`        | `<bishop-dir>/bishop-fetch-usage`    | Path to fetch helper                           |
| `BISHOP_USAGE_CACHE_PATH`       | `~/.claude/oauth-usage.json`         | Cached OAuth response                          |
| `BISHOP_USAGE_CACHE_TTL_SECONDS`| `55`                                 | Max cache age before re-fetching               |

## Consumer examples

**Shell:**
```bash
bishop --refresh
posture="$(bishop get posture)"
echo "Current posture: $posture"
echo "Exhausted models: $(bishop get exhausted_models)"
```

**Mother integration (separate repo):**  
Mother reads `~/.claude/budget-posture.json` at job spawn time to bias
model/effort selection. See `docs/PLAN.md` §"Mother integration" for the
full contract. The kill switch is `MOTHER_POSTURE_ENABLED=0`.

## Run tests

```bash
bats tests/bishop.bats
```
