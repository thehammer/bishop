# Bishop — project notes for Claude Code

## Layout

```
bin/bishop                              Main CLI (single executable, no lib split)
launchd/com.user.bishop.refresh.plist   Template — placeholders substituted at install-agent time
tests/bishop.bats                       bats-core unit tests (22 cases)
scripts/install.sh                      Symlink bin/bishop to $PREFIX (~/.local/bin)
scripts/doctor.sh                       Dependency health check
docs/PLAN.md                            Implementation plan (canonical reference)

Runtime files (written by bishop --refresh):
~/.claude/budget-posture.json           Current posture snapshot (polled by consumers)
~/.claude/budget-posture.events.jsonl   Push-threshold events (JSON-lines, edge-triggered)
                                        Rotates to .events.jsonl.1 at 1 MB (BISHOP_EVENTS_MAX_BYTES)
```

## Shell conventions

- `#!/usr/bin/env bash` + `set -euo pipefail` in every script.
- Target bash 3.2 (macOS system bash). No `[[` with regex `=~` against user
  data; no `mapfile`/`readarray`; no associative arrays.
- Reference env vars with `${VAR:-default}` even when a default is set with
  `:=` earlier — belt and suspenders in case `set -u` hits before the default.
- Atomic writes: always write to `${target}.tmp.$$`, then `mv` to final path.
  Never write to the final path directly.
- Acquire `flock -n 9` for concurrent-write safety; degrade gracefully if
  `flock` is not on PATH.

## Bishop never crashes

All error paths route to `_bishop_log_err` and exit 0. The launchd agent and
statusline hook are fire-and-forget — a crash would accumulate in launchd
failure counters and thrash the hook. Log and exit 0, always.

## Test command

```bash
bats tests/bishop.bats
```

## Dependencies

- `jq` (required) — JSON processing
- `flock` (required for safe concurrency; optional for basic operation)
- `bats` (advisory) — running tests

Install on macOS: `brew install jq flock bats-core`
