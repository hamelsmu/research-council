# Testing, Debugging & Troubleshooting Guide

## Test Suite

### Unit Tests (`scripts/test-refactoring.sh`)

Run with:

```bash
bash scripts/test-refactoring.sh
```

Tests 5 groups (45 tests total):

1. **iteration-hook.sh** — Verifies both Claude and Gemini output formats, completion marker detection, max iteration limits, missing env var handling, non-numeric state reset, and iteration counter increments.

2. **lib/phase-common.sh** — Tests `register_agent`/`agent_pid`/`agent_log` registry, `record_pids` writing PID files, and `check_log_for_fatal_errors` detecting quota/auth patterns while passing clean logs.

3. **sedi() helper** — Tests portable `sed -i` replacement, variable substitution, and preservation of other lines.

4. **No stale references** — Ensures phase scripts reference `iteration-hook.sh` (not the old `claude-stop-hook.sh` or `gemini-afteragent-hook.sh`), set `RESEARCH_HOOK_FORMAT` for both Claude and Gemini, don't contain dead `kill_tree` code, and source `phase-common.sh`.

5. **Syntax checks** — Runs `bash -n` on all scripts to catch parse errors.

### End-to-End Tests (`scripts/run-e2e-test.sh`)

#### Quick-start (copy-paste)

```bash
# 1. Clean up any stale session first
ps aux | grep -E "claude -p|codex exec|gemini " | grep -v grep | awk '{print $2}' | xargs kill 2>/dev/null
rm -f .claude/deep-research.local.md .claude/deep-research.lock

# 2. Launch in tmux with output capture
tmux new-session -d -s e2e 'bash scripts/run-e2e-test.sh "What is the history of chess?" 2>&1 | tee /tmp/e2e-test-output.log'

# 3. Monitor (in another terminal)
tail -f /tmp/e2e-test-output.log           # full output
tmux ls                                     # session exists = still running
```

#### Expected timeline (test mode)

| Phase | Typical duration | What to expect |
|-------|-----------------|----------------|
| Phase 0: Smoke tests | ~35-40s | Claude smoke test is slowest (~35s). Codex/Gemini are fast (~2-4s) |
| Phase 1: Research | ~2-5 min | Codex finishes first (~1 min). Claude (Haiku) takes ~4 min. Gemini may fail on quota |
| Phase 2: Refinement | ~5-8 min | Only runs agents that produced Phase 1 reports. Claude is slowest |
| Phase 3: Synthesis | ~2-3 min | Single Claude agent synthesizes all refined reports |
| **Total** | **~10-15 min** | Varies by API latency and quota availability |

#### Monitoring a running test

```bash
# Watch the captured output
tail -f /tmp/e2e-test-output.log

# Check structured progress entries (filters agent stdout noise)
grep "^\[" research/<id>/progress.log | tail -20

# Verify agents are alive (not hanging)
ps aux | grep -E "claude -p|codex exec|gemini " | grep -v grep

# Check agent stdout log sizes (growing = actively working)
wc -l research/<id>/*-stdout.log research/<id>/*-refine-stdout.log 2>/dev/null

# Check if test is still running
tmux ls                                           # session exists = still running
```

**Note:** Claude stdout logs are often empty for minutes due to output buffering — this does NOT mean the agent is hanging. Check that the process is alive with `ps` instead.

#### Cleaning up

```bash
# Kill a stuck test
tmux kill-session -t e2e
# Kill any orphaned agent processes
ps aux | grep -E "claude -p|codex exec|gemini " | grep -v grep | awk '{print $2}' | xargs kill 2>/dev/null
# Remove stale state
rm -f .claude/deep-research.local.md .claude/deep-research.lock
```

#### Common blockers

- **"A research session is already active"** — A previous session left state behind. Run the cleanup commands above before launching.
- **Gemini quota errors** — Gemini CLI hits rate limits frequently. The fatal error detector kills it correctly; the test continues with Claude + Codex only. This is expected behavior, not a test failure.
- **Claude stdout log empty** — Output buffering. The process is likely alive and working. Verify with `ps`.

#### What counts as a pass

The test succeeds if `run-e2e-test.sh` prints `SUCCESS: Final report written` and exits 0. Partial agent failures (e.g., Gemini quota) are tolerated as long as at least 2/3 agents produce reports.

This runs the full 4-phase pipeline (setup, research, refinement, synthesis) using `--test` mode, which selects cheap/fast models (Haiku, codex-mini, flash-lite) and limits to 2 iterations.

**Important: plugin cache synchronization.** The e2e test script runs from the local `scripts/` directory, but if you've been running `/deep-research` via the Claude Code plugin, the orchestrator uses scripts from `~/.claude/plugins/cache/research-council/...`. After modifying scripts locally, either:
- Run `claude /install-plugin .` to update the plugin cache, OR
- Run `run-e2e-test.sh` directly (it uses local scripts, not the plugin cache)

