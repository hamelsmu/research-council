#!/usr/bin/env bash
# Unit tests for the DRY refactoring changes:
#   1. iteration-hook.sh (unified claude/gemini hook)
#   2. lib/phase-common.sh (shared wait infrastructure)
#   3. sedi() helper in orchestrator-stop-hook.sh
#   4. No stale references to old hook scripts

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
TESTS=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TESTS=$((TESTS + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: ${label}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ${label}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TESTS=$((TESTS + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo "  PASS: ${label}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ${label}"
    echo "    expected to contain: ${needle}"
    echo "    actual: ${haystack}"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  TESTS=$((TESTS + 1))
  if ! echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo "  PASS: ${label}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ${label}"
    echo "    expected NOT to contain: ${needle}"
  fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Helper: run iteration hook with env vars properly exported
run_hook() {
  local format="$1" report="$2" state="$3" max_iters="$4"
  (
    export RESEARCH_REPORT_PATH="$report"
    export RESEARCH_STATE_PATH="$state"
    export RESEARCH_MAX_ITERS="$max_iters"
    export RESEARCH_HOOK_FORMAT="$format"
    export RESEARCH_PROGRESS_LOG="/dev/null"
    echo '{}' | bash "${SCRIPT_DIR}/iteration-hook.sh"
  )
}

# ═══════════════════════════════════════════════════════════════════════════
echo "=== Test Group 1: iteration-hook.sh ==="

# Test 1a: Claude format — blocks with "block" decision
echo "1" > "${TMPDIR}/state.txt"
touch "${TMPDIR}/report.md"
OUTPUT=$(run_hook claude "${TMPDIR}/report.md" "${TMPDIR}/state.txt" 5)
assert_contains "claude format uses block decision" '"decision": "block"' "$OUTPUT"
assert_contains "claude format has reason" '"reason":' "$OUTPUT"
assert_eq "claude format increments state" "2" "$(cat "${TMPDIR}/state.txt")"

# Test 1b: Gemini format — blocks with "deny" decision
echo "1" > "${TMPDIR}/state.txt"
touch "${TMPDIR}/report.md"
OUTPUT=$(run_hook gemini "${TMPDIR}/report.md" "${TMPDIR}/state.txt" 5)
assert_contains "gemini format uses deny decision" '"decision": "deny"' "$OUTPUT"

# Test 1c: Completion marker stops the loop (claude)
echo "2" > "${TMPDIR}/state.txt"
echo "Some report content" > "${TMPDIR}/report.md"
echo "<!-- RESEARCH_COMPLETE -->" >> "${TMPDIR}/report.md"
OUTPUT=$(run_hook claude "${TMPDIR}/report.md" "${TMPDIR}/state.txt" 10)
# Claude format: allow = empty output + exit 0
assert_eq "claude allows exit on RESEARCH_COMPLETE" "" "$OUTPUT"

# Test 1d: Completion marker stops the loop (gemini)
echo "2" > "${TMPDIR}/state.txt"
OUTPUT=$(run_hook gemini "${TMPDIR}/report.md" "${TMPDIR}/state.txt" 10)
assert_contains "gemini allows exit on RESEARCH_COMPLETE" '"decision": "allow"' "$OUTPUT"

# Test 1e: Max iterations reached
echo "5" > "${TMPDIR}/state.txt"
echo "no marker here" > "${TMPDIR}/report.md"
OUTPUT=$(run_hook gemini "${TMPDIR}/report.md" "${TMPDIR}/state.txt" 5)
assert_contains "gemini allows exit at max iters" '"decision": "allow"' "$OUTPUT"

# Test 1f: Missing env vars → allow exit
OUTPUT=$(run_hook claude "" "" 5)
assert_eq "claude allows exit when env vars missing" "" "$OUTPUT"

OUTPUT=$(run_hook gemini "" "" 5)
assert_contains "gemini allows exit when env vars missing" '"decision": "allow"' "$OUTPUT"

# Test 1g: Non-numeric state resets to 1
echo "garbage" > "${TMPDIR}/state.txt"
echo "no marker" > "${TMPDIR}/report.md"
OUTPUT=$(run_hook claude "${TMPDIR}/report.md" "${TMPDIR}/state.txt" 5)
assert_contains "non-numeric state resets and blocks" '"decision": "block"' "$OUTPUT"
assert_eq "state reset to 2 (1+1)" "2" "$(cat "${TMPDIR}/state.txt")"

# Test 1h: Iteration counter increments correctly
echo "3" > "${TMPDIR}/state.txt"
echo "no marker" > "${TMPDIR}/report.md"
OUTPUT=$(run_hook claude "${TMPDIR}/report.md" "${TMPDIR}/state.txt" 5)
assert_eq "state incremented from 3 to 4" "4" "$(cat "${TMPDIR}/state.txt")"
assert_contains "systemMessage shows iteration 4/5" "4/5" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Test Group 2: lib/phase-common.sh ==="

# Test 2a: register_agent and agent_pid/agent_log work
(
  WORKSPACE="$TMPDIR"
  PROGRESS_LOG="${TMPDIR}/progress.log"
  PHASE_LABEL="Test"
  touch "$PROGRESS_LOG"
  source "${SCRIPT_DIR}/lib/phase-common.sh"

  # Launch a trivial background process
  sleep 60 &
  PID1=$!
  register_agent "testagent" "$PID1" "/tmp/test.log"

  GOT_PID=$(agent_pid "testagent")
  GOT_LOG=$(agent_log "testagent")

  kill "$PID1" 2>/dev/null
  wait "$PID1" 2>/dev/null || true

  echo "PID=${GOT_PID} LOG=${GOT_LOG} EXPECTED_PID=${PID1}"
) > "${TMPDIR}/reg_output.txt" 2>&1

REG_OUT=$(cat "${TMPDIR}/reg_output.txt")
EXPECTED_PID=$(echo "$REG_OUT" | sed -n 's/.*EXPECTED_PID=\([0-9]*\).*/\1/p')
GOT_PID=$(echo "$REG_OUT" | sed -n 's/.*PID=\([0-9]*\) .*/\1/p')
assert_eq "agent_pid returns correct PID" "$EXPECTED_PID" "$GOT_PID"
assert_contains "agent_log returns log path" "LOG=/tmp/test.log" "$REG_OUT"

# Test 2b: record_pids writes PID file
(
  WORKSPACE="$TMPDIR"
  PROGRESS_LOG="${TMPDIR}/progress.log"
  PHASE_LABEL="Test"
  touch "$PROGRESS_LOG"
  source "${SCRIPT_DIR}/lib/phase-common.sh"

  sleep 60 &
  P1=$!
  sleep 60 &
  P2=$!
  register_agent "a1" "$P1" "/dev/null"
  register_agent "a2" "$P2" "/dev/null"
  record_pids

  kill "$P1" "$P2" 2>/dev/null
  wait "$P1" "$P2" 2>/dev/null || true
) > /dev/null 2>&1

PID_COUNT=$(wc -l < "${TMPDIR}/agent-pids.txt" 2>/dev/null || echo "0")
assert_eq "record_pids writes 2 PIDs" "2" "$(echo "$PID_COUNT" | tr -d ' ')"

# Test 2c: check_log_for_fatal_errors detects quota/auth errors
(
  source "${SCRIPT_DIR}/lib/phase-common.sh" 2>/dev/null
  echo "normal log line" > "${TMPDIR}/clean.log"
  echo "You have exhausted your capacity for this model" > "${TMPDIR}/quota.log"
  echo "Error: API key is invalid" > "${TMPDIR}/auth.log"

  check_log_for_fatal_errors "${TMPDIR}/clean.log" && echo "CLEAN=fatal" || echo "CLEAN=ok"
  check_log_for_fatal_errors "${TMPDIR}/quota.log" && echo "QUOTA=fatal" || echo "QUOTA=ok"
  check_log_for_fatal_errors "${TMPDIR}/auth.log" && echo "AUTH=fatal" || echo "AUTH=ok"
  check_log_for_fatal_errors "${TMPDIR}/nonexistent.log" && echo "MISSING=fatal" || echo "MISSING=ok"
) > "${TMPDIR}/fatal_output.txt" 2>&1

FATAL_OUT=$(cat "${TMPDIR}/fatal_output.txt")
assert_contains "clean log has no fatal errors" "CLEAN=ok" "$FATAL_OUT"
assert_contains "quota error detected as fatal" "QUOTA=fatal" "$FATAL_OUT"
assert_contains "auth error detected as fatal" "AUTH=fatal" "$FATAL_OUT"
assert_contains "missing log is not fatal" "MISSING=ok" "$FATAL_OUT"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Test Group 3: sedi() helper ==="

# Test 3a: sedi replaces in-place
echo "phase: research" > "${TMPDIR}/sedi_test.txt"
echo "other: value" >> "${TMPDIR}/sedi_test.txt"

# Define sedi directly (same as in orchestrator hook)
sedi() { if [[ "$OSTYPE" == "darwin"* ]]; then sed -i '' "$@"; else sed -i "$@"; fi; }

sedi 's/^phase: research$/phase: refinement/' "${TMPDIR}/sedi_test.txt"
RESULT=$(cat "${TMPDIR}/sedi_test.txt")
assert_contains "sedi replaces phase correctly" "phase: refinement" "$RESULT"
assert_contains "sedi preserves other lines" "other: value" "$RESULT"

# Test 3b: sedi with variable substitution
echo "session_id:" > "${TMPDIR}/sedi_test2.txt"
TEST_SESSION="abc-123-def"
sedi "s/^session_id:$/session_id: ${TEST_SESSION}/" "${TMPDIR}/sedi_test2.txt"
RESULT2=$(cat "${TMPDIR}/sedi_test2.txt")
assert_contains "sedi handles variable substitution" "session_id: abc-123-def" "$RESULT2"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Test Group 4: No stale references ==="

# Test 4a: Phase scripts don't reference old hook names
RESEARCH_SCRIPT=$(cat "${SCRIPT_DIR}/run-research-phase.sh")
assert_not_contains "research phase has no claude-stop-hook.sh ref" "claude-stop-hook.sh" "$RESEARCH_SCRIPT"
assert_not_contains "research phase has no gemini-afteragent-hook.sh ref" "gemini-afteragent-hook.sh" "$RESEARCH_SCRIPT"

REFINEMENT_SCRIPT=$(cat "${SCRIPT_DIR}/run-refinement-phase.sh")
assert_not_contains "refinement phase has no claude-stop-hook.sh ref" "claude-stop-hook.sh" "$REFINEMENT_SCRIPT"
assert_not_contains "refinement phase has no gemini-afteragent-hook.sh ref" "gemini-afteragent-hook.sh" "$REFINEMENT_SCRIPT"

# iteration-hook.sh reference now lives in phase-common.sh (via write_claude_settings/write_gemini_settings)
COMMON_LIB=$(cat "${SCRIPT_DIR}/lib/phase-common.sh")
assert_contains "phase-common.sh references iteration-hook.sh" "iteration-hook.sh" "$COMMON_LIB"

# Test 4b: RESEARCH_HOOK_FORMAT is set for both claude and gemini launches
assert_contains "research sets HOOK_FORMAT=claude" "RESEARCH_HOOK_FORMAT=claude" "$RESEARCH_SCRIPT"
assert_contains "research sets HOOK_FORMAT=gemini" "RESEARCH_HOOK_FORMAT=gemini" "$RESEARCH_SCRIPT"
assert_contains "refinement sets HOOK_FORMAT=claude" "RESEARCH_HOOK_FORMAT=claude" "$REFINEMENT_SCRIPT"
assert_contains "refinement sets HOOK_FORMAT=gemini" "RESEARCH_HOOK_FORMAT=gemini" "$REFINEMENT_SCRIPT"

# Test 4c: kill_tree is not defined in phase scripts (removed dead code)
assert_not_contains "research phase has no kill_tree" "kill_tree" "$RESEARCH_SCRIPT"
assert_not_contains "refinement phase has no kill_tree" "kill_tree" "$REFINEMENT_SCRIPT"

# Test 4d: Phase scripts source phase-common.sh
assert_contains "research phase sources phase-common.sh" "phase-common.sh" "$RESEARCH_SCRIPT"
assert_contains "refinement phase sources phase-common.sh" "phase-common.sh" "$REFINEMENT_SCRIPT"

# Test 4e: Orchestrator uses sedi helper, not raw sed -i
ORCH_SCRIPT=$(cat "${PLUGIN_ROOT}/hooks/orchestrator-stop-hook.sh")
# Exclude the sedi() function definition and comments, then check no raw 'sed -i' calls remain
RAW_SED_I=$(echo "$ORCH_SCRIPT" | grep -v '^sedi()' | grep -v '^#' | grep -c 'sed -i' || true)
assert_eq "orchestrator has no raw sed -i calls" "0" "$RAW_SED_I"
# Verify sedi is actually used (at least one call)
SEDI_USAGE=$(echo "$ORCH_SCRIPT" | grep -c 'sedi ' || true)
TESTS=$((TESTS + 1))
if [ "$SEDI_USAGE" -gt 0 ]; then
  PASS=$((PASS + 1))
  echo "  PASS: orchestrator uses sedi helper (${SEDI_USAGE} calls)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: orchestrator has no sedi calls"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Test Group 5: Syntax checks ==="

for script in \
  "${SCRIPT_DIR}/iteration-hook.sh" \
  "${SCRIPT_DIR}/lib/phase-common.sh" \
  "${SCRIPT_DIR}/run-research-phase.sh" \
  "${SCRIPT_DIR}/run-refinement-phase.sh" \
  "${PLUGIN_ROOT}/hooks/orchestrator-stop-hook.sh" \
  "${SCRIPT_DIR}/codex-wrapper.sh" \
  "${SCRIPT_DIR}/run-e2e-test.sh"; do
  TESTS=$((TESTS + 1))
  if bash -n "$script" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: syntax OK — $(basename "$script")"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: syntax error — $(basename "$script")"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Summary ==="
echo "${PASS} passed, ${FAIL} failed, ${TESTS} total"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
