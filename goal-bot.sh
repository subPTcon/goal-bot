#!/usr/bin/env bash

set -e
set -u
set -o pipefail

usage() {
  echo "Usage: bash goal-bot.sh goal.yaml" >&2
}

die() {
  echo "goal-bot: $*" >&2
  exit 1
}

now_epoch() {
  date +%s
}

log_line() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

CURRENT_CHILD_PID=""
CURRENT_HEARTBEAT_PID=""
CURRENT_MONITOR_PID=""

start_stream_monitor() {
  local output_file="$1"
  local label="$2"

  python3 -u - "$output_file" "$label" "$LOG_FILE" <<'PY' &
import json
import os
import sys
import time

path, label, log_path = sys.argv[1], sys.argv[2], sys.argv[3]
offset = 0
seen = set()

def emit(message):
    line = f"goal-bot: {message}"
    print(line, flush=True)
    with open(log_path, "a", encoding="utf-8") as log:
        log.write(line + "\n")

def shorten(text, limit=220):
    text = " ".join(str(text).split())
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."

def describe_tool(name, tool_input):
    tool_input = tool_input or {}
    if name == "Bash":
        desc = tool_input.get("description")
        command = tool_input.get("command", "")
        if desc:
            return f"Bash: {shorten(desc, 120)} | {shorten(command, 180)}"
        return f"Bash: {shorten(command, 220)}"
    if name in ("Read", "Write", "Edit"):
        target = tool_input.get("file_path") or tool_input.get("path") or ""
        return f"{name}: {target}"
    if name in ("Glob", "Grep"):
        pattern = tool_input.get("pattern") or tool_input.get("glob") or ""
        path = tool_input.get("path") or ""
        return f"{name}: {pattern} {path}".strip()
    return f"{name}: {shorten(tool_input, 220)}"

emit(f"monitoring {label} stream")

while True:
    if not os.path.exists(path):
        time.sleep(0.5)
        continue

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        f.seek(offset)
        lines = f.readlines()
        offset = f.tell()

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        event_id = event.get("uuid") or line[:80]
        if event_id in seen:
            continue
        seen.add(event_id)

        event_type = event.get("type")
        if event_type == "system" and event.get("subtype") == "init":
            emit(f"claude init: cwd={event.get('cwd')} model={event.get('model')} permission={event.get('permissionMode')}")
            continue

        if event_type == "assistant":
            message = event.get("message") or {}
            for item in message.get("content") or []:
                item_type = item.get("type")
                if item_type == "text":
                    emit(f"claude says: {shorten(item.get('text', ''), 260)}")
                elif item_type == "tool_use":
                    emit(f"claude tool: {describe_tool(item.get('name'), item.get('input'))}")
            continue

        if event_type == "user":
            result = event.get("tool_use_result")
            if result:
                stdout = result.get("stdout") or ""
                stderr = result.get("stderr") or ""
                if stdout:
                    emit(f"tool result stdout: {shorten(stdout, 260)}")
                if stderr:
                    emit(f"tool result stderr: {shorten(stderr, 260)}")
            continue

        if event_type == "result":
            emit(
                "claude result: "
                f"subtype={event.get('subtype')} "
                f"turns={event.get('num_turns')} "
                f"duration_ms={event.get('duration_ms')} "
                f"cost_usd={event.get('total_cost_usd')} "
                f"terminal={event.get('terminal_reason')}"
            )
            continue

    time.sleep(0.5)
PY
  CURRENT_MONITOR_PID=$!
}

