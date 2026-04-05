#!/usr/bin/env bash
# Gemini Deep Research Wrapper — starts a Deep Research task via the
# Interactions REST API and polls until completion.
#
# Usage: gemini-wrapper.sh <prompt> <report_path> <progress_log> [<poll_interval>]
#
# Requires: GEMINI_API_KEY environment variable
# Dependencies: curl, jq

set -uo pipefail

PROMPT="$1"
REPORT="$2"
PROGRESS_LOG="${3:-/dev/null}"
POLL_INTERVAL="${4:-30}"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Gemini: $*" >> "$PROGRESS_LOG"
}

if [ -z "${GEMINI_API_KEY:-}" ]; then
  log "ERROR: GEMINI_API_KEY is not set"
  exit 1
fi

API_BASE="https://generativelanguage.googleapis.com/v1beta"
SAFETY_TIMEOUT=5400  # 90 minutes (API max is ~60 min)
MAX_HTTP_ERRORS=5

log "Starting Deep Research task (poll interval: ${POLL_INTERVAL}s, timeout: ${SAFETY_TIMEOUT}s)"

# ── Start the Deep Research interaction ──────────────────────────────────
START_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "${API_BASE}/interactions" \
  -H "x-goog-api-key: ${GEMINI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROMPT" '{
    model: "models/gemini-2.5-pro",
    config: { tools: [{ googleSearch: {} }] },
    userInput: { text: $p },
    background: true
  }')")

HTTP_CODE=$(echo "$START_RESPONSE" | tail -1)
BODY=$(echo "$START_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  log "ERROR: Failed to start interaction (HTTP ${HTTP_CODE})"
  log "Response: ${BODY}"
  exit 1
fi

INTERACTION_ID=$(echo "$BODY" | jq -r '.name // empty')

if [ -z "$INTERACTION_ID" ]; then
  log "ERROR: No interaction ID in response"
  log "Response: ${BODY}"
  exit 1
fi

log "Interaction started: ${INTERACTION_ID}"

# ── Poll for completion ──────────────────────────────────────────────────
START_TIME=$(date +%s)
CONSECUTIVE_ERRORS=0

while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))
  if [ "$ELAPSED" -gt "$SAFETY_TIMEOUT" ]; then
    log "ERROR: Safety timeout reached (${SAFETY_TIMEOUT}s)"
    exit 1
  fi

  sleep "$POLL_INTERVAL"

  POLL_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X GET "${API_BASE}/${INTERACTION_ID}" \
    -H "x-goog-api-key: ${GEMINI_API_KEY}" \
    -H "Content-Type: application/json")

  POLL_HTTP=$(echo "$POLL_RESPONSE" | tail -1)
  POLL_BODY=$(echo "$POLL_RESPONSE" | sed '$d')

  if [ "$POLL_HTTP" -lt 200 ] || [ "$POLL_HTTP" -ge 300 ]; then
    CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
    log "WARNING: Poll failed (HTTP ${POLL_HTTP}, attempt ${CONSECUTIVE_ERRORS}/${MAX_HTTP_ERRORS})"
    if [ "$CONSECUTIVE_ERRORS" -ge "$MAX_HTTP_ERRORS" ]; then
      log "ERROR: Too many consecutive HTTP errors, aborting"
      exit 1
    fi
    continue
  fi
  CONSECUTIVE_ERRORS=0

  STATUS=$(echo "$POLL_BODY" | jq -r '.status // "unknown"')
  log "Poll: status=${STATUS}, elapsed=${ELAPSED}s"

  case "$STATUS" in
    completed|COMPLETED)
      # Extract the final text output
      TEXT=$(echo "$POLL_BODY" | jq -r '.outputs[-1].text // empty')
      if [ -z "$TEXT" ]; then
        # Try alternative response shapes
        TEXT=$(echo "$POLL_BODY" | jq -r '.output.text // empty')
      fi
      if [ -z "$TEXT" ]; then
        TEXT=$(echo "$POLL_BODY" | jq -r '
          .outputs[-1].content.parts[-1].text // empty')
      fi

      if [ -n "$TEXT" ]; then
        echo "$TEXT" > "$REPORT"
        LINES=$(wc -l < "$REPORT")
        log "Report written to ${REPORT} (${LINES} lines)"
        exit 0
      else
        log "ERROR: Completed but no text output found"
        log "Response keys: $(echo "$POLL_BODY" | jq -r 'keys | join(", ")')"
        exit 1
      fi
      ;;
    failed|FAILED)
      ERROR_MSG=$(echo "$POLL_BODY" | jq -r '.error.message // "unknown error"')
      log "ERROR: Deep Research failed: ${ERROR_MSG}"
      exit 1
      ;;
    processing|PROCESSING|running|RUNNING)
      # Still working, continue polling
      ;;
    *)
      log "Unknown status: ${STATUS}, continuing to poll"
      ;;
  esac
done
