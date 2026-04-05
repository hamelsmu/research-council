#!/usr/bin/env bash
# End-to-end test runner for the Deep Research Council pipeline.
#
# Runs all 4 phases headlessly using cheap/fast models:
#   1. Setup (smoke tests + workspace creation)
#   2. Research (2 parallel agents)
#   3. Refinement (2 parallel agents cross-pollinate)
#   4. Synthesis (single Claude agent writes final report)
#
# Usage:
#   bash scripts/run-e2e-test.sh <topic>
#   bash scripts/run-e2e-test.sh "What is the history of chess?"
#
# Run in tmux for background execution:
#   tmux new-session -d -s e2e 'bash scripts/run-e2e-test.sh "What is chess?"'
#   tail -f research/<id>/progress.log

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(pwd)"

TOPIC="${*:-}"
if [ -z "$TOPIC" ]; then
  echo "Usage: bash scripts/run-e2e-test.sh <research topic>"
  exit 1
fi

# ── Phase 0: Setup (smoke tests + workspace) ─────────────────────────────
echo "=== Phase 0: Setup ==="
set -o noglob
bash "${SCRIPT_DIR}/setup-research.sh" --test "$TOPIC"
SETUP_EXIT=$?
set +o noglob

if [ "$SETUP_EXIT" -ne 0 ]; then
  echo "FATAL: Setup failed (exit $SETUP_EXIT)"
  exit 1
fi

# Extract research ID from state file
STATE_FILE=".claude/deep-research.local.md"
if [ ! -f "$STATE_FILE" ]; then
  echo "FATAL: State file not created"
  exit 1
fi

parse_field() { sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1; }

RESEARCH_ID=$(parse_field "research_id")
CLAUDE_MODEL=$(parse_field "claude_model")
CODEX_MODEL=$(parse_field "codex_model")
CODEX_REASONING=$(parse_field "codex_reasoning")
MAX_ITERS=$(parse_field "max_iterations")
GEMINI_ENABLED=$(parse_field "gemini_enabled")
GEMINI_ENABLED="${GEMINI_ENABLED:-false}"

WORKSPACE="research/${RESEARCH_ID}"
PROGRESS_LOG="${WORKSPACE}/progress.log"

# Remove state file immediately to prevent the orchestrator stop hook from
# racing this e2e test. The e2e script drives phases directly; it doesn't
# need the state file after extracting config above.
rm -f "$STATE_FILE"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] e2e-test: $*" | tee -a "$PROGRESS_LOG"
}

log "Research ID: ${RESEARCH_ID}"
log "Topic: ${TOPIC}"

# ── Phase 1: Research ────────────────────────────────────────────────────
echo ""
echo "=== Phase 1: Research ==="
bash "${SCRIPT_DIR}/run-research-phase.sh" \
  "$RESEARCH_ID" "$TOPIC" "$MAX_ITERS" \
  "$CLAUDE_MODEL" "$CODEX_MODEL" "$CODEX_REASONING" "$GEMINI_ENABLED"
RESEARCH_EXIT=$?

if [ "$RESEARCH_EXIT" -ne 0 ]; then
  log "FATAL: Research phase failed (exit $RESEARCH_EXIT)"
  exit 1
fi

# Verify at least 1 report exists
REPORTS=0
EXPECTED_AGENTS=2
REPORT_CHECK=("${WORKSPACE}/claude-report.md" "${WORKSPACE}/codex-report.md")
if [ "$GEMINI_ENABLED" = "true" ]; then
  REPORT_CHECK+=("${WORKSPACE}/gemini-report.md")
  EXPECTED_AGENTS=3
fi
for f in "${REPORT_CHECK[@]}"; do
  [ -f "$f" ] && [ -s "$f" ] && REPORTS=$((REPORTS + 1))
done
if [ "$REPORTS" -eq 0 ]; then
  log "FATAL: No reports produced"
  exit 1
fi
log "Research complete: ${REPORTS}/${EXPECTED_AGENTS} reports"

