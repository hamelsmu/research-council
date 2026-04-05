#!/usr/bin/env bash
# Shared infrastructure for phase runner scripts (research + refinement).
#
# Expected globals before sourcing:
#   WORKSPACE       — absolute path to the research workspace
#   PROGRESS_LOG    — absolute path to the progress log
#   PHASE_LABEL     — e.g. "Phase 1" or "Phase 2" (used in log messages)
#
# Provides:
#   log()                    — timestamped logging to stdout + progress log
#   agent_pid(name)          — get PID for a registered agent
#   agent_log(name)          — get log path for a registered agent
#   register_agent()         — register an agent name, PID, and log path
#   record_pids()            — write agent-pids.txt for cancel support
#   write_claude_settings()  — write Claude Stop hook settings JSON
#   wait_for_agents()        — poll-based wait with log monitoring for fatal errors
#                              Sets: FAILURES (count of failed agents)

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$PROGRESS_LOG"
}

# ── Agent registry ────────────────────────────────────────────────────────
_AGENT_NAMES=""
_AGENT_COUNT=0

register_agent() {
  local name="$1" pid="$2" logfile="$3"
  _AGENT_NAMES="${name} ${_AGENT_NAMES}"
  eval "_AGENT_PID_${name}=\$pid"
  eval "_AGENT_LOG_${name}=\$logfile"
  _AGENT_COUNT=$((_AGENT_COUNT + 1))
}

agent_pid() { eval echo "\$_AGENT_PID_$1"; }
agent_log() { eval echo "\$_AGENT_LOG_$1"; }

record_pids() {
  {
    for agent in $_AGENT_NAMES; do
      agent_pid "$agent"
    done
  } > "${WORKSPACE}/agent-pids.txt"
}

# ── Settings writers ─────────────────────────────────────────────────────
# Write Claude settings JSON with Stop hook pointing to iteration-hook.sh.
# Usage: write_claude_settings <output_file> <plugin_root>
write_claude_settings() {
  cat > "$1" << EOF
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "${2}/scripts/iteration-hook.sh",
        "timeout": 120
      }]
    }]
  }
}
EOF
}

# ── Fatal error detection ────────────────────────────────────────────────
# Check an agent's stdout log for patterns that indicate unrecoverable errors.
# Returns 0 if a fatal pattern is found, 1 if clean.
check_log_for_fatal_errors() {
  local logfile="$1"
  [ ! -f "$logfile" ] && return 1
  # Patterns that mean the agent will never succeed (quota, auth, rate limits)
  grep -qiE \
    'exhausted your capacity|quota.*reset|rate.?limit|unauthorized|authentication failed|Interactive consent could not be obtained|API key.*(invalid|expired|missing)|billing.*not active|account.*suspended|permission denied|PERMISSION_DENIED|RESOURCE_EXHAUSTED|UNAUTHENTICATED|INVALID_ARGUMENT.*api.key' \
    "$logfile" 2>/dev/null
}

# Kill a running agent and all its child processes.
# Tries process-group kill first (covers child CLIs spawned by wrapper
# subshells), then falls back to killing just the PID.
kill_agent() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || return 0

  # Try to kill the entire process group rooted at $pid.
  # The wrapper subshells run in their own pgroup when launched with
  # set -m or via ( ... ) &, so "kill -- -$pid" targets that group.
  # If the PGID doesn't match $pid (not a group leader), fall back to
  # walking /proc / pgrep for descendants.
  if kill -- -"$pid" 2>/dev/null; then
    sleep 2
    kill -0 "$pid" 2>/dev/null && kill -9 -- -"$pid" 2>/dev/null || true
  else
    # Fallback: kill descendants individually via pgrep, then the parent
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
      kill "$child" 2>/dev/null || true
    done
    kill "$pid" 2>/dev/null || true
    sleep 2
    for child in $(pgrep -P "$pid" 2>/dev/null); do
      kill -9 "$child" 2>/dev/null || true
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
}

# ── Poll-based wait with log monitoring ──────────────────────────────────
# Polls every 5 seconds. For each agent checks:
#   1. Has the process exited? (reap it)
#   2. Is the process alive but its logs show fatal errors? (kill it)
# Sets FAILURES to total number of failed agents.
wait_for_agents() {
  FAILURES=0

  if [ "$_AGENT_COUNT" -eq 0 ]; then
    return
  fi

  for agent in $_AGENT_NAMES; do
    eval "_REAPED_${agent}=false"
  done

  local reaped_count=0

  # Poll until all agents are reaped
  while [ "$reaped_count" -lt "$_AGENT_COUNT" ]; do
    sleep 5
    for agent in $_AGENT_NAMES; do
      eval "local already_reaped=\$_REAPED_${agent}"
      [ "$already_reaped" = true ] && continue

      local pid
      pid=$(agent_pid "$agent")
      local logfile
      logfile=$(agent_log "$agent")

      if ! kill -0 "$pid" 2>/dev/null; then
        # Process exited — reap it
        wait "$pid" 2>/dev/null
        local exit_code=$?
        eval "_REAPED_${agent}=true"
        reaped_count=$((reaped_count + 1))
        if [ "$exit_code" -ne 0 ]; then
          log "${PHASE_LABEL}: ${agent} agent failed (exit ${exit_code})"
          tail -20 "$logfile" 2>/dev/null | while IFS= read -r line; do
            log "  ${agent}> ${line}"
          done
          FAILURES=$((FAILURES + 1))
        else
          log "${PHASE_LABEL}: ${agent} agent completed successfully"
        fi
      elif check_log_for_fatal_errors "$logfile"; then
        # Process still running but logs show fatal errors — kill it
        log "${PHASE_LABEL}: FATAL ERROR in ${agent} logs — killing agent"
        tail -20 "$logfile" 2>/dev/null | while IFS= read -r line; do
          log "  ${agent}> ${line}"
        done
        kill_agent "$pid"
        wait "$pid" 2>/dev/null || true
        eval "_REAPED_${agent}=true"
        reaped_count=$((reaped_count + 1))
        FAILURES=$((FAILURES + 1))
      fi
    done
  done

  if [ "$FAILURES" -ge "$_AGENT_COUNT" ]; then
    rm -f "${WORKSPACE}/agent-pids.txt"
    log "${PHASE_LABEL}: FATAL — all agents failed, aborting"
    return 1
  fi
}
