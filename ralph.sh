#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop with fresh context per iteration
# Fork of snarktank/ralph with frankbria reliability features
#
# Usage:
#   ./ralph.sh [--tool amp|claude] [--prompt "task description"] [--prompt-file path] [max_iterations]
#
# Modes:
#   PRD mode (default): Reads prd.json, works through stories one at a time
#   Prompt mode: Plain prompt, no PRD. Uses completion signal only.
#     --prompt "Build feature X"
#     --prompt-file path/to/task.md

set -e

# Unset CLAUDECODE to allow spawning claude --print from within a Claude Code session.
# ralph.sh uses non-interactive --print mode which doesn't conflict with parent sessions.
unset CLAUDECODE

# ===== Configuration =====
TOOL="claude"  # Default to claude
MAX_ITERATIONS=10
PROMPT_MODE=""
PROMPT_TEXT=""
PROMPT_FILE=""

# Circuit breaker thresholds (from frankbria)
CB_NO_PROGRESS_THRESHOLD=${CB_NO_PROGRESS_THRESHOLD:-3}
CB_SAME_ERROR_THRESHOLD=${CB_SAME_ERROR_THRESHOLD:-5}

# ===== Argument parsing =====
while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    --prompt)
      PROMPT_MODE="inline"
      PROMPT_TEXT="$2"
      shift 2
      ;;
    --prompt=*)
      PROMPT_MODE="inline"
      PROMPT_TEXT="${1#*=}"
      shift
      ;;
    --prompt-file)
      PROMPT_MODE="file"
      PROMPT_FILE="$2"
      shift 2
      ;;
    --prompt-file=*)
      PROMPT_MODE="file"
      PROMPT_FILE="${1#*=}"
      shift
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

# Validate tool choice
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp' or 'claude'."
  exit 1
fi

# Validate prompt mode
if [[ "$PROMPT_MODE" == "file" && ! -f "$PROMPT_FILE" ]]; then
  echo "Error: Prompt file not found: $PROMPT_FILE"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
STATE_DIR="$SCRIPT_DIR/.ralph-state"

# Determine mode
if [[ -n "$PROMPT_MODE" ]]; then
  MODE="prompt"
elif [[ -f "$PRD_FILE" ]]; then
  MODE="prd"
else
  echo "Error: No prd.json found and no --prompt or --prompt-file specified."
  echo "Usage:"
  echo "  PRD mode:    Create prd.json then run ./ralph.sh"
  echo "  Prompt mode: ./ralph.sh --prompt \"Build feature X\""
  echo "  File mode:   ./ralph.sh --prompt-file path/to/task.md"
  exit 1
fi

# ===== State directory for circuit breaker =====
mkdir -p "$STATE_DIR"

# ===== Circuit breaker functions (adapted from frankbria) =====
no_progress_count=0
same_error_count=0
last_error=""

check_circuit_breaker() {
  if [[ $no_progress_count -ge $CB_NO_PROGRESS_THRESHOLD ]]; then
    echo ""
    echo "CIRCUIT BREAKER: $CB_NO_PROGRESS_THRESHOLD consecutive iterations with no progress."
    echo "Ralph is stuck. Stopping to avoid wasting resources."
    echo "Check $PROGRESS_FILE for what was accomplished."
    exit 1
  fi
  if [[ $same_error_count -ge $CB_SAME_ERROR_THRESHOLD ]]; then
    echo ""
    echo "CIRCUIT BREAKER: Same error repeated $CB_SAME_ERROR_THRESHOLD times."
    echo "Ralph is stuck on: $last_error"
    echo "Stopping. Manual intervention needed."
    exit 1
  fi
}

detect_progress() {
  local output="$1"
  local files_changed
  files_changed=$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')

  # Progress if: files changed, or completion signal found
  if [[ "$files_changed" -gt 0 ]]; then
    no_progress_count=0
    same_error_count=0
    return 0
  fi

  # Check for meaningful output patterns (story completed, test passed, etc.)
  if echo "$output" | grep -qiE "passes.*true|story.*complete|implemented|committed"; then
    no_progress_count=0
    return 0
  fi

  # No progress detected
  no_progress_count=$((no_progress_count + 1))

  # Check for repeated errors
  local current_error
  current_error=$(echo "$output" | grep -iE "^error:|^ERROR:|failed|exception" | tail -1)
  if [[ -n "$current_error" && "$current_error" == "$last_error" ]]; then
    same_error_count=$((same_error_count + 1))
  else
    same_error_count=1
    last_error="$current_error"
  fi

  return 1
}

# ===== Dual-exit gate (adapted from frankbria) =====
completion_indicators=0

check_exit_condition() {
  local output="$1"

  # Check for explicit completion signal
  if echo "$output" | grep -q "<promise>COMPLETE</promise>"; then
    completion_indicators=$((completion_indicators + 1))
  fi

  # Dual gate: need 2+ completion signals (prevents premature "I'm done")
  if [[ $completion_indicators -ge 2 ]]; then
    echo ""
    echo "DUAL-EXIT GATE: Completion confirmed across $completion_indicators iterations."
    return 0
  fi

  # Single signal on first occurrence: trust it for PRD mode (stories tracked),
  # but for prompt mode require confirmation
  if [[ $completion_indicators -ge 1 && "$MODE" == "prd" ]]; then
    # In PRD mode, the prd.json tracking provides the second confirmation
    return 0
  fi

  return 1
}

