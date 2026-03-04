#!/usr/bin/env bash
# Phase 2: Cross-pollination refinement — each agent reads both reports and refines
#
# Usage: run-refinement-phase.sh <research_id> <topic> <max_iters> \
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

# Ensure WORKSPACE is absolute (needed for agents that cd elsewhere)
if [ -d "$WORKSPACE" ]; then
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"
fi
PROGRESS_LOG="${WORKSPACE}/progress.log"
PHASE_LABEL="Phase 2"

# shellcheck source=lib/phase-common.sh
source "${SCRIPT_DIR}/lib/phase-common.sh"

EXPECTED_AGENTS=2
if [ "$GEMINI_ENABLED" = "true" ]; then
  EXPECTED_AGENTS=3
fi

log "Phase 2: Starting cross-pollination refinement (${EXPECTED_AGENTS} agents)"

CLAUDE_REPORT="${WORKSPACE}/claude-report.md"
CODEX_REPORT="${WORKSPACE}/codex-report.md"
GEMINI_REPORT="${WORKSPACE}/gemini-report.md"

CLAUDE_REFINED="${WORKSPACE}/claude-refined.md"
CODEX_REFINED="${WORKSPACE}/codex-refined.md"
GEMINI_REFINED="${WORKSPACE}/gemini-refined.md"

REFINEMENT_PROMPT="$(cat "${PLUGIN_ROOT}/prompts/refinement-system.md")"

# Helper: build refinement prompt for a specific agent
# Usage: build_refinement_prompt <own_report> <own_label> <output> <other_label:path> [<other_label:path> ...]
build_refinement_prompt() {
  local OWN_REPORT="$1"
  local OWN_LABEL="$2"
  local OUTPUT="$3"
  shift 3

  local FILES_SECTION="- Your original report (${OWN_LABEL}): ${OWN_REPORT}"
  while [ $# -gt 0 ]; do
    local PAIR="$1"
    local LABEL="${PAIR%%:*}"
    local PATH_="${PAIR#*:}"
    FILES_SECTION="${FILES_SECTION}
- Other report (${LABEL}): ${PATH_}"
    shift
  done
  FILES_SECTION="${FILES_SECTION}
- Write your REFINED report to: ${OUTPUT}"

  echo "${REFINEMENT_PROMPT}

## Research Topic
${TOPIC}

## Files
${FILES_SECTION}

Read all reports, then write your refined report to ${OUTPUT}."
}

# ── Launch Claude refinement ──────────────────────────────────────────────
if [ -f "$CLAUDE_REPORT" ] && [ -s "$CLAUDE_REPORT" ]; then
  CLAUDE_STATE="${WORKSPACE}/claude-refine-state.txt"
  CLAUDE_SETTINGS="${WORKSPACE}/claude-refine-settings.json"

  echo "1" > "$CLAUDE_STATE"

  write_claude_settings "$CLAUDE_SETTINGS" "$PLUGIN_ROOT"

  CLAUDE_OTHER_REPORTS=("Codex:${CODEX_REPORT}")
  if [ "$GEMINI_ENABLED" = "true" ] && [ -f "$GEMINI_REPORT" ] && [ -s "$GEMINI_REPORT" ]; then
    CLAUDE_OTHER_REPORTS+=("Gemini:${GEMINI_REPORT}")
  fi
  CLAUDE_REFINE_PROMPT="$(build_refinement_prompt "$CLAUDE_REPORT" "Claude" "$CLAUDE_REFINED" "${CLAUDE_OTHER_REPORTS[@]}")"

  CLAUDE_EFFORT_FLAG=""
  if [ "${RESEARCH_TEST_MODE:-false}" = "true" ]; then
    CLAUDE_EFFORT_FLAG="--effort low"
  fi

  log "Phase 2: Launching Claude refinement agent${CLAUDE_EFFORT_FLAG:+ (effort=low)}"

  (
    RESEARCH_REPORT_PATH="$CLAUDE_REFINED" \
    RESEARCH_STATE_PATH="$CLAUDE_STATE" \
    RESEARCH_MAX_ITERS="$MAX_ITERS" \
    RESEARCH_PROGRESS_LOG="$PROGRESS_LOG" \
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
  CODEX_OTHER_REPORTS=("Claude:${CLAUDE_REPORT}")
  if [ "$GEMINI_ENABLED" = "true" ] && [ -f "$GEMINI_REPORT" ] && [ -s "$GEMINI_REPORT" ]; then
    CODEX_OTHER_REPORTS+=("Gemini:${GEMINI_REPORT}")
  fi
  CODEX_REFINE_PROMPT="$(build_refinement_prompt "$CODEX_REPORT" "Codex" "$CODEX_REFINED" "${CODEX_OTHER_REPORTS[@]}")"

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

# ── Launch Gemini refinement (optional) ──────────────────────────────────
if [ "$GEMINI_ENABLED" = "true" ] && [ -f "$GEMINI_REPORT" ] && [ -s "$GEMINI_REPORT" ]; then
  # Gemini can't read local files, so embed report contents inline
  GEMINI_INLINE_REPORTS=""
  if [ -f "$CLAUDE_REPORT" ] && [ -s "$CLAUDE_REPORT" ]; then
    GEMINI_INLINE_REPORTS="${GEMINI_INLINE_REPORTS}
<report agent=\"Claude\">
$(cat "$CLAUDE_REPORT")
</report>"
  fi
  if [ -f "$CODEX_REPORT" ] && [ -s "$CODEX_REPORT" ]; then
    GEMINI_INLINE_REPORTS="${GEMINI_INLINE_REPORTS}
<report agent=\"Codex\">
$(cat "$CODEX_REPORT")
</report>"
  fi

  GEMINI_OWN_CONTENT="$(cat "$GEMINI_REPORT")"

  GEMINI_REFINE_PROMPT="${REFINEMENT_PROMPT}

## Research Topic
${TOPIC}

## Your Original Report
<report agent=\"Gemini\">
${GEMINI_OWN_CONTENT}
</report>

## Other Reports
${GEMINI_INLINE_REPORTS}

Write your REFINED report based on all the reports above."

  log "Phase 2: Launching Gemini refinement agent"

  (
    cd "$PROJECT_DIR"
    bash "${PLUGIN_ROOT}/scripts/gemini-wrapper.sh" \
      "$GEMINI_REFINE_PROMPT" \
      "$GEMINI_REFINED" \
      "$PROGRESS_LOG" > "${WORKSPACE}/gemini-refine-stdout.log" 2>&1
    rc=$?
    log "Phase 2: Gemini refinement finished (exit $rc)"
    exit $rc
  ) &
  register_agent gemini $! "${WORKSPACE}/gemini-refine-stdout.log"
else
  if [ "$GEMINI_ENABLED" = "true" ]; then
    log "Phase 2: Skipping Gemini refinement (no Phase 1 report)"
  fi
fi

# ── Wait for agents ──────────────────────────────────────────────────────
record_pids

wait_for_agents || {
  # All agents crashed at startup
  exit 1
}

# ── Report results ────────────────────────────────────────────────────────
REFINED_FOUND=0
REFINED_FILES=("$CLAUDE_REFINED" "$CODEX_REFINED")
if [ "$GEMINI_ENABLED" = "true" ]; then
  REFINED_FILES+=("$GEMINI_REFINED")
fi

for f in "${REFINED_FILES[@]}"; do
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
log "Phase 2: Complete (${REFINED_FOUND}/${EXPECTED_AGENTS} refined reports, ${FAILURES} failures)"
