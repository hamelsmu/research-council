#!/usr/bin/env bash
# Phase 1: Launch 2 research agents in parallel and wait for all to complete
#
# Usage: run-research-phase.sh <research_id> <topic> <max_iters> \
#          <claude_model> <codex_model> <codex_reasoning>

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
GEMINI_ENABLED="${7:-false}"

WORKSPACE="${PROJECT_DIR}/research/${RESEARCH_ID}"
mkdir -p "$WORKSPACE"
WORKSPACE="$(cd "$WORKSPACE" && pwd)"
PROGRESS_LOG="${WORKSPACE}/progress.log"
PHASE_LABEL="Phase 1"

# shellcheck source=lib/phase-common.sh
source "${SCRIPT_DIR}/lib/phase-common.sh"

EXPECTED_AGENTS=2
if [ "$GEMINI_ENABLED" = "true" ]; then
  EXPECTED_AGENTS=3
fi

log "Phase 1: Starting initial research (${EXPECTED_AGENTS} agents)"
log "  Topic: ${TOPIC}"
log "  Max iterations: ${MAX_ITERS}"
log "  Claude: ${CLAUDE_MODEL} | Codex: ${CODEX_MODEL} (${CODEX_REASONING})"
if [ "$GEMINI_ENABLED" = "true" ]; then
  log "  Gemini: Deep Research (gemini-2.5-pro)"
fi

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
  RESEARCH_PROGRESS_LOG="$PROGRESS_LOG" \
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

# ── Launch Gemini subagent (optional) ─────────────────────────────────────
GEMINI_PID=""
if [ "$GEMINI_ENABLED" = "true" ]; then
  GEMINI_REPORT="${WORKSPACE}/gemini-report.md"
  GEMINI_PROMPT="$(cat "${PLUGIN_ROOT}/prompts/gemini-research-system.md")

## Your Research Topic

${TOPIC}"

  log "Phase 1: Launching Gemini Deep Research agent"

  (
    cd "$PROJECT_DIR"
    bash "${PLUGIN_ROOT}/scripts/gemini-wrapper.sh" \
      "$GEMINI_PROMPT" \
      "$GEMINI_REPORT" \
      "$PROGRESS_LOG" > "${WORKSPACE}/gemini-stdout.log" 2>&1
    rc=$?
    log "Phase 1: Gemini agent finished (exit $rc)"
    exit $rc
  ) &
  GEMINI_PID=$!
fi

# ── Register agents and wait ─────────────────────────────────────────────
register_agent claude "$CLAUDE_PID" "${WORKSPACE}/claude-stdout.log"
register_agent codex  "$CODEX_PID"  "${WORKSPACE}/codex-stdout.log"
if [ -n "$GEMINI_PID" ]; then
  register_agent gemini "$GEMINI_PID" "${WORKSPACE}/gemini-stdout.log"
fi

PID_MSG="PIDs: Claude=${CLAUDE_PID}, Codex=${CODEX_PID}"
if [ -n "$GEMINI_PID" ]; then
  PID_MSG="${PID_MSG}, Gemini=${GEMINI_PID}"
fi
log "Phase 1: Waiting for all ${EXPECTED_AGENTS} agents (${PID_MSG})"
record_pids

wait_for_agents || {
  # All agents crashed at startup
  exit 1
}

# ── Report results ────────────────────────────────────────────────────────
REPORTS_FOUND=0
REPORT_FILES=("$CLAUDE_REPORT" "$CODEX_REPORT")
if [ "$GEMINI_ENABLED" = "true" ]; then
  REPORT_FILES+=("${WORKSPACE}/gemini-report.md")
fi

for f in "${REPORT_FILES[@]}"; do
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
log "Phase 1: Complete (${REPORTS_FOUND}/${EXPECTED_AGENTS} reports produced, ${FAILURES} agent failures)"
