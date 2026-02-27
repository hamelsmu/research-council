#!/usr/bin/env bash
# Codex Subagent Wrapper — runs Codex in a bash loop since Codex lacks hooks
#
# Usage: codex-wrapper.sh <initial_prompt> <report_path> <max_iterations> <model> <reasoning_effort> <progress_log> [<topic>]
#
# The initial prompt is the full instruction set for the first iteration,
# built by the phase runner. The optional <topic> argument provides a short
# description for continuation prompts. If omitted, defaults to "(research)".

set -uo pipefail

INITIAL_PROMPT="$1"
REPORT="$2"
MAX_ITERS="${3:-10}"
MODEL="${4:-gpt-5.3-codex}"
REASONING="${5:-xhigh}"
PROGRESS_LOG="${6:-/dev/null}"
TOPIC="${7:-(research)}"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Codex: $*" >> "$PROGRESS_LOG"
}

REPORT_ABS="$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")"

# Build the continuation prompt
CONTINUE_PROMPT="Continue your deep research on: ${TOPIC}

Read your current report at ${REPORT_ABS}. Identify:
- Gaps in coverage that need filling
- Angles you haven't explored yet
- Claims that need better evidence or more sources
- Areas where you were shallow and should go deeper

Conduct additional web searches and update the report with substantial new content.
When truly comprehensive, add <!-- RESEARCH_COMPLETE --> as the very last line."

log "Starting research (model: ${MODEL}, reasoning: ${REASONING}, max_iters: ${MAX_ITERS})"

LAST_ERROR=0

# First iteration
log "Iteration 1/${MAX_ITERS}"
codex exec \
  --model "$MODEL" \
  -c model_reasoning_effort="$REASONING" \
  --full-auto \
  --skip-git-repo-check \
  "$INITIAL_PROMPT" 2>>"$PROGRESS_LOG" || {
    LAST_ERROR=$?
    log "ERROR: Codex iteration 1 failed (exit $LAST_ERROR)"
  }

# Subsequent iterations
for i in $(seq 2 "$MAX_ITERS"); do
  # Check completion
  if [ -f "$REPORT" ] && grep -q "RESEARCH_COMPLETE" "$REPORT" 2>/dev/null; then
    log "Research complete after $((i-1)) iterations"
    LAST_ERROR=0
    break
  fi

  log "Iteration ${i}/${MAX_ITERS}"
  # NOTE: --last resumes the most recent Codex session. If the user runs
  # Codex independently in another terminal during research, this could
  # resume the wrong session. This is a Codex CLI limitation.
  codex exec resume --last \
    --skip-git-repo-check \
    "$CONTINUE_PROMPT" 2>>"$PROGRESS_LOG" || {
      LAST_ERROR=$?
      log "ERROR: Codex iteration ${i} failed (exit $LAST_ERROR)"
    }
done

# Final check — exit non-zero if no report was produced
if [ -f "$REPORT" ] && [ -s "$REPORT" ]; then
  log "Report written to ${REPORT} ($(wc -l < "$REPORT") lines)"
  exit 0
else
  log "ERROR: No report file produced at ${REPORT}"
  exit 1
fi
