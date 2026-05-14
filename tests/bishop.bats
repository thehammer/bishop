#!/usr/bin/env bats
# bishop.bats — unit tests for bin/bishop
#
# Requires: bats-core, jq
# Run: bats tests/bishop.bats

BISHOP_BIN="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/bin/bishop"
BISHOP_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/bin"

# Fixed epoch used across tests for deterministic math
FIXED_NOW=1700000000

# Halfway through the 5h window: elapsed ≈ 50%, resets_at = now + 9000
FIVE_HOUR_RESETS_HALF=$((FIXED_NOW + 9000))
# Halfway through the 7d window: elapsed ≈ 50%, resets_at = now + 302400
SEVEN_DAY_RESETS_HALF=$((FIXED_NOW + 302400))

# OAuth fixture helpers
# ISO resets_at values with fractional seconds — matching real Anthropic response shape
OAUTH_RESETS_FUTURE="2026-05-15T02:00:00.989763+00:00"
OAUTH_RESETS_PAST="2020-01-01T00:00:00.000000+00:00"

setup() {
  # Fresh tmpdir per test
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR}/bishop.XXXXXX")"

  SOURCE_PATH="${TEST_DIR}/rate-limits.json"
  OUTPUT_PATH="${TEST_DIR}/budget-posture.json"
  CACHE_PATH="${TEST_DIR}/oauth-usage.json"
  # Dummy nonexistent fetch cmd — existing tests force the Mother-aggregate path
  FETCH_DISABLED="${TEST_DIR}/no-such-fetch"

  # Write a default "normal" fixture for the Mother-aggregate path
  cat > "$SOURCE_PATH" <<EOF
{"five_hour":{"used_percentage":50,"resets_at":${FIVE_HOUR_RESETS_HALF}},"seven_day":{"used_percentage":50,"resets_at":${SEVEN_DAY_RESETS_HALF}}}
EOF

  export BISHOP_SOURCE_PATH="$SOURCE_PATH"
  export BISHOP_OUTPUT_PATH="$OUTPUT_PATH"
  export BISHOP_SOURCE_STALE_SECONDS=600
  export BISHOP_NOW_OVERRIDE=$FIXED_NOW
  export BISHOP_MTIME_OVERRIDE=$((FIXED_NOW - 30))
  export BISHOP_USAGE_CACHE_PATH="$CACHE_PATH"
  export BISHOP_USAGE_CACHE_TTL_SECONDS=55
  # Default: OAuth disabled so existing tests always use Mother-aggregate path
  export BISHOP_USAGE_FETCH_CMD="$FETCH_DISABLED"
  unset BISHOP_DISABLED
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Helper: write a mock fetch script to $TEST_DIR/mock-fetch that prints
# fixed OAuth JSON and exits with the given code.
# Usage: _make_fetch_mock <exit_code> <json_file_or_->
# ---------------------------------------------------------------------------
_make_fetch_mock() {
  local exit_code="$1"
  local json_content="$2"
  local script="${TEST_DIR}/mock-fetch"
  cat > "$script" <<SCRIPT
#!/usr/bin/env bash
printf '%s\n' '${json_content}'
exit ${exit_code}
SCRIPT
  chmod +x "$script"
  echo "$script"
}

# ---------------------------------------------------------------------------
# Helper: build a standard OAuth fixture JSON
# Params: sonnet_util opus_util haiku_util fh_util sd_util extra_enabled extra_credits
# ---------------------------------------------------------------------------
_oauth_fixture() {
  local sonnet_util="$1" opus_null="${2:-null}" haiku_null="${3:-null}"
  local fh_util="${4:-12.0}" sd_util="${5:-71.0}"
  local extra_enabled="${6:-false}" extra_credits="${7:-0}"
  local resets="$OAUTH_RESETS_FUTURE"

  cat <<JSON
{
  "five_hour":        { "utilization": ${fh_util},    "resets_at": "${resets}" },
  "seven_day":        { "utilization": ${sd_util},    "resets_at": "${resets}" },
  "seven_day_sonnet": { "utilization": ${sonnet_util}, "resets_at": "${resets}" },
  "seven_day_opus":   ${opus_null},
  "seven_day_haiku":  ${haiku_null},
  "extra_usage": {
    "is_enabled":    ${extra_enabled},
    "monthly_limit": null,
    "used_credits":  ${extra_credits},
    "utilization":   null,
    "currency":      "USD"
  }
}
JSON
}

