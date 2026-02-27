#!/usr/bin/env bash
# Phase 2: Cross-pollination refinement — each agent reads all 3 reports and refines
#
# Usage: run-refinement-phase.sh <research_id> <topic> <max_iters> \
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

# Ensure WORKSPACE is absolute (needed for agents that cd elsewhere)
if [ -d "$WORKSPACE" ]; then
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"
fi
PROGRESS_LOG="${WORKSPACE}/progress.log"
PHASE_LABEL="Phase 2"

# shellcheck source=lib/phase-common.sh
source "${SCRIPT_DIR}/lib/phase-common.sh"

log "Phase 2: Starting cross-pollination refinement"

CLAUDE_REPORT="${WORKSPACE}/claude-report.md"
CODEX_REPORT="${WORKSPACE}/codex-report.md"
GEMINI_REPORT="${WORKSPACE}/gemini-report.md"

CLAUDE_REFINED="${WORKSPACE}/claude-refined.md"
CODEX_REFINED="${WORKSPACE}/codex-refined.md"
GEMINI_REFINED="${WORKSPACE}/gemini-refined.md"

REFINEMENT_PROMPT="$(cat "${PLUGIN_ROOT}/prompts/refinement-system.md")"

# Helper: build refinement prompt for a specific agent
build_refinement_prompt() {
  local OWN_REPORT="$1"
  local OWN_LABEL="$2"
  local OTHER1="$3"
  local OTHER1_LABEL="$4"
  local OTHER2="$5"
  local OTHER2_LABEL="$6"
  local OUTPUT="$7"

  echo "${REFINEMENT_PROMPT}

## Research Topic
${TOPIC}

## Files
- Your original report (${OWN_LABEL}): ${OWN_REPORT}
- Other report (${OTHER1_LABEL}): ${OTHER1}
- Other report (${OTHER2_LABEL}): ${OTHER2}
- Write your REFINED report to: ${OUTPUT}

Read all three reports, then write your refined report to ${OUTPUT}."
}

# ── Launch Claude refinement ──────────────────────────────────────────────
if [ -f "$CLAUDE_REPORT" ] && [ -s "$CLAUDE_REPORT" ]; then
  CLAUDE_STATE="${WORKSPACE}/claude-refine-state.txt"
  CLAUDE_SETTINGS="${WORKSPACE}/claude-refine-settings.json"

  echo "1" > "$CLAUDE_STATE"

  write_claude_settings "$CLAUDE_SETTINGS" "$PLUGIN_ROOT"

  CLAUDE_REFINE_PROMPT="$(build_refinement_prompt "$CLAUDE_REPORT" "Claude" "$CODEX_REPORT" "Codex" "$GEMINI_REPORT" "Gemini" "$CLAUDE_REFINED")"

  CLAUDE_EFFORT_FLAG=""
  if [ "${RESEARCH_TEST_MODE:-false}" = "true" ]; then
    CLAUDE_EFFORT_FLAG="--effort low"
  fi

  log "Phase 2: Launching Claude refinement agent${CLAUDE_EFFORT_FLAG:+ (effort=low)}"

  (
    RESEARCH_REPORT_PATH="$CLAUDE_REFINED" \
    RESEARCH_STATE_PATH="$CLAUDE_STATE" \
    RESEARCH_MAX_ITERS="$MAX_ITERS" \
    RESEARCH_HOOK_FORMAT=claude \
    env -u CLAUDECODE claude -p \
      --model "$CLAUDE_MODEL" \
      $CLAUDE_EFFORT_FLAG \
      --dangerously-skip-permissions \
      --settings "$CLAUDE_SETTINGS" \
      --max-turns 200 \
      "$CLAUDE_REFINE_PROMPT" > "${WORKSPACE}/claude-refine-stdout.log" 2>&1
    rc=$?
    log "Phase 2: Claude refinement finished (exit $rc)"
    exit $rc
  ) &
  register_agent claude $! "${WORKSPACE}/claude-refine-stdout.log"
else
  log "Phase 2: Skipping Claude refinement (no Phase 1 report)"
fi

# ── Launch Codex refinement ───────────────────────────────────────────────
if [ -f "$CODEX_REPORT" ] && [ -s "$CODEX_REPORT" ]; then
  CODEX_REFINE_PROMPT="$(build_refinement_prompt "$CODEX_REPORT" "Codex" "$CLAUDE_REPORT" "Claude" "$GEMINI_REPORT" "Gemini" "$CODEX_REFINED")"

  log "Phase 2: Launching Codex refinement agent"

  (
    cd "$PROJECT_DIR"
    bash "${PLUGIN_ROOT}/scripts/codex-wrapper.sh" \
      "$CODEX_REFINE_PROMPT" \
      "$CODEX_REFINED" \
      "$MAX_ITERS" \
      "$CODEX_MODEL" \
      "$CODEX_REASONING" \
      "$PROGRESS_LOG" \
      "$TOPIC" > "${WORKSPACE}/codex-refine-stdout.log" 2>&1
    rc=$?
    log "Phase 2: Codex refinement finished (exit $rc)"
    exit $rc
  ) &
  register_agent codex $! "${WORKSPACE}/codex-refine-stdout.log"