wait_with_heartbeat() {
  local label="$1"
  local output_file="$2"
  local start
  local elapsed
  local heartbeat_pid
  local status

  start="$(now_epoch)"
  start_stream_monitor "$output_file" "$label"
  (
    trap - INT TERM
    local last_bytes=0
    local current_bytes=0
    local last_change
    local idle_for
    last_change="$(now_epoch)"
    while true; do
      sleep 15
      elapsed="$(( $(now_epoch) - start ))"
      if [ -f "$output_file" ]; then
        current_bytes="$(wc -c < "$output_file" | tr -d ' ')"
        if [ "$current_bytes" != "$last_bytes" ]; then
          last_bytes="$current_bytes"
          last_change="$(now_epoch)"
        fi
        idle_for="$(( $(now_epoch) - last_change ))"
        printf 'goal-bot: still waiting for %s (%ss elapsed, %s lines, %s bytes)...\n' \
          "$label" \
          "$elapsed" \
          "$(wc -l < "$output_file" | tr -d ' ')" \
          "$current_bytes"
        if [ "$CLAUDE_IDLE_TIMEOUT" -gt 0 ] && [ "$idle_for" -ge "$CLAUDE_IDLE_TIMEOUT" ]; then
          echo "goal-bot: $label stream idle for ${idle_for}s; terminating claude child $CURRENT_CHILD_PID."
          log_line "$label stream idle for ${idle_for}s; terminating claude child $CURRENT_CHILD_PID"
          kill -TERM "$CURRENT_CHILD_PID" >/dev/null 2>&1 || true
          sleep 3
          kill -KILL "$CURRENT_CHILD_PID" >/dev/null 2>&1 || true
          exit 0
        fi
      else
        echo "goal-bot: still waiting for $label (${elapsed}s elapsed)..."
      fi
    done
  ) &
  heartbeat_pid=$!
  CURRENT_HEARTBEAT_PID="$heartbeat_pid"

  set +e
  wait "$CURRENT_CHILD_PID"
  status=$?
  set -e

  kill "$heartbeat_pid" >/dev/null 2>&1 || true
  wait "$heartbeat_pid" >/dev/null 2>&1 || true
  if [ -n "${CURRENT_MONITOR_PID:-}" ]; then
    kill "$CURRENT_MONITOR_PID" >/dev/null 2>&1 || true
    wait "$CURRENT_MONITOR_PID" >/dev/null 2>&1 || true
  fi
  CURRENT_CHILD_PID=""
  CURRENT_HEARTBEAT_PID=""
  CURRENT_MONITOR_PID=""

  return "$status"
}

run_command_capture() {
  local command="$1"
  local output_file="$2"
  local status_file="$3"

  set +e
  (
    cd "$WORK_DIR" || exit 127
    bash -lc "$command"
  ) > "$output_file" 2>&1
  local status=$?
  set -e

  printf '%s' "$status" > "$status_file"
}

extract_session_id() {
  local json_file="$1"

  if command -v jq >/dev/null 2>&1; then
    jq -r 'select(type == "object") | .session_id // .sessionId // empty' "$json_file" | tail -1
  else
    python3 - "$json_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    text = f.read().strip()

session_id = ""
if text:
    try:
        data = json.loads(text)
        session_id = data.get("session_id") or data.get("sessionId") or ""
    except json.JSONDecodeError:
        for line in text.splitlines():
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            session_id = data.get("session_id") or data.get("sessionId") or session_id

print(session_id)
PY
  fi
}

send_feedback() {
  local feedback="$1"
  local response_file="$2"
  local prompt

  prompt="$(build_feedback_prompt "$feedback")"
  (
    cd "$WORK_DIR" || exit 127
    claude -p "$prompt" "${CLAUDE_FEEDBACK_ARGS[@]}" --resume "$SESSION_ID"
  ) > "$response_file" 2>&1 &
  CURRENT_CHILD_PID=$!

  wait_with_heartbeat "claude feedback" "$response_file"
}

build_initial_prompt() {
  cat <<EOF
$DESCRIPTION

Automation instructions from goal-bot:
- You are running inside an automated compile/test/fix loop.
- Make a concrete code change quickly. Do not spend the session exhaustively exploring tests.
- Read only the files needed to understand the build contract, then implement a buildable solution.
- For this first pass, prefer creating or editing source files over broad test inventory.
- Do not enumerate every test case. The outer loop will run setup/evaluate and feed failures back to you.
- Keep tool use focused: write the implementation, optionally run one small sanity check, then stop.
- If src/ is empty, create the required source files immediately after minimal context gathering.
EOF
}

build_feedback_prompt() {
  local feedback="$1"

  cat <<EOF
The previous attempt failed in the automated goal-bot loop.

Your task now:
- Use the failure output below to make the smallest useful code change.
- Do not re-read broad specs or enumerate the whole test suite unless the failure requires it.
- Prefer editing source files over additional investigation.
- After making the fix, stop; the outer loop will compile and test again.

$feedback
EOF
}