# ---------------------------------------------------------------------------
# 1. Fresh source writes output
# ---------------------------------------------------------------------------
@test "fresh source writes output with valid posture" {
  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  posture="$(jq -r '.posture' "$OUTPUT_PATH")"
  [[ "$posture" == "conservative" || "$posture" == "normal" || \
     "$posture" == "elevated"     || "$posture" == "flush"  ]]
}

# ---------------------------------------------------------------------------
# 2. Idempotent on unchanged mtime
# ---------------------------------------------------------------------------
@test "idempotent: second --refresh skips write when mtime unchanged" {
  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  output_mtime_1="$(stat -f %m "$OUTPUT_PATH")"

  # Small sleep so filesystem mtime would differ if bishop wrote again
  sleep 1

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  output_mtime_2="$(stat -f %m "$OUTPUT_PATH")"
  [ "$output_mtime_1" -eq "$output_mtime_2" ]
}

# ---------------------------------------------------------------------------
# 3. BISHOP_DISABLED short-circuits
# ---------------------------------------------------------------------------
@test "BISHOP_DISABLED prevents output from being written" {
  export BISHOP_DISABLED=1
  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ ! -f "$OUTPUT_PATH" ]
}

# ---------------------------------------------------------------------------
# 4. Stale input flags stale_input: true and forces posture to "normal"
# ---------------------------------------------------------------------------
@test "stale input sets stale_input=true and posture=normal" {
  # Mtime older than BISHOP_SOURCE_STALE_SECONDS (600)
  export BISHOP_MTIME_OVERRIDE=$((FIXED_NOW - 601))

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  stale="$(jq -r '.stale_input' "$OUTPUT_PATH")"
  posture="$(jq -r '.posture' "$OUTPUT_PATH")"

  [ "$stale" = "true" ]
  [ "$posture" = "normal" ]
}

# ---------------------------------------------------------------------------
# 5. get posture returns a valid level
# ---------------------------------------------------------------------------
@test "get posture returns a valid level string" {
  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  run "$BISHOP_BIN" get posture
  [ "$status" -eq 0 ]
  [[ "$output" == "conservative" || "$output" == "normal" || \
     "$output" == "elevated"     || "$output" == "flush"  ]]
}

# ---------------------------------------------------------------------------
# 6. status includes age in expected format (first line check)
# ---------------------------------------------------------------------------
@test "status outputs expected human-readable format" {
  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  run "$BISHOP_BIN" status
  [ "$status" -eq 0 ]
  # First line: "posture (5h: level · 7d: level · age Ns)"
  first_line="$(printf '%s' "$output" | head -1)"
  [[ "$first_line" =~ ^[a-z]+\ \(5h:\ [a-z]+\ ·\ 7d:\ [a-z]+\ ·\ age\ [0-9]+s\)$ ]]
}

# ---------------------------------------------------------------------------
# 7. Just-reset window → elapsed < 2% → level = "normal"
# ---------------------------------------------------------------------------
@test "just-reset window: elapsed < 2pct yields level=normal for that window" {
  # resets_at very far in future → elapsed ≈ 0% (well below 2%)
  local far_future=$((FIXED_NOW + 17999))  # 1 second into the 5h window
  local far_future_7d=$((FIXED_NOW + 604799))  # 1 second into the 7d window

  cat > "$BISHOP_SOURCE_PATH" <<EOF
{"five_hour":{"used_percentage":99,"resets_at":${far_future}},"seven_day":{"used_percentage":99,"resets_at":${far_future_7d}}}
EOF

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  fh_level="$(jq -r '.five_hour.level' "$OUTPUT_PATH")"
  sd_level="$(jq -r '.seven_day.level' "$OUTPUT_PATH")"

  # When elapsed < 2%, pace=null → level forced to "normal"
  [ "$fh_level" = "normal" ]
  [ "$sd_level" = "normal" ]
}