Never run both paths simultaneously against the same workspace — they'll fight over the same files.

### Test Mode

The `--test` flag on `setup-research.sh` configures:
- `max_iterations: 2` (vs 10 in production)
- `claude_model: claude-haiku-4-5-20251001` (vs opus)
- `codex_model: gpt-5.1-codex-mini` (vs gpt-5.3-codex)
- `codex_reasoning: low` (vs xhigh)
- `gemini_model: gemini-2.5-flash-lite` (vs gemini-2.5-pro)

Test mode is propagated to child scripts via `RESEARCH_TEST_MODE=true`, which also sets `--effort low` on Claude subagent launches.

## Debugging

### Log Files

Each research session creates a workspace at `research/<research-id>/` containing:

| File | Purpose |
|------|---------|
| `progress.log` | Main progress log — timestamped entries from all phases |
| `claude-stdout.log` | Claude agent's raw stdout/stderr (Phase 1) |
| `codex-stdout.log` | Codex agent's raw stdout/stderr (Phase 1) |
| `gemini-stdout.log` | Gemini agent's raw stdout/stderr (Phase 1) |
| `claude-refine-stdout.log` | Claude refinement stdout (Phase 2) |
| `codex-refine-stdout.log` | Codex refinement stdout (Phase 2) |
| `gemini-refine-stdout.log` | Gemini refinement stdout (Phase 2) |
| `synthesis-stdout.log` | Synthesis agent stdout (Phase 3, e2e only) |

The orchestrator also writes to `.claude/deep-research.log`.

### Monitoring a Live Session

```bash
# Main progress feed
tail -f research/<id>/progress.log

# Watch a specific agent
tail -f research/<id>/claude-stdout.log
tail -f research/<id>/gemini-stdout.log
```

### Common Failure Patterns

**Agent fails immediately (exit code non-zero, empty log)**
- CLI not installed or not authenticated
- Fix: Run the smoke test commands from `setup-research.sh` manually:
  ```bash
  claude -p --model claude-haiku-4-5-20251001 --max-turns 1 'Reply with OK'
  codex exec --model gpt-5.1-codex-mini --full-auto --skip-git-repo-check 'Reply with OK'
  gemini -p 'Reply with OK' --model gemini-2.5-flash-lite
  ```

**Agent killed mid-run with "FATAL ERROR in logs"**
- `phase-common.sh` polls agent logs every 5 seconds for fatal patterns (quota exhaustion, auth failure, rate limits, billing issues)
- Check the agent's stdout log for the specific error
- Patterns detected: `exhausted your capacity`, `quota.*reset`, `rate.?limit`, `unauthorized`, `API key.*(invalid|expired|missing)`, etc.

**"All agents failed, aborting"**
- Every registered agent exited non-zero or was killed for fatal errors
- `wait_for_agents` returns 1 and the phase exits
- Check each agent's stdout log individually

**Lock contention: "Research agents are still running"**
- The orchestrator lock at `.claude/deep-research.lock` stores `PID:EPOCH`
- A lock is considered alive only if the PID exists AND the lock is less than 2 hours old
- Stale locks (>2 hours or dead PID) are automatically cleaned
- Manual fix: `rm .claude/deep-research.lock`

**State file staleness: session auto-cleaned**
- State files older than 5 hours are automatically removed
- The `started_at` timestamp in `.claude/deep-research.local.md` is checked on every hook invocation

**Session adoption: "Adopting orphaned research into new session"**
- If Claude Code restarts (new session ID) while research is in progress but no lock is held, the new session adopts the research automatically
- If a lock IS held by a live process, the new session skips (different orchestrator is running phases)

### Inspecting State

```bash
# Current state file
cat .claude/deep-research.local.md

# Lock status
cat .claude/deep-research.lock    # Format: PID:EPOCH

# Agent PIDs (while running)
cat research/<id>/agent-pids.txt

# Iteration state for an agent
cat research/<id>/claude-state.txt
cat research/<id>/gemini-state.txt
```

### Cancellation

Use `/cancel-research` which reads `agent-pids.txt` and kills all running agents.

Manual cancellation:

```bash
# Kill agents listed in PID file
cat research/<id>/agent-pids.txt | xargs kill 2>/dev/null
# Clean up state
rm -f .claude/deep-research.local.md .claude/deep-research.lock
```

## Key Architecture Decisions

### Unified iteration hook (`iteration-hook.sh`)

Claude and Gemini have different hook protocols — Claude's Stop hook expects `{"decision": "block"}` to continue (empty output + exit 0 to allow), while Gemini's AfterAgent hook expects `{"decision": "deny"}` to continue and `{"decision": "allow"}` to stop. Rather than maintaining two separate hook scripts, a single `iteration-hook.sh` uses the `RESEARCH_HOOK_FORMAT` env var to switch output format. Codex has no hook system at all, so it uses a bash loop wrapper (`codex-wrapper.sh`) instead.