on_interrupt() {
  echo
  echo "goal-bot: interrupted, exiting gracefully."
  if [ -n "${CURRENT_CHILD_PID:-}" ] && kill -0 "$CURRENT_CHILD_PID" >/dev/null 2>&1; then
    echo "goal-bot: stopping child process $CURRENT_CHILD_PID."
    kill -TERM "$CURRENT_CHILD_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "${CURRENT_HEARTBEAT_PID:-}" ] && kill -0 "$CURRENT_HEARTBEAT_PID" >/dev/null 2>&1; then
    kill -TERM "$CURRENT_HEARTBEAT_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "${CURRENT_MONITOR_PID:-}" ] && kill -0 "$CURRENT_MONITOR_PID" >/dev/null 2>&1; then
    kill -TERM "$CURRENT_MONITOR_PID" >/dev/null 2>&1 || true
  fi
  log_line "Interrupted by user"
  exit 130
}

trap on_interrupt INT TERM

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

GOAL_FILE="$1"
[ -f "$GOAL_FILE" ] || die "goal file not found: $GOAL_FILE"

SCRIPT_ROOT="$(pwd)"
LOG_DIR="$SCRIPT_ROOT/.goal-bot"
LOG_FILE="$LOG_DIR/run.log"
mkdir -p "$LOG_DIR"

CONFIG_JSON="$(python3 - "$GOAL_FILE" <<'PY'
import json
import os
import sys

goal_file = sys.argv[1]

def strip_comment(line):
    in_single = False
    in_double = False
    escaped = False
    for i, ch in enumerate(line):
        if escaped:
            escaped = False
            continue
        if ch == "\\" and in_double:
            escaped = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            return line[:i].rstrip()
    return line.rstrip()

def parse_scalar(value):
    value = value.strip()
    if value == "":
        return {}
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
        return int(value)
    return value

def parse_simple_yaml(path):
    with open(path, "r", encoding="utf-8") as f:
        raw_lines = f.read().splitlines()

    root = {}
    stack = [(-1, root)]
    i = 0
    while i < len(raw_lines):
        raw = raw_lines[i]
        if not raw.strip() or raw.lstrip().startswith("#"):
            i += 1
            continue

        line = strip_comment(raw)
        if not line.strip():
            i += 1
            continue
        indent = len(line) - len(line.lstrip(" "))
        text = line.strip()
        if ":" not in text:
            i += 1
            continue

        key, value = text.split(":", 1)
        key = key.strip()
        value = value.strip()

        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]

        if value in ("|", ">"):
            block_lines = []
            i += 1
            block_indent = None
            while i < len(raw_lines):
                next_raw = raw_lines[i]
                if not next_raw.strip():
                    block_lines.append("")
                    i += 1
                    continue
                next_indent = len(next_raw) - len(next_raw.lstrip(" "))
                if next_indent <= indent:
                    break
                if block_indent is None:
                    block_indent = next_indent
                block_lines.append(next_raw[block_indent:])
                i += 1
            parent[key] = "\n".join(block_lines).rstrip("\n")
            continue

        parsed = parse_scalar(value)
        parent[key] = parsed
        if isinstance(parsed, dict):
            stack.append((indent, parsed))
        i += 1

    return root

data = parse_simple_yaml(goal_file)

config = data.get("config") or {}
goal = data.get("goal") or {}
setup = data.get("setup") or {}
evaluate = data.get("evaluate") or {}

description = goal.get("description")
setup_command = setup.get("command")
evaluate_command = evaluate.get("command")

missing = []
if not description:
    missing.append("goal.description")
if not setup_command:
    missing.append("setup.command")
if not evaluate_command:
    missing.append("evaluate.command")
if missing:
    print("Missing required field(s): " + ", ".join(missing), file=sys.stderr)
    sys.exit(11)

goal_dir = os.path.dirname(os.path.abspath(goal_file)) or os.getcwd()
launch_dir = os.getcwd()
working_dir = config.get("working_dir") or "."
if not os.path.isabs(working_dir):
    launch_relative = os.path.abspath(os.path.join(launch_dir, working_dir))
    goal_relative = os.path.abspath(os.path.join(goal_dir, working_dir))
    if os.path.isdir(launch_relative):
        working_dir = launch_relative
    elif os.path.isdir(goal_relative):
        working_dir = goal_relative
    else:
        working_dir = launch_relative

