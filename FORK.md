# Fork Documentation — tahsinrk/ralph

- **Created:** 2026-03-04
- **Origin:** Tahsin was evaluating Ralph Wiggum loop implementations after Vivek (Terminal Use founder) mentioned the pattern in a March 3, 2026 meeting as a well-known agent development technique. Seven implementations were researched. snarktank/ralph was chosen as the base for its fresh-context architecture and skill-based deployment. frankbria/ralph-claude-code provided reliability features missing from the original.

## What this fork adds over snarktank/ralph

### 1. Prompt mode (`--prompt`, `--prompt-file`)

snarktank/ralph requires `prd.json` — the entire loop is built around picking the next incomplete story. This fork adds plain prompt mode for ad-hoc tasks where you don't have or want a PRD.

**Why:** Not every task warrants a structured PRD. Bug fixes, quick features, and exploratory work benefit from the fresh-context loop without the overhead of story decomposition.

**How:**
```bash
# Inline prompt
./ralph.sh --prompt "Fix the authentication bug in login.py" 15

# File-based prompt
./ralph.sh --prompt-file tasks/build-dashboard.md 20

# PRD mode (unchanged — if prd.json exists)
./ralph.sh 10
```

When prompt mode is active, ralph generates agent instructions on the fly that tell Claude to: read `progress.txt`, do the work, append progress, signal `<promise>COMPLETE</promise>` when done. No `prd.json` needed.

### 2. Circuit breaker (from frankbria/ralph-claude-code)

Stops the loop when Claude is stuck rather than burning through all iterations.

**Triggers:**
- 3 consecutive iterations with no progress (no files changed, no stories completed)
- 5 consecutive iterations hitting the same error

**Why:** Without this, a stuck loop burns through all max_iterations, wasting API credits and time. The original snarktank/ralph has no stuck-loop detection.

**Configurable via environment variables:**
```bash
CB_NO_PROGRESS_THRESHOLD=3   # iterations with no progress before stopping
CB_SAME_ERROR_THRESHOLD=5    # same error repeated before stopping
```

### 3. Dual-exit gate (from frankbria/ralph-claude-code)

Prevents premature exits when Claude says "done" but isn't.

**How it works:**
- In **prompt mode**: requires 2+ `<promise>COMPLETE</promise>` signals across iterations. A single "I'm done" isn't trusted — Claude must confirm completion across two fresh context windows.
- In **PRD mode**: trusts a single completion signal because `prd.json` story tracking provides independent confirmation (all stories `passes: true`).

**Why:** Claude commonly says "I'm done" mid-task. The dual-exit gate catches this in prompt mode. PRD mode doesn't need it because the story tracking already serves as the second confirmation.

### 4. Rate-limit detection (from frankbria/ralph-claude-code)

Detects API rate limits and backs off instead of failing.

**Three-layer detection:**
1. JSON structural: checks output for `"rate_limit_event"` with `"status": "rejected"`
2. Text fallback: checks last 30 lines of output for rate-limit language, filtering out echoed file content (`"type": "user"`, `"tool_result"` lines) to avoid false positives
3. On detection: waits 60 seconds then retries

### 5. Default tool changed to Claude

snarktank defaults to `amp`. This fork defaults to `claude` since that's what we use.

### 6. CLAUDECODE env var unset

Claude Code sets a `CLAUDECODE` environment variable to prevent nested sessions. ralph.sh unsets it because it uses `claude --print` (non-interactive pipe mode) which doesn't conflict with the parent session. Without this fix, ralph.sh fails when invoked from within a Claude Code session.

### 7. Automated upstream update check

GitHub Action (`.github/workflows/check-upstream.yml`) runs weekly (Monday 9am UTC) and opens an issue labeled `upstream-update` when snarktank/ralph has new commits. Deduplicates — won't create a new issue if one is already open.

## What was NOT changed

- **CLAUDE.md** (agent instructions for PRD mode) — kept as-is
- **prompt.md** / **AGENTS.md** — kept for Amp compatibility
- **skills/prd/** and **skills/ralph/** — kept as-is (PRD generation and conversion)
- **Archive system** — kept as-is
- **progress.txt** format — kept as-is
- **prd.json** format — kept as-is

## Upstream tracking

```bash
# Remotes
origin    https://github.com/tahsinrk/ralph.git
upstream  https://github.com/snarktank/ralph.git

# Check for upstream updates
git fetch upstream
git log upstream/main --oneline -10

# Selectively merge updates
git merge upstream/main  # or cherry-pick specific commits
```

## What we evaluated and rejected

| Implementation | Stars | Why rejected |
|---|---|---|
| Official Anthropic plugin (`anthropics/claude-code/plugins/ralph-wiggum`) | n/a | Same-session context degradation (no fresh context). Currently broken (CVE-2025-54795). |
| frankbria/ralph-claude-code (full install) | 7.5K | Heavyweight standalone CLI tool with global install. Overkill — we only needed the reliability features. |
| gmickel/flow-next | 538 | Only plugin with fresh context, but low adoption. Cross-model review adds cost. |
| Th0rgal/open-ralph-wiggum | 1.1K | npm CLI tool, not a skill. Multi-agent flexibility we don't need. |
| mikeyobrien/ralph-orchestrator | 2K | Web dashboard, Rust backend, hat-based persona system. Overengineered. |
| AnandChowdhary/continuous-claude | 1.2K | PR-focused only, not general-purpose. |

Full research: `memory-topics/session-logs/2026-03-04-tdd-skill-ralph-fork-readme-standard.md`

## Source attribution

- **Base:** [snarktank/ralph](https://github.com/snarktank/ralph) (MIT license, 12K stars)
- **Circuit breaker, dual-exit gate, rate-limit detection:** Adapted from [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) (MIT license, 7.5K stars)
- **Ralph Wiggum pattern:** Originated by [Geoffrey Huntley](https://ghuntley.com/ralph/)
