---
description: "Launch deep research across Claude, Codex, and Gemini with cross-pollination"
argument-hint: "[--test] <research topic>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - WebSearch
  - WebFetch
---

First, run the setup script to validate prerequisites and create the research workspace. **IMPORTANT: Run this in the foreground (do NOT use run_in_background).** You need to read the output to check for errors.

```bash
set -o noglob; bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-research.sh" $ARGUMENTS; _rc=$?; set +o noglob; (exit $_rc)
```

If setup fails, help the user fix the issue (install missing CLIs, set API keys, etc.) and DO NOT proceed further.

If setup succeeds, it will print the research ID and a progress log path. Tell the user:

1. The research council is now active with 3 AI agents (Claude, Codex, Gemini)
2. They can monitor progress in another terminal with the `tail -f` command shown
3. When all agents finish their research and cross-pollination refinement, you will synthesize the final report

Then **finish your response** — the Stop hook will automatically launch all research agents. You do not need to run any additional commands.

When you are given the synthesis prompt (after the research agents complete), read ALL three refined reports carefully and write a comprehensive synthesis to the specified path. Structure it as:

1. **Executive Summary** — the most important findings across all three investigations
2. **Key Findings** — organized by THEME (not by source agent), with the strongest evidence from all reports
3. **Areas of Consensus** — where all three agents agree, with combined evidence
4. **Areas of Disagreement** — where agents differed, with analysis of why
5. **Novel Insights** — unique findings from the cross-pollination refinement round
6. **Open Questions** — what remains uncertain even after three independent investigations
7. **Sources** — comprehensive, deduplicated list from all reports
8. **Methodology** — brief note on the multi-agent research process used