else
  log "Phase 2: Skipping Codex refinement (no Phase 1 report)"
fi

# ── Launch Gemini refinement ──────────────────────────────────────────────
if [ -f "$GEMINI_REPORT" ] && [ -s "$GEMINI_REPORT" ]; then
  GEMINI_STATE="${WORKSPACE}/gemini-refine-state.txt"
  GEMINI_WORKSPACE="${WORKSPACE}/gemini-refine-workspace"
  GEMINI_LOCAL_REFINED="refined-report.md"

  echo "1" > "$GEMINI_STATE"
  write_gemini_settings "$GEMINI_WORKSPACE" "$PLUGIN_ROOT" "refinement-loop"

  # Copy input reports INTO Gemini workspace (sandbox can't read outside)
  cp "$GEMINI_REPORT" "${GEMINI_WORKSPACE}/own-report.md" 2>/dev/null || true
  cp "$CLAUDE_REPORT" "${GEMINI_WORKSPACE}/claude-report.md" 2>/dev/null || true
  cp "$CODEX_REPORT" "${GEMINI_WORKSPACE}/codex-report.md" 2>/dev/null || true

  # Use the shared helper with local paths (Gemini sandbox can't read outside its workspace)
  GEMINI_REFINE_PROMPT="$(build_refinement_prompt \
    "own-report.md" "Gemini" "claude-report.md" "Claude" "codex-report.md" "Codex" "$GEMINI_LOCAL_REFINED")"

  # Write full prompt (system + topic + file paths) to GEMINI.md for consistency
  # with the research phase — Gemini may read GEMINI.md as system instructions.
  printf '%s\n' "$GEMINI_REFINE_PROMPT" > "${GEMINI_WORKSPACE}/GEMINI.md"

  log "Phase 2: Launching Gemini refinement agent"

  (
    cd "$GEMINI_WORKSPACE"
    RESEARCH_REPORT_PATH="${GEMINI_WORKSPACE}/${GEMINI_LOCAL_REFINED}" \
    RESEARCH_STATE_PATH="$GEMINI_STATE" \
    RESEARCH_MAX_ITERS="$MAX_ITERS" \
    RESEARCH_PROGRESS_LOG="$PROGRESS_LOG" \
    RESEARCH_HOOK_FORMAT=gemini \
    gemini --model "$GEMINI_MODEL" --approval-mode=yolo \
      "$GEMINI_REFINE_PROMPT" > "${WORKSPACE}/gemini-refine-stdout.log" 2>&1
    GEMINI_EXIT=$?
    # Copy refined report from workspace to expected location
    if [ -f "${GEMINI_LOCAL_REFINED}" ] && [ -s "${GEMINI_LOCAL_REFINED}" ]; then
      cp "${GEMINI_LOCAL_REFINED}" "${GEMINI_REFINED}"
    fi
    log "Phase 2: Gemini refinement finished (exit $GEMINI_EXIT)"
    exit $GEMINI_EXIT
  ) &
  register_agent gemini $! "${WORKSPACE}/gemini-refine-stdout.log"
else
  log "Phase 2: Skipping Gemini refinement (no Phase 1 report)"
fi

# ── Wait for agents ──────────────────────────────────────────────────────
record_pids

wait_for_agents || {
  # All agents crashed at startup
  exit 1
}

# ── Report results ────────────────────────────────────────────────────────
REFINED_FOUND=0
for f in "$CLAUDE_REFINED" "$CODEX_REFINED" "$GEMINI_REFINED"; do
  if [ -f "$f" ] && [ -s "$f" ]; then
    REFINED_FOUND=$((REFINED_FOUND + 1))
    log "Phase 2: Refined report found: $(basename "$f") ($(wc -l < "$f") lines)"
  else
    # Fall back to original report if refinement failed
    ORIGINAL="${f//-refined/-report}"
    if [ -f "$ORIGINAL" ] && [ -s "$ORIGINAL" ]; then
      cp "$ORIGINAL" "$f"
      log "Phase 2: WARNING — refinement failed for $(basename "$f"), using original report as fallback"
      REFINED_FOUND=$((REFINED_FOUND + 1))
    else
      log "Phase 2: WARNING — no refined report: $(basename "$f")"
    fi
  fi
done

rm -f "${WORKSPACE}/agent-pids.txt"
log "Phase 2: Complete (${REFINED_FOUND}/3 refined reports, ${FAILURES} failures)"
