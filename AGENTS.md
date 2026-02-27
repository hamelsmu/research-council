# Agent Instructions

## Before making changes

Run unit tests first to catch syntax errors early:

```bash
bash scripts/test-refactoring.sh
```

## After making changes

Run the full e2e test to verify agents aren't hanging and the pipeline completes:

```bash
# Clean up stale state, launch in tmux, monitor output
ps aux | grep -E "claude -p|codex exec|gemini " | grep -v grep | awk '{print $2}' | xargs kill 2>/dev/null
rm -f .claude/deep-research.local.md .claude/deep-research.lock
tmux new-session -d -s e2e 'bash scripts/run-e2e-test.sh "What is the history of chess?" 2>&1 | tee /tmp/e2e-test-output.log'
tail -f /tmp/e2e-test-output.log
```

The test takes ~10-15 minutes. See [testing.md](testing.md) for expected timelines, monitoring commands, troubleshooting, and pass criteria.