# ---------------------------------------------------------------------------
# 8. Past resets_at → elapsed treated as 100
# ---------------------------------------------------------------------------
@test "past resets_at: elapsed_pct clamped to 100" {
  # resets_at 1 second in the past → elapsed > 100, clamped to 100
  local past=$((FIXED_NOW - 1))
  cat > "$BISHOP_SOURCE_PATH" <<EOF
{"five_hour":{"used_percentage":50,"resets_at":${past}},"seven_day":{"used_percentage":50,"resets_at":${SEVEN_DAY_RESETS_HALF}}}
EOF

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  elapsed="$(jq -r '.five_hour.elapsed_pct' "$OUTPUT_PATH")"
  # Should be 100 (clamped)
  [ "$elapsed" = "100" ]
}

# ---------------------------------------------------------------------------
# 9. Conservative wins over flush (most urgent posture wins)
# ---------------------------------------------------------------------------
@test "conservative posture beats flush: top-level=conservative" {
  # 5h: flush (used=10, elapsed≈80% → pace=10/80=0.125 < 0.6)
  local fh_resets=$((FIXED_NOW + 3600))    # 14400s into 18000s window → elapsed=80%
  # 7d: conservative (used=90, elapsed≈70% → pace=90/70=1.286 > 1.1)
  local sd_resets=$((FIXED_NOW + 181440))  # 423360s into 604800s window → elapsed=70%

  cat > "$BISHOP_SOURCE_PATH" <<EOF
{"five_hour":{"used_percentage":10,"resets_at":${fh_resets}},"seven_day":{"used_percentage":90,"resets_at":${sd_resets}}}
EOF

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  fh_level="$(jq -r '.five_hour.level' "$OUTPUT_PATH")"
  sd_level="$(jq -r '.seven_day.level' "$OUTPUT_PATH")"
  posture="$(jq -r '.posture' "$OUTPUT_PATH")"

  [ "$fh_level" = "flush" ]
  [ "$sd_level" = "conservative" ]
  [ "$posture" = "conservative" ]
}

