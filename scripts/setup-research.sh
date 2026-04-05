#!/usr/bin/env bash
set -euo pipefail

# Deep Research Council — Setup Script
# Validates prerequisites, creates workspace, and prepares the research lifecycle.

# ── Parse arguments ───────────────────────────────────────────────────────
TEST_MODE=false
ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --test)
      TEST_MODE=true
      shift
      ;;
    --help|-h)
      cat << 'HELP'
Usage: /deep-research [--test] <research topic>

Launches deep research across Claude and Codex in parallel.

Phases:
  1. Two agents independently research the topic (with iterative loops)
  2. Each agent reads both reports and refines with new avenues
  3. Main Claude synthesizes everything into a final report

Options:
  --test    Use cheap/fast models and 2 iterations (for testing the pipeline)

Prerequisites:
  - claude CLI (Claude Code)
  - codex CLI (OpenAI Codex)
  - jq (JSON processor)

Example:
  /deep-research How do transformer attention mechanisms scale with sequence length?
  /deep-research --test What is the history of the Python programming language?
HELP
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

TOPIC="${ARGS[*]:-}"

if [ -z "$TOPIC" ]; then
  echo "Error: No research topic provided."
  echo "Usage: /deep-research [--test] <research topic>"
  echo ""
  echo "Example: /deep-research How do LLMs handle long-context reasoning?"
  exit 1
fi

# ── Check for existing session ────────────────────────────────────────────
if [ -f ".claude/deep-research.local.md" ]; then
  echo "Error: A research session is already active."
  echo "Use /cancel-research to abort it first, or wait for it to complete."
  exit 1
fi

# ── Check dependencies ───────────────────────────────────────────────────
MISSING=()

if ! command -v claude &>/dev/null; then
  MISSING+=("claude (Claude Code CLI — https://docs.anthropic.com/en/docs/claude-code)")
fi
if ! command -v codex &>/dev/null; then
  MISSING+=("codex (OpenAI Codex CLI — npm install -g @openai/codex)")
fi
if ! command -v jq &>/dev/null; then
  MISSING+=("jq (JSON processor — brew install jq)")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: Missing required CLI tools:"
  echo ""
  for dep in "${MISSING[@]}"; do
    echo "  ✗ $dep"
  done
  echo ""
  echo "Install the missing tools and try again."
  exit 1
fi

# ── Verify CLI auth (best-effort checks) ─────────────────────────────────
WARNINGS=()

# Check Codex auth
if ! codex --version &>/dev/null 2>&1; then
  WARNINGS+=("codex may not be authenticated — run 'codex login' if research fails")
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo "Warnings:"
  for w in "${WARNINGS[@]}"; do
    echo "  ⚠ $w"
  done
  echo ""
fi

# ── Smoke-test API connectivity ──────────────────────────────────────────
# Run a single cheap prompt against each CLI to verify auth/quota before
# creating any workspace or launching expensive agents.

echo "Running pre-flight smoke tests..."
echo ""

SMOKE_DIR="$(mktemp -d)"
trap 'rm -rf "$SMOKE_DIR"' EXIT

# macOS ships without GNU timeout; use perl fallback
if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
elif ! command -v perl &>/dev/null; then
  echo "Error: Neither 'timeout' (GNU coreutils) nor 'perl' found."
  echo "Install GNU coreutils: brew install coreutils"
  exit 1
else
  # Create a small timeout wrapper script that subshells can call
  TIMEOUT_CMD="${SMOKE_DIR}/timeout-wrapper"
  cat > "$TIMEOUT_CMD" << 'WRAPPER_EOF'
#!/usr/bin/env bash
secs="$1"; shift
perl -e 'alarm shift; exec @ARGV' -- "$secs" "$@"
WRAPPER_EOF
  chmod +x "$TIMEOUT_CMD"
fi

smoke_claude() {
  local start=$SECONDS
  (
    unset CLAUDECODE
    "$TIMEOUT_CMD" 60 claude -p \
      --model claude-haiku-4-5-20251001 \
      --max-turns 1 \
      "Reply with OK"
  ) > "$SMOKE_DIR/claude.out" 2>&1
  echo $? > "$SMOKE_DIR/claude.exit"
  echo $((SECONDS - start)) > "$SMOKE_DIR/claude.time"
}

smoke_codex() {
  local start=$SECONDS
  "$TIMEOUT_CMD" 60 codex exec \
    --model gpt-5.1-codex-mini \
    -c model_reasoning_effort=low \
    --full-auto --skip-git-repo-check \
    "Reply with OK" > "$SMOKE_DIR/codex.out" 2>&1
  echo $? > "$SMOKE_DIR/codex.exit"
  echo $((SECONDS - start)) > "$SMOKE_DIR/codex.time"
}

# ── Optional Gemini detection ────────────────────────────────────────────
GEMINI_ENABLED=false

smoke_gemini() {
  local start=$SECONDS
  "$TIMEOUT_CMD" 30 curl -s -o "$SMOKE_DIR/gemini.out" -w "%{http_code}" \
    -X POST "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent" \
    -H "x-goog-api-key: ${GEMINI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"contents":[{"parts":[{"text":"Reply with OK"}]}]}' \
    > "$SMOKE_DIR/gemini.http" 2>&1
  local http_code
  http_code=$(cat "$SMOKE_DIR/gemini.http" 2>/dev/null || echo "000")
  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo 0 > "$SMOKE_DIR/gemini.exit"
  else
    echo 1 > "$SMOKE_DIR/gemini.exit"
  fi
  echo $((SECONDS - start)) > "$SMOKE_DIR/gemini.time"
}

