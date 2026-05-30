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

  # Write a default "Cruise" fixture for the Mother-aggregate path
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
  [[ "$posture" == "Pump the brakes" || "$posture" == "Ease up" || \
     "$posture" == "Cruise"   || "$posture" == "Push" || \
     "$posture" == "Put the hammer down"  ]]
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
# 4. Stale input flags stale_input: true and forces posture to "Cruise"
# ---------------------------------------------------------------------------
@test "stale input sets stale_input=true and posture=On pace" {
  # Mtime older than BISHOP_SOURCE_STALE_SECONDS (600)
  export BISHOP_MTIME_OVERRIDE=$((FIXED_NOW - 601))

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  stale="$(jq -r '.stale_input' "$OUTPUT_PATH")"
  posture="$(jq -r '.posture' "$OUTPUT_PATH")"

  [ "$stale" = "true" ]
  [ "$posture" = "Cruise" ]
}

# ---------------------------------------------------------------------------
# 5. get posture returns a valid level
# ---------------------------------------------------------------------------
@test "get posture returns a valid level string" {
  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  run "$BISHOP_BIN" get posture
  [ "$status" -eq 0 ]
  [[ "$output" == "Pump the brakes" || "$output" == "Ease up" || \
     "$output" == "Cruise"   || "$output" == "Push" || \
     "$output" == "Put the hammer down"  ]]
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
  # posture/level strings can contain spaces and mixed case (e.g. "Cruise", "Pump the brakes")
  [[ "$first_line" =~ ^[A-Za-z\ ]+\ \(5h:\ [A-Za-z\ ]+\ ·\ 7d:\ [A-Za-z\ ]+\ ·\ age\ [0-9]+s\)$ ]]
}

# ---------------------------------------------------------------------------
# 7. Just-reset window → elapsed < 2% → level = "Cruise"
# ---------------------------------------------------------------------------
@test "just-reset window: elapsed < 2pct yields level=On pace for that window" {
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

  # When elapsed < 2%, pace=null → level forced to "Cruise"
  [ "$fh_level" = "Cruise" ]
  [ "$sd_level" = "Cruise" ]
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
@test "Pump the brakes beats Full speed: top-level=Pump the brakes" {
  # 5h: flush (used=10, elapsed≈80% → pace=10/80=0.125 < 0.6)
  local fh_resets=$((FIXED_NOW + 3600))    # 14400s into 18000s window → elapsed=80%
  # 7d: Pump the brakes (used=95, elapsed≈70% → pace=95/70=1.357 > 1.3)
  local sd_resets=$((FIXED_NOW + 181440))  # 423360s into 604800s window → elapsed=70%

  cat > "$BISHOP_SOURCE_PATH" <<EOF
{"five_hour":{"used_percentage":10,"resets_at":${fh_resets}},"seven_day":{"used_percentage":95,"resets_at":${sd_resets}}}
EOF

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  fh_level="$(jq -r '.five_hour.level' "$OUTPUT_PATH")"
  sd_level="$(jq -r '.seven_day.level' "$OUTPUT_PATH")"
  posture="$(jq -r '.posture' "$OUTPUT_PATH")"

  [ "$fh_level" = "Put the hammer down" ]
  [ "$sd_level" = "Pump the brakes" ]
  [ "$posture" = "Pump the brakes" ]
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
# (g) OAuth source: posture math works correctly (Pump the brakes beats Full speed)
# ---------------------------------------------------------------------------
@test "OAuth: posture math works with OAuth source format" {
  # Construct an OAuth fixture where:
  #   5h: utilization=10, elapsed≈80% → pace=0.125 → Put the hammer down
  #   7d: utilization=95, elapsed≈70% → pace=1.357 → Pump the brakes (>1.3)
  # Top-level posture must be "Pump the brakes" (worst of the two).
  #
  # FIXED_NOW=1700000000.  We need an ISO timestamp representing specific epochs.
  local fh_resets=$((FIXED_NOW + 3600))    # elapsed≈80%
  local sd_resets=$((FIXED_NOW + 181440))  # elapsed≈70%
  local fh_iso sd_iso
  fh_iso="$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp(${fh_resets}, tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000000+00:00'))")"
  sd_iso="$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp(${sd_resets}, tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000000+00:00'))")"

  local fixture
  fixture="{
  \"five_hour\":        { \"utilization\": 10.0, \"resets_at\": \"${fh_iso}\" },
  \"seven_day\":        { \"utilization\": 95.0, \"resets_at\": \"${sd_iso}\" },
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

  [ "$fh_level" = "Put the hammer down" ]
  [ "$sd_level" = "Pump the brakes" ]
  [ "$posture" = "Pump the brakes" ]
}

