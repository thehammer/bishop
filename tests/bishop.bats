#!/usr/bin/env bats
# bishop.bats — unit tests for bin/bishop
#
# Requires: bats-core, jq
# Run: bats tests/bishop.bats

BISHOP_BIN="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/bin/bishop"

# Fixed epoch used across tests for deterministic math
FIXED_NOW=1700000000

# Halfway through the 5h window: elapsed ≈ 50%, resets_at = now + 9000
FIVE_HOUR_RESETS_HALF=$((FIXED_NOW + 9000))
# Halfway through the 7d window: elapsed ≈ 50%, resets_at = now + 302400
SEVEN_DAY_RESETS_HALF=$((FIXED_NOW + 302400))

setup() {
  # Fresh tmpdir per test
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR}/bishop.XXXXXX")"

  SOURCE_PATH="${TEST_DIR}/rate-limits.json"
  OUTPUT_PATH="${TEST_DIR}/budget-posture.json"

  # Write a default "normal" fixture
  cat > "$SOURCE_PATH" <<EOF
{"five_hour":{"used_percentage":50,"resets_at":${FIVE_HOUR_RESETS_HALF}},"seven_day":{"used_percentage":50,"resets_at":${SEVEN_DAY_RESETS_HALF}}}
EOF

  export BISHOP_SOURCE_PATH="$SOURCE_PATH"
  export BISHOP_OUTPUT_PATH="$OUTPUT_PATH"
  export BISHOP_SOURCE_STALE_SECONDS=600
  export BISHOP_NOW_OVERRIDE=$FIXED_NOW
  export BISHOP_MTIME_OVERRIDE=$((FIXED_NOW - 30))
  unset BISHOP_DISABLED
}

teardown() {
  rm -rf "$TEST_DIR"
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
# 6. status includes age in expected format
# ---------------------------------------------------------------------------
@test "status outputs expected human-readable format" {
  run "$BISHOP_BIN" --refresh
  [ "$status" -eq 0 ]

  run "$BISHOP_BIN" status
  [ "$status" -eq 0 ]
  # Pattern: "posture (5h: level · 7d: level · age Ns)"
  [[ "$output" =~ ^[a-z]+\ \(5h:\ [a-z]+\ ·\ 7d:\ [a-z]+\ ·\ age\ [0-9]+s\)$ ]]
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