# ---------------------------------------------------------------------------
# 10. Concurrent refreshes produce valid JSON (no torn writes)
# ---------------------------------------------------------------------------
@test "concurrent refreshes don't tear the output file" {
  # Use different mtime overrides so both instances think work needs to be done
  # (first one wins the lock; second one exits 0 without writing)
  BISHOP_MTIME_OVERRIDE=$((FIXED_NOW - 30)) "$BISHOP_BIN" --refresh &
  pid1=$!
  BISHOP_MTIME_OVERRIDE=$((FIXED_NOW - 29)) "$BISHOP_BIN" --refresh &
  pid2=$!
  wait "$pid1"
  wait "$pid2"

  # Output must exist and be valid JSON
  [ -f "$OUTPUT_PATH" ]
  run jq -e . "$OUTPUT_PATH"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# OAuth-path tests (cases a–g)
# ===========================================================================

# ---------------------------------------------------------------------------
# Helper: write a fixture JSON to a file and wire BISHOP_USAGE_FETCH_CMD
# to a mock script that cats that file and exits with the given code.
# Usage: _write_mock <json_string> [exit_code=0]
# Side-effect: exports BISHOP_USAGE_FETCH_CMD to the mock path.
# ---------------------------------------------------------------------------
_write_mock() {
  local json="$1"
  local exit_code="${2:-0}"
  local fixture_file="$TEST_DIR/oauth-fixture.json"
  local mock="$TEST_DIR/mock-fetch"
  printf '%s\n' "$json" > "$fixture_file"
  {
    printf '#!/usr/bin/env bash\n'
    printf "cat '%s'\n" "$fixture_file"
    printf "exit %d\n" "$exit_code"
  } > "$mock"
  chmod +x "$mock"
  export BISHOP_USAGE_FETCH_CMD="$mock"
}

# ---------------------------------------------------------------------------
# (a) Fresh OAuth fetch: sonnet at 100% → exhausted, source == "oauth_usage"
# ---------------------------------------------------------------------------
@test "OAuth: sonnet at 100pct is exhausted; source=oauth_usage" {
  _write_mock "$(_oauth_fixture 100.0 null null 12.0 71.0 false 0)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  source="$(jq -r '.source' "$OUTPUT_PATH")"
  [ "$source" = "oauth_usage" ]

  sonnet_status="$(jq -r '.models.sonnet.status' "$OUTPUT_PATH")"
  [ "$sonnet_status" = "exhausted" ]

  exhausted="$(jq -c '.exhausted_models' "$OUTPUT_PATH")"
  [ "$exhausted" = '["sonnet"]' ]
}

# ---------------------------------------------------------------------------
# (b) seven_day_opus: null → models.opus == null, not in exhausted_models
# ---------------------------------------------------------------------------
@test "OAuth: null opus bucket yields models.opus=null and not exhausted" {
  _write_mock "$(_oauth_fixture 50.0 null null 12.0 71.0 false 0)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  source="$(jq -r '.source' "$OUTPUT_PATH")"
  [ "$source" = "oauth_usage" ]

  opus="$(jq -r '.models.opus' "$OUTPUT_PATH")"
  [ "$opus" = "null" ]

  exhausted="$(jq -c '.exhausted_models' "$OUTPUT_PATH")"
  [[ "$exhausted" != *opus* ]]
}

# ---------------------------------------------------------------------------
# (c) extra_usage.is_enabled=true, used_credits=15650 → block preserved
# ---------------------------------------------------------------------------
@test "OAuth: extra_usage block is forwarded into posture output" {
  _write_mock "$(_oauth_fixture 100.0 null null 12.0 71.0 true 15650)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  source="$(jq -r '.source' "$OUTPUT_PATH")"
  [ "$source" = "oauth_usage" ]

  is_enabled="$(jq -r '.extra_usage.is_enabled' "$OUTPUT_PATH")"
  [ "$is_enabled" = "true" ]

  used_credits="$(jq -r '.extra_usage.used_credits' "$OUTPUT_PATH")"
  [ "$used_credits" = "15650" ]

  currency="$(jq -r '.extra_usage.currency' "$OUTPUT_PATH")"
  [ "$currency" = "USD" ]
}

# ---------------------------------------------------------------------------
# (d) Stale cache (age > TTL AND age > STALE_SECONDS) + fetch exits 1
#     → stale cache used, stale_input=true, log warning
# ---------------------------------------------------------------------------
@test "OAuth: stale cache used when fetch fails; stale_input=true" {
  # Write a valid cache file directly (not via _write_mock, which targets fixture.json)
  printf '%s\n' "$(_oauth_fixture 50.0 null null 12.0 50.0 false 0)" > "$CACHE_PATH"

  # Set its mtime to FIXED_NOW - 700 (older than STALE_SECONDS=600)
  python3 -c "import os; os.utime('$CACHE_PATH', (${FIXED_NOW} - 700, ${FIXED_NOW} - 700))"

  # Fetch script that always fails (not rate-limited, generic error)
  local fail_mock="$TEST_DIR/fail-fetch"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fail_mock"
  chmod +x "$fail_mock"
  export BISHOP_USAGE_FETCH_CMD="$fail_mock"
  # TTL=55 < 700 → cache not fresh → attempt fetch → fails → use stale cache
  export BISHOP_USAGE_CACHE_TTL_SECONDS=55

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  source="$(jq -r '.source' "$OUTPUT_PATH")"
  [ "$source" = "oauth_usage" ]

  stale="$(jq -r '.stale_input' "$OUTPUT_PATH")"
  [ "$stale" = "true" ]
}

# ---------------------------------------------------------------------------
# (e) No fetch script + no cache file → Mother aggregate fallback
# ---------------------------------------------------------------------------
@test "OAuth: no fetch cmd + no cache falls back to mother_aggregate" {
  # BISHOP_USAGE_FETCH_CMD points to nonexistent path (set in setup)
  # No cache file either (CACHE_PATH doesn't exist in a fresh TEST_DIR)

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  source="$(jq -r '.source' "$OUTPUT_PATH")"
  [ "$source" = "mother_aggregate" ]

  # models must be null for all three
  sonnet="$(jq -r '.models.sonnet' "$OUTPUT_PATH")"
  opus="$(jq -r '.models.opus' "$OUTPUT_PATH")"
  haiku="$(jq -r '.models.haiku' "$OUTPUT_PATH")"
  [ "$sonnet" = "null" ]
  [ "$opus"   = "null" ]
  [ "$haiku"  = "null" ]

  exhausted="$(jq -c '.exhausted_models' "$OUTPUT_PATH")"
  [ "$exhausted" = "[]" ]
}

# ---------------------------------------------------------------------------
# (f) resets_at in the past → model entry is null (stale-bucket guard)
# ---------------------------------------------------------------------------
@test "OAuth: past resets_at in model bucket yields models.<name>=null" {
  # Build a fixture where seven_day_sonnet resets_at is in the far past
  local past_fixture
  past_fixture="{
  \"five_hour\":        { \"utilization\": 50.0, \"resets_at\": \"${OAUTH_RESETS_FUTURE}\" },
  \"seven_day\":        { \"utilization\": 50.0, \"resets_at\": \"${OAUTH_RESETS_FUTURE}\" },
  \"seven_day_sonnet\": { \"utilization\": 80.0, \"resets_at\": \"${OAUTH_RESETS_PAST}\" },
  \"seven_day_opus\":   null,
  \"seven_day_haiku\":  null,
  \"extra_usage\": { \"is_enabled\": false, \"monthly_limit\": null, \"used_credits\": 0, \"utilization\": null, \"currency\": \"USD\" }
}"
  _write_mock "$past_fixture"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  source="$(jq -r '.source' "$OUTPUT_PATH")"
  [ "$source" = "oauth_usage" ]

  sonnet="$(jq -r '.models.sonnet' "$OUTPUT_PATH")"
  [ "$sonnet" = "null" ]

  exhausted="$(jq -c '.exhausted_models' "$OUTPUT_PATH")"
  [[ "$exhausted" != *sonnet* ]]
}