out = {
    "description": str(description),
    "setup_command": str(setup_command),
    "evaluate_command": str(evaluate_command),
    "max_iterations": int(config.get("max_iterations", 10)),
    "max_turns": int(config.get("max_turns_per_iteration", config.get("max_turns", 50))),
    "max_turns_initial": int(config.get("max_turns_initial", config.get("max_turns_per_iteration", config.get("max_turns", 50)))),
    "max_turns_feedback": int(config.get("max_turns_feedback", config.get("max_turns_per_iteration", config.get("max_turns", 50)))),
    "claude_idle_timeout": int(config.get("claude_idle_timeout_seconds", 90)),
    "working_dir": working_dir,
    "model": str(config.get("model") or ""),
}
print(json.dumps(out))
PY
)" || exit $?

DESCRIPTION="$(printf '%s' "$CONFIG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["description"])')"
SETUP_COMMAND="$(printf '%s' "$CONFIG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["setup_command"])')"
EVALUATE_COMMAND="$(printf '%s' "$CONFIG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["evaluate_command"])')"
MAX_ITERATIONS="$(printf '%s' "$CONFIG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["max_iterations"])')"
MAX_TURNS="$(printf '%s' "$CONFIG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["max_turns"])')"
MAX_TURNS_INITIAL="$(printf '%s' "$CONFIG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["max_turns_initial"])')"
MAX_TURNS_FEEDBACK="$(printf '%s' "$CONFIG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["max_turns_feedback"])')"
CLAUDE_IDLE_TIMEOUT="$(printf '%s' "$CONFIG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["claude_idle_timeout"])')"
WORK_DIR="$(printf '%s' "$CONFIG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["working_dir"])')"
MODEL="$(printf '%s' "$CONFIG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["model"])')"

[ -d "$WORK_DIR" ] || die "working_dir not found: $WORK_DIR"
command -v claude >/dev/null 2>&1 || die "claude command not found"

CLAUDE_COMMON_ARGS=(
  --output-format stream-json
  --verbose
  --allowedTools "Read,Write,Edit,Bash,Glob,Grep"
  --permission-mode acceptEdits
)

if [ -n "$MODEL" ]; then
  CLAUDE_COMMON_ARGS+=(--model "$MODEL")
fi

CLAUDE_INITIAL_ARGS=(--max-turns "$MAX_TURNS_INITIAL" "${CLAUDE_COMMON_ARGS[@]}")
CLAUDE_FEEDBACK_ARGS=(--max-turns "$MAX_TURNS_FEEDBACK" "${CLAUDE_COMMON_ARGS[@]}")

echo "goal-bot: work dir: $WORK_DIR"
echo "goal-bot: max iterations: $MAX_ITERATIONS, initial turns: $MAX_TURNS_INITIAL, feedback turns: $MAX_TURNS_FEEDBACK"
echo "goal-bot: claude idle timeout: ${CLAUDE_IDLE_TIMEOUT}s"
echo "goal-bot: log: $LOG_FILE"

log_line "Started goal-bot"
log_line "Goal file: $GOAL_FILE"
log_line "Working dir: $WORK_DIR"
log_line "Setup command: $SETUP_COMMAND"
log_line "Evaluate command: $EVALUATE_COMMAND"

INITIAL_RESPONSE="$LOG_DIR/claude-initial.json"
INITIAL_PROMPT="$(build_initial_prompt)"
echo "goal-bot: starting initial claude run..."
log_line "Starting initial claude run"
(
  cd "$WORK_DIR" || exit 127
  claude -p "$INITIAL_PROMPT" "${CLAUDE_INITIAL_ARGS[@]}"
) > "$INITIAL_RESPONSE" 2>&1 &
CURRENT_CHILD_PID=$!
if wait_with_heartbeat "initial claude run" "$INITIAL_RESPONSE"; then
  CLAUDE_STATUS=0
else
  CLAUDE_STATUS=$?
fi

set +e
SESSION_ID="$(extract_session_id "$INITIAL_RESPONSE")"
SESSION_EXTRACT_STATUS=$?
set -e
if [ "$SESSION_EXTRACT_STATUS" -ne 0 ]; then
  die "could not parse initial claude JSON output; see $INITIAL_RESPONSE"
fi
[ -n "$SESSION_ID" ] || die "could not extract session_id from initial claude JSON output; see $INITIAL_RESPONSE"
log_line "Claude session_id: $SESSION_ID"