# Run required agents in parallel
smoke_claude &
smoke_codex &

# Run optional Gemini smoke test if API key is set
if [ -n "${GEMINI_API_KEY:-}" ]; then
  smoke_gemini &
fi
wait

SMOKE_FAILURES=()

for agent in claude codex; do
  EXIT_CODE=$(cat "$SMOKE_DIR/${agent}.exit" 2>/dev/null || echo 1)
  ELAPSED=$(cat "$SMOKE_DIR/${agent}.time" 2>/dev/null || echo "?")

  if [ "$EXIT_CODE" -eq 0 ]; then
    echo "  ✓ ${agent} — OK (${ELAPSED}s)"
  else
    echo "  ✗ ${agent} — FAILED (exit ${EXIT_CODE}, ${ELAPSED}s)"
    LAST_LINES=$(tail -5 "$SMOKE_DIR/${agent}.out" 2>/dev/null || echo "(no output)")
    echo "    Last output:"
    echo "$LAST_LINES" | sed 's/^/      /'
    SMOKE_FAILURES+=("$agent")
  fi
done

echo ""

# Handle optional Gemini result (warning only, not a hard failure)
if [ -n "${GEMINI_API_KEY:-}" ]; then
  GEMINI_EXIT=$(cat "$SMOKE_DIR/gemini.exit" 2>/dev/null || echo 1)
  GEMINI_ELAPSED=$(cat "$SMOKE_DIR/gemini.time" 2>/dev/null || echo "?")
  if [ "$GEMINI_EXIT" -eq 0 ]; then
    echo "  ✓ gemini — OK (${GEMINI_ELAPSED}s)"
    GEMINI_ENABLED=true
  else
    echo "  ⚠ gemini — FAILED (${GEMINI_ELAPSED}s) — continuing without Gemini"
  fi
fi

if [ ${#SMOKE_FAILURES[@]} -gt 0 ]; then
  echo "Error: Smoke tests failed for: ${SMOKE_FAILURES[*]}"
  echo ""
  echo "Fix instructions:"
  for agent in "${SMOKE_FAILURES[@]}"; do
    case "$agent" in
      claude)
        echo "  claude: Verify your Anthropic API key and account quota."
        echo "          Run: claude -p --model claude-haiku-4-5-20251001 --max-turns 1 'Reply with OK'"
        ;;
      codex)
        echo "  codex:  Verify your OpenAI API key and account quota."
        echo "          Run: codex exec --model gpt-5.1-codex-mini --full-auto --skip-git-repo-check 'Reply with OK'"
        ;;
    esac
  done
  echo ""
  echo "All agents must pass smoke tests before launching a research session."
  exit 1
fi

echo "All smoke tests passed — agents are ready."
echo ""

# ── Generate unique research ID ──────────────────────────────────────────
if command -v openssl &>/dev/null; then
  RAND_HEX=$(openssl rand -hex 3)
else
  RAND_HEX=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi
RESEARCH_ID="$(date +%Y%m%d-%H%M%S)-${RAND_HEX}"

# ── Determine model configuration ────────────────────────────────────────
if [ "$TEST_MODE" = true ]; then
  MAX_ITERS=2
  CLAUDE_MODEL="claude-haiku-4-5-20251001"
  CODEX_MODEL="gpt-5.1-codex-mini"
  CODEX_REASONING="low"
  MODE_LABEL="TEST MODE (cheap models, 2 iterations)"
else
  MAX_ITERS=10
  CLAUDE_MODEL="claude-opus-4-6"
  CODEX_MODEL="gpt-5.3-codex"
  CODEX_REASONING="xhigh"
  MODE_LABEL="PRODUCTION (maximum reasoning depth)"
fi

# ── Create workspace ─────────────────────────────────────────────────────
WORKSPACE="research/${RESEARCH_ID}"
mkdir -p "$WORKSPACE" .claude
rm -f .claude/deep-research.lock

# ── Create state file ────────────────────────────────────────────────────
STATE_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > .claude/deep-research.local.md << STATE_EOF
---
active: true
phase: research
research_id: ${RESEARCH_ID}
session_id:
test_mode: ${TEST_MODE}
max_iterations: ${MAX_ITERS}
claude_model: ${CLAUDE_MODEL}
codex_model: ${CODEX_MODEL}
codex_reasoning: ${CODEX_REASONING}
gemini_enabled: ${GEMINI_ENABLED}
started_at: ${STATE_TIMESTAMP}
---
STATE_EOF
# Append topic separately (user-controlled data kept out of heredoc)
printf '\n%s\n' "$TOPIC" >> .claude/deep-research.local.md

# ── Report success ───────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Deep Research Council activated"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Research ID:  ${RESEARCH_ID}"
echo "  Mode:         ${MODE_LABEL}"
echo "  Topic:        ${TOPIC}"
echo ""
echo "  Agents:"
echo "    Claude  →  ${CLAUDE_MODEL}"
echo "    Codex   →  ${CODEX_MODEL} (reasoning: ${CODEX_REASONING})"
if [ "$GEMINI_ENABLED" = true ]; then
  echo "    Gemini  →  gemini-2.5-pro (Deep Research)"
fi
echo ""
echo "  Max iterations per agent: ${MAX_ITERS}"
echo "  Workspace: ${WORKSPACE}/"
echo ""
echo "  Monitor progress in another terminal:"
echo "    tail -f ${WORKSPACE}/progress.log"
echo ""
echo "  Cancel with: /cancel-research"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""