# ===========================================================================
# New fields: billing_mode, overage, subscription, projected_exhaustion,
# pace_smoothed (cases h–v, 15 tests)
# ===========================================================================

# ---------------------------------------------------------------------------
# Helper: build an OAuth fixture with specific ISO resets_at for window math
# Params: fh_util fh_resets_epoch sd_util sd_resets_epoch extra_enabled extra_credits
# ---------------------------------------------------------------------------
_oauth_fixture_timed() {
  local fh_util="$1" fh_epoch="$2" sd_util="$3" sd_epoch="$4"
  local extra_enabled="${5:-false}" extra_credits="${6:-0}"
  local fh_iso sd_iso
  fh_iso="$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp(${fh_epoch}, tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000000+00:00'))")"
  sd_iso="$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp(${sd_epoch}, tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000000+00:00'))")"
  cat <<JSON
{
  "five_hour":        { "utilization": ${fh_util}, "resets_at": "${fh_iso}" },
  "seven_day":        { "utilization": ${sd_util}, "resets_at": "${sd_iso}" },
  "seven_day_sonnet": { "utilization": 50.0,        "resets_at": "${sd_iso}" },
  "seven_day_opus":   null,
  "seven_day_haiku":  null,
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
# (h) billing_mode subscription when overage disabled
# ---------------------------------------------------------------------------
@test "billing_mode subscription when overage disabled" {
  _write_mock "$(_oauth_fixture 50.0 null null 12.0 71.0 false 0)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  billing_mode="$(jq -r '.billing_mode' "$OUTPUT_PATH")"
  [ "$billing_mode" = "subscription" ]
}

# ---------------------------------------------------------------------------
# (i) billing_mode metered when overage enabled and credits spent
# ---------------------------------------------------------------------------
@test "billing_mode metered when overage enabled and credits spent" {
  _write_mock "$(_oauth_fixture 50.0 null null 12.0 71.0 true 500)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  billing_mode="$(jq -r '.billing_mode' "$OUTPUT_PATH")"
  [ "$billing_mode" = "metered" ]
}

# ---------------------------------------------------------------------------
# (j) billing_mode subscription when overage enabled but zero credits
# ---------------------------------------------------------------------------
@test "billing_mode subscription when overage enabled but zero credits" {
  _write_mock "$(_oauth_fixture 50.0 null null 12.0 71.0 true 0)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  billing_mode="$(jq -r '.billing_mode' "$OUTPUT_PATH")"
  [ "$billing_mode" = "subscription" ]
}

# ---------------------------------------------------------------------------
# (k) overage block promoted with spent_usd in dollars
# ---------------------------------------------------------------------------
@test "overage block promoted with spent_usd in dollars" {
  # 15650 cents = $156.50
  _write_mock "$(_oauth_fixture 50.0 null null 12.0 71.0 true 15650)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  enabled="$(jq -r '.overage.enabled' "$OUTPUT_PATH")"
  spent_usd="$(jq -r '.overage.spent_usd' "$OUTPUT_PATH")"
  this_session="$(jq -r '.overage.this_session_usd' "$OUTPUT_PATH")"

  [ "$enabled" = "true" ]
  [ "$spent_usd" = "156.5" ]
  [ "$this_session" = "null" ]
}

# ---------------------------------------------------------------------------
# (l) overage block: enabled=false when overage disabled
# ---------------------------------------------------------------------------
@test "overage block null spend when disabled" {
  _write_mock "$(_oauth_fixture 50.0 null null 12.0 71.0 false 0)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  enabled="$(jq -r '.overage.enabled' "$OUTPUT_PATH")"
  [ "$enabled" = "false" ]
}

# ---------------------------------------------------------------------------
# (m) subscription block present with null plan and limits; plus max-plan fixture
# ---------------------------------------------------------------------------
@test "subscription block present with null plan and limits; infers Max 20x" {
  # Standard fixture — no .limit field on windows → plan=null
  _write_mock "$(_oauth_fixture 50.0 null null 12.0 71.0 false 0)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  plan="$(jq -r '.subscription.plan' "$OUTPUT_PATH")"
  fh_limit="$(jq -r '.subscription.limits.five_hour' "$OUTPUT_PATH")"
  [ "$plan" = "null" ]
  [ "$fh_limit" = "null" ]

  # Inline fixture with seven_day.limit: 2000000 → infers "Max 20x"
  # Clear OAuth cache so bishop re-fetches from the new mock (FIXED_NOW makes
  # cache_age negative, so the old cache would otherwise appear "fresh").
  rm -f "$CACHE_PATH"
  local max_fixture
  max_fixture='{
    "five_hour":        { "utilization": 50.0, "resets_at": "'"$OAUTH_RESETS_FUTURE"'", "limit": null },
    "seven_day":        { "utilization": 50.0, "resets_at": "'"$OAUTH_RESETS_FUTURE"'", "limit": 2000000 },
    "seven_day_sonnet": { "utilization": 50.0, "resets_at": "'"$OAUTH_RESETS_FUTURE"'" },
    "seven_day_opus":   null,
    "seven_day_haiku":  null,
    "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": 0, "utilization": null, "currency": "USD" }
  }'
  _write_mock "$max_fixture"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  plan="$(jq -r '.subscription.plan' "$OUTPUT_PATH")"
  sd_limit="$(jq -r '.subscription.limits.seven_day' "$OUTPUT_PATH")"
  [ "$plan" = "Max 20x" ]
  [ "$sd_limit" = "2000000" ]
}

