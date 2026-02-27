#!/usr/bin/env bash
# Phase 1: Launch 3 research agents in parallel and wait for all to complete
#
# Usage: run-research-phase.sh <research_id> <topic> <max_iters> \
#          <claude_model> <codex_model> <codex_reasoning> <gemini_model>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(pwd)"

RESEARCH_ID="$1"
TOPIC="$2"
MAX_ITERS="$3"
CLAUDE_MODEL="$4"
CODEX_MODEL="$5"
CODEX_REASONING="$6"
GEMINI_MODEL="$7"

WORKSPACE="${PROJECT_DIR}/research/${RESEARCH_ID}"
mkdir -p "$WORKSPACE"
WORKSPACE="$(cd "$WORKSPACE" && pwd)"
PROGRESS_LOG="${WORKSPACE}/progress.log"
PHASE_LABEL="Phase 1"

# shellcheck source=lib/phase-common.sh
source "${SCRIPT_DIR}/lib/phase-common.sh"

log "Phase 1: Starting initial research"
log "  Topic: ${TOPIC}"
log "  Max iterations: ${MAX_ITERS}"
log "  Claude: ${CLAUDE_MODEL} | Codex: ${CODEX_MODEL} (${CODEX_REASONING}) | Gemini: ${GEMINI_MODEL}"

# ── Prompt file (shared base, customized per agent) ───────────────────────
RESEARCH_PROMPT="$(cat "${PLUGIN_ROOT}/prompts/research-system.md")

## Your Research Topic

${TOPIC}

## Output

Write your report to the file path specified below. Create or overwrite the file with your full report."

# ── Launch Claude subagent ────────────────────────────────────────────────
CLAUDE_REPORT="${WORKSPACE}/claude-report.md"
CLAUDE_STATE="${WORKSPACE}/claude-state.txt"
CLAUDE_SETTINGS="${WORKSPACE}/claude-settings.json"

echo "1" > "$CLAUDE_STATE"

write_claude_settings "$CLAUDE_SETTINGS" "$PLUGIN_ROOT"

CLAUDE_EFFORT_FLAG=""
if [ "${RESEARCH_TEST_MODE:-false}" = "true" ]; then
  CLAUDE_EFFORT_FLAG="--effort low"
fi

log "Phase 1: Launching Claude agent (${CLAUDE_MODEL}${CLAUDE_EFFORT_FLAG:+ effort=low})"

(
  RESEARCH_REPORT_PATH="$CLAUDE_REPORT" \
  RESEARCH_STATE_PATH="$CLAUDE_STATE" \
  RESEARCH_MAX_ITERS="$MAX_ITERS" \
  RESEARCH_HOOK_FORMAT=claude \
  env -u CLAUDECODE claude -p \
    --model "$CLAUDE_MODEL" \
    $CLAUDE_EFFORT_FLAG \
    --dangerously-skip-permissions \
    --settings "$CLAUDE_SETTINGS" \
    --max-turns 200 \
    "${RESEARCH_PROMPT}

Write your report to: ${CLAUDE_REPORT}" > "${WORKSPACE}/claude-stdout.log" 2>&1
  rc=$?
  log "Phase 1: Claude agent finished (exit $rc)"
  exit $rc
) &
CLAUDE_PID=$!

# ── Launch Codex subagent ─────────────────────────────────────────────────
CODEX_REPORT="${WORKSPACE}/codex-report.md"

log "Phase 1: Launching Codex agent (${CODEX_MODEL}, reasoning: ${CODEX_REASONING})"

CODEX_PROMPT="${RESEARCH_PROMPT}

Write your report to: ${CODEX_REPORT}"

(
  cd "$PROJECT_DIR"
  bash "${PLUGIN_ROOT}/scripts/codex-wrapper.sh" \
    "$CODEX_PROMPT" \
    "$CODEX_REPORT" \
    "$MAX_ITERS" \
    "$CODEX_MODEL" \
    "$CODEX_REASONING" \
    "$PROGRESS_LOG" \
    "$TOPIC" > "${WORKSPACE}/codex-stdout.log" 2>&1
  rc=$?
  log "Phase 1: Codex agent finished (exit $rc)"
  exit $rc
) &
CODEX_PID=$!