# ── Phase 2: Refinement ─────────────────────────────────────────────────
echo ""
echo "=== Phase 2: Refinement ==="
bash "${SCRIPT_DIR}/run-refinement-phase.sh" \
  "$RESEARCH_ID" "$TOPIC" "$MAX_ITERS" \
  "$CLAUDE_MODEL" "$CODEX_MODEL" "$CODEX_REASONING" "$GEMINI_ENABLED"
REFINEMENT_EXIT=$?

if [ "$REFINEMENT_EXIT" -ne 0 ]; then
  log "WARNING: Refinement phase had failures (exit $REFINEMENT_EXIT), continuing with available reports"
fi

# Collect available refined reports (fall back to originals if needed)
REPORT_LIST=""
AVAILABLE=0
AGENTS_TO_CHECK="claude codex"
if [ "$GEMINI_ENABLED" = "true" ]; then
  AGENTS_TO_CHECK="claude codex gemini"
fi
for agent in $AGENTS_TO_CHECK; do
  REFINED="${WORKSPACE}/${agent}-refined.md"
  ORIGINAL="${WORKSPACE}/${agent}-report.md"
  if [ -f "$REFINED" ] && [ -s "$REFINED" ]; then
    REPORT_LIST="${REPORT_LIST} ${REFINED}"
    AVAILABLE=$((AVAILABLE + 1))
  elif [ -f "$ORIGINAL" ] && [ -s "$ORIGINAL" ]; then
    cp "$ORIGINAL" "$REFINED"
    REPORT_LIST="${REPORT_LIST} ${REFINED}"
    AVAILABLE=$((AVAILABLE + 1))
    log "Using original report as fallback for ${agent}"
  fi
done

if [ "$AVAILABLE" -eq 0 ]; then
  log "FATAL: No reports available for synthesis"
  exit 1
fi
log "Refinement complete: ${AVAILABLE}/${EXPECTED_AGENTS} refined reports"

# ── Phase 3: Synthesis ───────────────────────────────────────────────────
echo ""
echo "=== Phase 3: Synthesis ==="
FINAL_REPORT="${WORKSPACE}/final-report.md"

SYNTHESIS_PROMPT="You are synthesizing research from multiple AI agents into a final report.

Topic: ${TOPIC}

Read these refined reports:
$(for f in $REPORT_LIST; do echo "- $f"; done)

Write a comprehensive synthesis to: ${FINAL_REPORT}

Structure:
1. **Executive Summary** — the most important findings
2. **Key Findings** — organized by THEME, combining the strongest evidence
3. **Areas of Consensus** — where agents agree
4. **Areas of Disagreement** — where agents differed and which view is better supported
5. **Novel Insights** — unique findings from cross-pollination
6. **Open Questions** — what remains uncertain
7. **Sources** — deduplicated list of all URLs/references
8. **Methodology** — brief note on the multi-agent research process

Be thorough. This is the final deliverable."

log "Launching synthesis agent (${CLAUDE_MODEL})"
(
  unset CLAUDECODE
  claude -p \
    --model "$CLAUDE_MODEL" \
    --dangerously-skip-permissions \
    --max-turns 50 \
    "$SYNTHESIS_PROMPT"
) > "${WORKSPACE}/synthesis-stdout.log" 2>&1
SYNTHESIS_EXIT=$?
log "Synthesis agent finished (exit $SYNTHESIS_EXIT)"

# ── Results ──────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="

if [ -f "$FINAL_REPORT" ] && [ -s "$FINAL_REPORT" ]; then
  LINES=$(wc -l < "$FINAL_REPORT")
  log "SUCCESS: Final report written (${LINES} lines)"
  echo ""
  echo "  Final report: ${FINAL_REPORT}"
  echo "  Progress log: ${PROGRESS_LOG}"
  echo ""
  exit 0
else
  log "FAILED: No final report produced"
  echo "  Check synthesis log: ${WORKSPACE}/synthesis-stdout.log"
  exit 1
fi