# ---------------------------------------------------------------------------
# (n) projected_exhaustion null when pace is sustainable (ee >= resets)
# ---------------------------------------------------------------------------
@test "projected_exhaustion null when pace sustainable" {
  # fh: used=10, elapsed=50% → pace=0.2 (sustainable) → ee far past resets → null
  local fh_resets=$((FIXED_NOW + 9000))   # halfway through 18000s window
  local sd_resets=$((FIXED_NOW + 302400)) # halfway through 604800s window
  _write_mock "$(_oauth_fixture_timed 10.0 "$fh_resets" 10.0 "$sd_resets" false 0)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  pe="$(jq -r '.five_hour.projected_exhaustion' "$OUTPUT_PATH")"
  [ "$pe" = "null" ]
}

# ---------------------------------------------------------------------------
# (o) projected_exhaustion ISO timestamp when over-pace
# ---------------------------------------------------------------------------
@test "projected_exhaustion ISO timestamp when over-pace" {
  # fh: used=80, elapsed=50% → pace=1.6 → ee = now + 9000*(20/80) = now+2250 < resets
  local fh_resets=$((FIXED_NOW + 9000))
  local sd_resets=$((FIXED_NOW + 302400))
  _write_mock "$(_oauth_fixture_timed 80.0 "$fh_resets" 50.0 "$sd_resets" false 0)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  pe="$(jq -r '.five_hour.projected_exhaustion' "$OUTPUT_PATH")"
  [ "$pe" != "null" ]
  [[ "$pe" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

# ---------------------------------------------------------------------------
# (p) projected_exhaustion null when utilization=100 (already exhausted)
# ---------------------------------------------------------------------------
@test "projected_exhaustion null when already exhausted" {
  local fh_resets=$((FIXED_NOW + 9000))
  local sd_resets=$((FIXED_NOW + 302400))
  _write_mock "$(_oauth_fixture_timed 100.0 "$fh_resets" 50.0 "$sd_resets" false 0)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  pe="$(jq -r '.five_hour.projected_exhaustion' "$OUTPUT_PATH")"
  [ "$pe" = "null" ]
}

# ---------------------------------------------------------------------------
# (q) pace_smoothed null on first refresh (no history); history file created
# ---------------------------------------------------------------------------
@test "pace_smoothed null on first refresh; history file created" {
  _write_mock "$(_oauth_fixture 50.0 null null 12.0 71.0 false 0)"
  export BISHOP_PACE_SMOOTH_WINDOW_SECONDS=2700
  export BISHOP_PACE_SMOOTH_MIN_SAMPLES=3

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  # With pace=null (elapsed=0%), and no history → 0 samples < smooth_min=3 → null
  smoothed="$(jq -r '.five_hour.pace_smoothed' "$OUTPUT_PATH")"
  [ "$smoothed" = "null" ]

  # History file must be created with at least 1 sample
  local hist_path="${OUTPUT_PATH}.pace-history.json"
  [ -f "$hist_path" ]
  sample_count="$(jq 'length' "$hist_path")"
  [ "$sample_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# (r) pace_smoothed populated after enough history samples
# ---------------------------------------------------------------------------
@test "pace_smoothed populated after enough history samples" {
  _write_mock "$(_oauth_fixture 50.0 null null 12.0 71.0 false 0)"
  export BISHOP_PACE_SMOOTH_WINDOW_SECONDS=2700
  export BISHOP_PACE_SMOOTH_MIN_SAMPLES=3

  # Pre-seed 3 in-horizon samples (each within 2700s of FIXED_NOW)
  local hist_path="${OUTPUT_PATH}.pace-history.json"
  printf '%s\n' '[
    {"ts":'"$((FIXED_NOW - 100))"',"fh":0.5,"sd":0.7},
    {"ts":'"$((FIXED_NOW - 200))"',"fh":0.6,"sd":0.8},
    {"ts":'"$((FIXED_NOW - 300))"',"fh":0.4,"sd":0.6}
  ]' > "$hist_path"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  # 3 historical fh samples (current pace=null, elapsed=0%); 3 >= smooth_min=3 → smoothed
  smoothed="$(jq -r '.five_hour.pace_smoothed' "$OUTPUT_PATH")"
  [ "$smoothed" != "null" ]
}

# ---------------------------------------------------------------------------
# (s) pace_smoothed ignores stale samples (outside smooth window)
# ---------------------------------------------------------------------------
@test "pace_smoothed ignores stale samples outside smooth window" {
  _write_mock "$(_oauth_fixture 50.0 null null 12.0 71.0 false 0)"
  export BISHOP_PACE_SMOOTH_WINDOW_SECONDS=2700
  export BISHOP_PACE_SMOOTH_MIN_SAMPLES=3

  # Pre-seed 3 samples all older than 2700s
  local hist_path="${OUTPUT_PATH}.pace-history.json"
  printf '%s\n' '[
    {"ts":'"$((FIXED_NOW - 3000))"',"fh":0.5,"sd":0.7},
    {"ts":'"$((FIXED_NOW - 3100))"',"fh":0.6,"sd":0.8},
    {"ts":'"$((FIXED_NOW - 3200))"',"fh":0.4,"sd":0.6}
  ]' > "$hist_path"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  # All historical samples stale; current pace=null (elapsed=0%) → 0 valid samples → null
  smoothed="$(jq -r '.five_hour.pace_smoothed' "$OUTPUT_PATH")"
  [ "$smoothed" = "null" ]
}

# ---------------------------------------------------------------------------
# (t) smoothed pace drives posture level (not raw pace)
# ---------------------------------------------------------------------------
@test "smoothed pace drives posture level when history present" {
  # Standard fixture: elapsed=0% → raw pace=null → raw level="Cruise"
  _write_mock "$(_oauth_fixture 50.0 null null 12.0 71.0 false 0)"
  export BISHOP_PACE_SMOOTH_WINDOW_SECONDS=2700
  export BISHOP_PACE_SMOOTH_MIN_SAMPLES=3

  # Seed 3 samples: fh=1.5 (>1.4 → 5h "Pump the brakes"), sd=1.5 (>1.3 → 7d "Pump the brakes")
  local hist_path="${OUTPUT_PATH}.pace-history.json"
  printf '%s\n' '[
    {"ts":'"$((FIXED_NOW - 100))"',"fh":1.5,"sd":1.5},
    {"ts":'"$((FIXED_NOW - 200))"',"fh":1.5,"sd":1.5},
    {"ts":'"$((FIXED_NOW - 300))"',"fh":1.5,"sd":1.5}
  ]' > "$hist_path"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  # Smoothed fh=1.5 → level_for("five_hour",1.5)="Pump the brakes"; dominates raw "Cruise"
  posture="$(jq -r '.posture' "$OUTPUT_PATH")"
  [ "$posture" = "Pump the brakes" ]
}

# ---------------------------------------------------------------------------
# (u) Mother-fallback shape: new fields present with correct defaults
# ---------------------------------------------------------------------------
@test "Mother-fallback shape has billing_mode, overage, subscription, pace_smoothed" {
  # Default setup: no fetch cmd, no cache → Mother aggregate path
  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_PATH" ]

  source="$(jq -r '.source' "$OUTPUT_PATH")"
  [ "$source" = "mother_aggregate" ]

  billing_mode="$(jq -r '.billing_mode' "$OUTPUT_PATH")"
  [ "$billing_mode" = "subscription" ]

  overage_enabled="$(jq -r '.overage.enabled' "$OUTPUT_PATH")"
  [ "$overage_enabled" = "false" ]

  plan="$(jq -r '.subscription.plan' "$OUTPUT_PATH")"
  [ "$plan" = "null" ]

  fh_smoothed="$(jq -r '.five_hour.pace_smoothed' "$OUTPUT_PATH")"
  [ "$fh_smoothed" = "null" ]

  sd_smoothed="$(jq -r '.seven_day.pace_smoothed' "$OUTPUT_PATH")"
  [ "$sd_smoothed" = "null" ]
}

# ---------------------------------------------------------------------------
# (v) backward-compat: extra_usage block still present and unchanged on OAuth path
# ---------------------------------------------------------------------------
@test "backward-compat: extra_usage block preserved on OAuth path" {
  _write_mock "$(_oauth_fixture 100.0 null null 12.0 71.0 true 15650)"

  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  source="$(jq -r '.source' "$OUTPUT_PATH")"
  [ "$source" = "oauth_usage" ]

  is_enabled="$(jq -r '.extra_usage.is_enabled' "$OUTPUT_PATH")"
  used_credits="$(jq -r '.extra_usage.used_credits' "$OUTPUT_PATH")"

  [ "$is_enabled" = "true" ]
  [ "$used_credits" = "15650" ]
}