if [ "$CLAUDE_STATUS" -ne 0 ]; then
  echo "goal-bot: initial claude run exited with code $CLAUDE_STATUS; continuing with setup/evaluate because session_id was captured."
  log_line "Initial claude run exited with code $CLAUDE_STATUS; continuing with setup/evaluate"
else
  echo "goal-bot: initial claude run completed."
fi

ITERATION=1
while [ "$ITERATION" -le "$MAX_ITERATIONS" ]; do
  echo "goal-bot: iteration $ITERATION/$MAX_ITERATIONS"
  log_line "===== iteration $ITERATION start ====="
  ITER_START="$(now_epoch)"

  SETUP_OUT="$LOG_DIR/setup-$ITERATION.out"
  SETUP_STATUS_FILE="$LOG_DIR/setup-$ITERATION.status"
  run_command_capture "$SETUP_COMMAND" "$SETUP_OUT" "$SETUP_STATUS_FILE"
  SETUP_STATUS="$(cat "$SETUP_STATUS_FILE")"

  if [ "$SETUP_STATUS" -ne 0 ]; then
    DURATION="$(( $(now_epoch) - ITER_START ))"
    log_line "Iteration $ITERATION setup failed with exit code $SETUP_STATUS after ${DURATION}s"
    {
      echo "setup output:"
      cat "$SETUP_OUT"
      echo
    } >> "$LOG_FILE"

    FEEDBACK="$(printf 'Iteration %s setup failed with exit code %s.\n\nSetup command:\n%s\n\nOutput:\n%s\n' "$ITERATION" "$SETUP_STATUS" "$SETUP_COMMAND" "$(cat "$SETUP_OUT")")"
    CLAUDE_RESPONSE="$LOG_DIR/claude-feedback-$ITERATION.json"
    echo "goal-bot: sending setup failure feedback to claude..."
    log_line "Sending setup failure feedback to claude"
    if ! send_feedback "$FEEDBACK" "$CLAUDE_RESPONSE"; then
      echo "goal-bot: claude feedback exited nonzero; continuing to next setup/evaluate iteration."
      log_line "Claude feedback call exited nonzero during iteration $ITERATION; continuing"
    fi
    echo "goal-bot: claude feedback run completed."

    ITERATION="$((ITERATION + 1))"
    continue
  fi

  EVAL_OUT="$LOG_DIR/evaluate-$ITERATION.out"
  EVAL_STATUS_FILE="$LOG_DIR/evaluate-$ITERATION.status"
  run_command_capture "$EVALUATE_COMMAND" "$EVAL_OUT" "$EVAL_STATUS_FILE"
  EVAL_STATUS="$(cat "$EVAL_STATUS_FILE")"
  DURATION="$(( $(now_epoch) - ITER_START ))"

  log_line "Iteration $ITERATION evaluate exit code: $EVAL_STATUS, duration: ${DURATION}s"
  {
    echo "evaluate output:"
    cat "$EVAL_OUT"
    echo
  } >> "$LOG_FILE"

  if [ "$EVAL_STATUS" -eq 0 ]; then
    echo "goal-bot: success after $ITERATION iteration(s)."
    log_line "Succeeded at iteration $ITERATION after ${DURATION}s"
    exit 0
  fi

  FEEDBACK="$(printf 'Iteration %s evaluate failed with exit code %s.\n\nEvaluate command:\n%s\n\nOutput:\n%s\n' "$ITERATION" "$EVAL_STATUS" "$EVALUATE_COMMAND" "$(cat "$EVAL_OUT")")"
  CLAUDE_RESPONSE="$LOG_DIR/claude-feedback-$ITERATION.json"
  echo "goal-bot: sending evaluate failure feedback to claude..."
  log_line "Sending evaluate failure feedback to claude"
  if ! send_feedback "$FEEDBACK" "$CLAUDE_RESPONSE"; then
    echo "goal-bot: claude feedback exited nonzero; continuing to next setup/evaluate iteration."
    log_line "Claude feedback call exited nonzero during iteration $ITERATION; continuing"
  fi
  echo "goal-bot: claude feedback run completed."

  ITERATION="$((ITERATION + 1))"
done

echo "goal-bot: reached max_iterations ($MAX_ITERATIONS) without success."
log_line "Failed: reached max_iterations ($MAX_ITERATIONS)"
exit 1