### Shared phase library (`lib/phase-common.sh`)

The research and refinement phase scripts had heavily duplicated infrastructure — `log()`, agent PID tracking, wait loops, kill logic. This was extracted into `phase-common.sh` which provides an agent registry (`register_agent`/`agent_pid`/`agent_log`), PID recording for cancellation support, and a poll-based `wait_for_agents` with fatal error detection.

### Poll-based wait with fatal error detection

Rather than a simple `wait $PID`, agents are polled every 5 seconds. Each poll checks if the process exited (reap it) or if the process is alive but its logs contain fatal errors (kill it). This catches scenarios where an agent gets stuck in a retry loop against a quota/auth error that will never succeed.

### Lock file with PID:EPOCH format

The orchestrator lock stores `$$:$(date +%s)` to defend against PID reuse. A lock is only alive if the PID is still running AND the lock is less than 2 hours old. This prevents a scenario where a PID gets recycled by the OS and the lock appears live when the original holder is long gone.

### Session ID adoption vs rejection

When a new Claude Code session encounters an in-progress research state from a different session, it checks the lock. If the lock is alive (another session is actively running phases), it skips. If the lock is dead (the original session crashed), the new session adopts the research and continues from where it left off. This prevents both duplicate execution and orphaned research.

### Portable `sedi()` helper

macOS `sed -i` requires an empty string argument (`sed -i ''`) while GNU `sed -i` does not. The `sedi()` function in the orchestrator hook handles this transparently. Defined inline rather than sourced from a library because the orchestrator hook must be self-contained.

### Gemini sandboxing workaround

Gemini CLI runs in a sandbox that can't read files outside its working directory. The phase scripts copy input reports INTO a dedicated Gemini workspace directory, and copy the output report back out after Gemini finishes. This is why you see `gemini-workspace/` subdirectories and file copying in the phase scripts.

## Pitfalls & Lessons Learned

### Test authoring

1. **Env vars before a pipe apply to the left side only.** `VAR=x echo '{}' | bash script.sh` sets `VAR` on `echo`, not `bash`. Wrap in a subshell with `export` instead.

2. **Don't eval-source functions from scripts that read stdin.** The orchestrator hook has `HOOK_INPUT=$(cat)` at the top, so sourcing it (even partially with `sed -n`) can hang as the eval'd code tries to read stdin. Define test helpers inline instead.

3. **The iteration hook reads stdin.** The `run_hook` test helper must pipe something (even `echo '{}'`) into the hook, otherwise it blocks on `cat`.

### macOS / bash 3.2 compatibility

4. **No associative arrays.** macOS ships bash 3.2, which doesn't support `declare -A`. Use `eval`-based variable naming (e.g., `eval "AGENT_PID_${name}=\$pid"`) with accessor functions instead.

5. **No GNU `timeout`.** macOS lacks `timeout`. The smoke tests use a perl one-liner wrapper: `perl -e 'alarm shift; exec @ARGV' -- "$secs" "$@"`.

6. **`CLAUDECODE` env var must be `unset`, not emptied.** Claude Code checks for variable existence, not value. `CLAUDECODE=""` doesn't work — use `(unset CLAUDECODE; claude -p ...)` in a subshell.

### Agent-specific gotchas

7. **Claude smoke test takes ~35 seconds.** Even with Haiku and a trivial prompt, Claude CLI startup + response takes 30-35s. The smoke test timeout is 60s to account for this.

8. **Gemini CLI retries quota errors forever.** When Gemini hits quota exhaustion or rate limits, it enters an internal retry loop and the process never exits. The `check_log_for_fatal_errors()` function in `phase-common.sh` scans agent stdout logs every 5 seconds for fatal patterns and kills the agent immediately. Without this, a quota-exhausted Gemini will spin indefinitely.

9. **Zsh glob expansion on special characters.** If a research topic contains `?`, `*`, `[`, or other glob characters, zsh will try to expand them. The command template wraps `$ARGUMENTS` with `set -o noglob` / `set +o noglob` to prevent this.

### E2E testing workflow

10. **Always use `grep "^\["` to read progress logs.** The progress log can get polluted with agent stdout when Codex writes reports via heredoc (the `tee -a` in `log()` sometimes captures stray output). Filtering for timestamped `[` entries gives clean structured output.

11. **Kill orphaned agents after aborting.** Killing the e2e test script (`Ctrl-C` or `tmux kill-session`) does NOT automatically kill child agent processes. Always check for and kill orphaned `claude -p`, `codex exec`, and `gemini` processes afterward.

12. **Don't mix plugin cache and local scripts.** The `/deep-research` slash command runs scripts from `~/.claude/plugins/cache/...`. The `run-e2e-test.sh` script runs from the local `scripts/` directory. Running both against the same research workspace creates duplicate Phase 1 processes fighting over the same output files.