# ===== Rate-limit detection =====
check_rate_limit() {
  local output="$1"

  # Check for Claude API rate limit signals
  if echo "$output" | grep -q '"rate_limit_event"'; then
    if echo "$output" | grep '"rate_limit_event"' | tail -1 | grep -qE '"status"\s*:\s*"rejected"'; then
      echo ""
      echo "RATE LIMIT: Claude API usage limit reached."
      echo "Waiting 60 seconds before retrying..."
      sleep 60
      return 1
    fi
  fi

  # Text-based fallback (filter out echoed file content)
  if tail -30 <<< "$output" 2>/dev/null | \
    grep -vE '"type"\s*:\s*"user"' | \
    grep -v '"tool_result"' | \
    grep -qi "5.*hour.*limit\|limit.*reached.*try.*back\|usage.*limit.*reached" 2>/dev/null; then
    echo ""
    echo "RATE LIMIT: Usage limit detected in output."
    echo "Waiting 60 seconds before retrying..."
    sleep 60
    return 1
  fi

  return 0
}

# ===== Build prompt for prompt mode =====
build_prompt_mode_instructions() {
  local task_text=""

  if [[ "$PROMPT_MODE" == "inline" ]]; then
    task_text="$PROMPT_TEXT"
  elif [[ "$PROMPT_MODE" == "file" ]]; then
    task_text=$(cat "$PROMPT_FILE")
  fi

  cat <<PROMPT_EOF
# Ralph Agent Instructions (Prompt Mode)

You are an autonomous coding agent working iteratively on a task.
Each iteration gives you a fresh context window. You have no memory of previous iterations.

## Your Task

$task_text

## State Files

- Read \`progress.txt\` first (if it exists) to see what previous iterations accomplished
- After completing work, append your progress to \`progress.txt\`

## Progress Report Format

APPEND to progress.txt (never replace, always append):
\`\`\`
## [Date/Time] - Iteration Progress
- What was implemented
- Files changed
- **Learnings for future iterations:**
  - Patterns discovered
  - Gotchas encountered
  - What still needs to be done
---
\`\`\`

## Quality Requirements

- ALL commits must pass quality checks (typecheck, lint, test)
- Do NOT commit broken code
- Keep changes focused and minimal
- Follow existing code patterns

## Stop Condition

When the task is FULLY complete (not partially), reply with:
<promise>COMPLETE</promise>

If work remains, end your response normally. Another iteration will continue.

## Important

- Commit frequently
- Keep CI green
- Read progress.txt before starting to avoid redoing work
PROMPT_EOF
}

# ===== Archive previous run (PRD mode only) =====
if [[ "$MODE" == "prd" ]]; then
  if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
    CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
    LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

    if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
      DATE=$(date +%Y-%m-%d)
      FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
      ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

      echo "Archiving previous run: $LAST_BRANCH"
      mkdir -p "$ARCHIVE_FOLDER"
      [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
      [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
      echo "   Archived to: $ARCHIVE_FOLDER"

      echo "# Ralph Progress Log" > "$PROGRESS_FILE"
      echo "Started: $(date)" >> "$PROGRESS_FILE"
      echo "---" >> "$PROGRESS_FILE"
    fi
  fi

  # Track current branch
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

echo "Starting Ralph - Tool: $TOOL - Mode: $MODE - Max iterations: $MAX_ITERATIONS"

# ===== Main loop =====
for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL, $MODE mode)"
  echo "==============================================================="

  # Check circuit breaker before each iteration
  check_circuit_breaker

  # Run the selected tool
  if [[ "$MODE" == "prompt" ]]; then
    # Prompt mode: generate instructions on the fly
    INSTRUCTIONS=$(build_prompt_mode_instructions)
    if [[ "$TOOL" == "amp" ]]; then
      OUTPUT=$(echo "$INSTRUCTIONS" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr) || true
    else
      OUTPUT=$(echo "$INSTRUCTIONS" | claude --dangerously-skip-permissions --print 2>&1 | tee /dev/stderr) || true
    fi
  else
    # PRD mode: use CLAUDE.md / prompt.md
    if [[ "$TOOL" == "amp" ]]; then
      OUTPUT=$(cat "$SCRIPT_DIR/prompt.md" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr) || true
    else
      OUTPUT=$(claude --dangerously-skip-permissions --print < "$SCRIPT_DIR/CLAUDE.md" 2>&1 | tee /dev/stderr) || true
    fi
  fi

  # Check for rate limiting
  check_rate_limit "$OUTPUT" || continue

  # Check for progress (circuit breaker)
  detect_progress "$OUTPUT" || true

  # Check exit condition (dual-exit gate)
  if check_exit_condition "$OUTPUT"; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi

  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