# ── Launch Gemini subagent ────────────────────────────────────────────────
GEMINI_REPORT="${WORKSPACE}/gemini-report.md"
GEMINI_STATE="${WORKSPACE}/gemini-state.txt"
GEMINI_WORKSPACE="${WORKSPACE}/gemini-workspace"

echo "1" > "$GEMINI_STATE"
write_gemini_settings "$GEMINI_WORKSPACE" "$PLUGIN_ROOT" "research-loop"

GEMINI_LOCAL_REPORT="report.md"

# Build GEMINI.md without embedding user topic in a heredoc
cat "${PLUGIN_ROOT}/prompts/research-system.md" > "${GEMINI_WORKSPACE}/GEMINI.md"
printf '\n## Your Research Topic\n\n%s\n\n## Output\n\nWrite your report to: %s\n' \
  "$TOPIC" "$GEMINI_LOCAL_REPORT" >> "${GEMINI_WORKSPACE}/GEMINI.md"

log "Phase 1: Launching Gemini agent (${GEMINI_MODEL})"

(
  cd "$GEMINI_WORKSPACE"
  RESEARCH_REPORT_PATH="${GEMINI_WORKSPACE}/${GEMINI_LOCAL_REPORT}" \
  RESEARCH_STATE_PATH="$GEMINI_STATE" \
  RESEARCH_MAX_ITERS="$MAX_ITERS" \
  RESEARCH_PROGRESS_LOG="$PROGRESS_LOG" \
  RESEARCH_HOOK_FORMAT=gemini \
  gemini --model "$GEMINI_MODEL" --approval-mode=yolo \
    "Conduct deep research on: ${TOPIC}. Write your comprehensive report to ${GEMINI_LOCAL_REPORT}." \
    > "${WORKSPACE}/gemini-stdout.log" 2>&1
  GEMINI_EXIT=$?
  if [ -f "${GEMINI_LOCAL_REPORT}" ] && [ -s "${GEMINI_LOCAL_REPORT}" ]; then
    cp "${GEMINI_LOCAL_REPORT}" "${GEMINI_REPORT}"
  fi
  log "Phase 1: Gemini agent finished (exit $GEMINI_EXIT)"
  exit $GEMINI_EXIT
) &
GEMINI_PID=$!

# ── Register agents and wait ─────────────────────────────────────────────
register_agent claude "$CLAUDE_PID" "${WORKSPACE}/claude-stdout.log"
register_agent codex  "$CODEX_PID"  "${WORKSPACE}/codex-stdout.log"
register_agent gemini "$GEMINI_PID" "${WORKSPACE}/gemini-stdout.log"

log "Phase 1: Waiting for all 3 agents (PIDs: Claude=${CLAUDE_PID}, Codex=${CODEX_PID}, Gemini=${GEMINI_PID})"
record_pids

wait_for_agents || {
  # All agents crashed at startup
  exit 1
}

# ── Report results ────────────────────────────────────────────────────────
REPORTS_FOUND=0
for f in "$CLAUDE_REPORT" "$CODEX_REPORT" "$GEMINI_REPORT"; do
  if [ -f "$f" ] && [ -s "$f" ]; then
    REPORTS_FOUND=$((REPORTS_FOUND + 1))
    log "Phase 1: Report found: $(basename "$f") ($(wc -l < "$f") lines)"
  else
    log "Phase 1: WARNING — missing report: $(basename "$f")"
  fi
done

if [ "$REPORTS_FOUND" -eq 0 ]; then
  log "Phase 1: FATAL — no reports produced by any agent"
  rm -f "${WORKSPACE}/agent-pids.txt"
  exit 1
fi

rm -f "${WORKSPACE}/agent-pids.txt"
log "Phase 1: Complete (${REPORTS_FOUND}/3 reports produced, ${FAILURES} agent failures)"
