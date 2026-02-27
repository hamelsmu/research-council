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

Launches deep research across Claude, Codex, and Gemini in parallel.

Phases:
  1. Three agents independently research the topic (with iterative loops)
  2. Each agent reads all 3 reports and refines with new avenues
  3. Main Claude synthesizes everything into a final report

Options:
  --test    Use cheap/fast models and 2 iterations (for testing the pipeline)

Prerequisites:
  - claude CLI (Claude Code)
  - codex CLI (OpenAI Codex)
  - gemini CLI (Google Gemini)
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
if ! command -v gemini &>/dev/null; then
  MISSING+=("gemini (Google Gemini CLI — npm install -g @google/gemini-cli)")
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

# Check Gemini auth
if [ -z "${GEMINI_API_KEY:-}" ] && [ -z "${GOOGLE_API_KEY:-}" ]; then
  # Check if OAuth is configured
  if [ ! -f "${HOME}/.gemini/oauth_creds.json" ] && [ ! -f "${HOME}/.config/gemini/oauth_creds.json" ]; then
    WARNINGS+=("gemini may not be authenticated — run 'gemini' once to set up auth, or set GEMINI_API_KEY")
  fi
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

smoke_gemini() {
  local start=$SECONDS
  "$TIMEOUT_CMD" 60 gemini -p \
    "Reply with OK" \
    --model gemini-2.5-flash-lite > "$SMOKE_DIR/gemini.out" 2>&1
  echo $? > "$SMOKE_DIR/gemini.exit"
  echo $((SECONDS - start)) > "$SMOKE_DIR/gemini.time"
}

# Run all 3 in parallel
smoke_claude &
smoke_codex &
smoke_gemini &
wait

SMOKE_FAILURES=()

for agent in claude codex gemini; do
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
      gemini)
        echo "  gemini: Verify your Gemini API key (GEMINI_API_KEY or GOOGLE_API_KEY) or OAuth setup."
        echo "          Run: gemini -p 'Reply with OK' --model gemini-2.5-flash-lite"
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
  GEMINI_MODEL="gemini-2.5-flash-lite"
  MODE_LABEL="TEST MODE (cheap models, 2 iterations)"
else
  MAX_ITERS=10
  CLAUDE_MODEL="claude-opus-4-6"
  CODEX_MODEL="gpt-5.3-codex"
  CODEX_REASONING="xhigh"
  GEMINI_MODEL="gemini-2.5-pro"
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
gemini_model: ${GEMINI_MODEL}
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
echo "    Gemini  →  ${GEMINI_MODEL}"
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