# ---------------------------------------------------------------------------
# (g) OAuth source: posture math works correctly (conservative beats flush)
# ---------------------------------------------------------------------------
@test "OAuth: posture math works with OAuth source format" {
  # Construct an OAuth fixture where:
  #   5h: utilization=10, resets_at far out → pace is low → flush
  #   7d: utilization=90, resets_at closer   → pace is high → conservative
  # Top-level posture must be conservative.
  #
  # FIXED_NOW=1700000000.  We need an ISO timestamp representing specific epochs.
  local fh_resets=$((FIXED_NOW + 3600))    # elapsed≈80% → flush
  local sd_resets=$((FIXED_NOW + 181440))  # elapsed≈70% → conservative
  local fh_iso sd_iso
  fh_iso="$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp(${fh_resets}, tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000000+00:00'))")"
  sd_iso="$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp(${sd_resets}, tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000000+00:00'))")"

  local fixture
  fixture="{
  \"five_hour\":        { \"utilization\": 10.0, \"resets_at\": \"${fh_iso}\" },
  \"seven_day\":        { \"utilization\": 90.0, \"resets_at\": \"${sd_iso}\" },
  \"seven_day_sonnet\": { \"utilization\": 50.0, \"resets_at\": \"${sd_iso}\" },
  \"seven_day_opus\":   null,
  \"seven_day_haiku\":  null,
  \"extra_usage\": { \"is_enabled\": false, \"monthly_limit\": null, \"used_credits\": 0, \"utilization\": null, \"currency\": \"USD\" }
}"
  _write_mock "$fixture"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  source="$(jq -r '.source' "$OUTPUT_PATH")"
  [ "$source" = "oauth_usage" ]

  fh_level="$(jq -r '.five_hour.level' "$OUTPUT_PATH")"
  sd_level="$(jq -r '.seven_day.level' "$OUTPUT_PATH")"
  posture="$(jq -r '.posture' "$OUTPUT_PATH")"

  [ "$fh_level" = "flush" ]
  [ "$sd_level" = "conservative" ]
  [ "$posture" = "conservative" ]
}
