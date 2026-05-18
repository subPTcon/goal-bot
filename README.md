# goal-bot

`goal-bot` is a small automation loop for driving a coding agent against a benchmark task.

The current implementation uses Claude Code through `claude -p`: it asks the agent to make an initial code change, runs the configured setup and evaluation commands, then feeds failures back into the same Claude session until the task passes or the iteration limit is reached.

## Workflow

Given a `goal.yaml`, `goal-bot.sh` does the following:

1. Reads `goal.description`, `setup.command`, `evaluate.command`, and `config`.
2. Starts Claude Code with the goal prompt in non-interactive print mode.
3. Captures the Claude `session_id` from stream JSON output.
4. Runs `setup.command` in the configured working directory.·
5. Runs `evaluate.command` if setup succeeds.
6. Exits successfully if evaluation returns exit code `0`.
7. If setup or evaluation fails, resumes the Claude session with the failure output.
8. Repeats until success or `config.max_iterations`.

The script logs each run to `.goal-bot/run.log` and stores raw Claude streams and command outputs under `.goal-bot/`.

## Usage

```bash
bash goal-bot.sh benchmarks/json-parser/goal.yaml
```

Claude Code must be installed and authenticated:

```bash
claude -p "say hi" --output-format stream-json --verbose --max-turns 1
```

The script also requires `python3`. `jq` is optional; if unavailable, Python is used to extract `session_id`.

## `goal.yaml`

Minimal shape:

```yaml
goal:
  name: "JSON Parser in C"
  description: |
    Implement an RFC 8259 compliant JSON validator from scratch in pure C.

setup:
  command: "gcc -std=c11 -o json_parser src/*.c -Wall -Werror"

evaluate:
  command: "bash run_tests.sh"

config:
  max_iterations: 30
  max_turns_initial: 8
  max_turns_feedback: 6
  claude_idle_timeout_seconds: 90
  working_dir: ./benchmarks/json-parser
  model: sonnet
```

Supported config fields:

- `working_dir`: directory where Claude, setup, and evaluate commands run.
- `max_iterations`: maximum setup/evaluate/fix cycles.
- `max_turns_per_iteration`: fallback turn limit if specific limits are not set.
- `max_turns_initial`: Claude turn limit for the first implementation attempt.
- `max_turns_feedback`: Claude turn limit for each failure feedback attempt.
- `claude_idle_timeout_seconds`: kill a Claude call if its stream output stops growing for this many seconds. Set to `0` to disable.
- `model`: passed to `claude --model`.

Relative `working_dir` is resolved from the launch directory first, then from the `goal.yaml` directory.

## Logging

Main log:

```bash
.goal-bot/run.log
```

Raw Claude stream files:

```bash
.goal-bot/claude-initial.json
.goal-bot/claude-feedback-1.json
.goal-bot/claude-feedback-2.json
```

Command outputs:

```bash
.goal-bot/setup-1.out
.goal-bot/evaluate-1.out
```

During Claude execution, the script prints and logs a compact view of the stream:

```text
goal-bot: claude init: cwd=... model=... permission=...
goal-bot: claude says: ...
goal-bot: claude tool: Read: /path/to/file
goal-bot: claude tool: Write: /path/to/file
goal-bot: claude tool: Bash: Build project | gcc ...
goal-bot: tool result stdout: ...
```

Heartbeat output shows whether Claude is still producing stream data:

```text
goal-bot: still waiting for initial claude run (45s elapsed, 18 lines, 32089 bytes)...
```

If line and byte counts stop changing for `claude_idle_timeout_seconds`, the script terminates that Claude process and continues the outer loop when possible.

## Claude Behavior Notes

Claude Code can exit nonzero for reasons that are not fatal to the outer loop, such as reaching `--max-turns`. If a `session_id` was captured, `goal-bot` continues to setup/evaluate and uses the results as feedback.

The prompt wrapper intentionally tells Claude to avoid exhaustive benchmark exploration. The outer loop is responsible for running tests and providing focused failure feedback.

## Benchmark Example

The repository includes a JSON parser benchmark:

```bash
bash goal-bot.sh benchmarks/json-parser/goal.yaml
```

The benchmark expects:

- source files in `benchmarks/json-parser/src/`
- a compiled binary at `benchmarks/json-parser/json_parser`
- stdin input
- exit code `0` for valid JSON and nonzero for invalid JSON

On macOS, `benchmarks/json-parser/run_tests.sh` supports `timeout`, `gtimeout`, or no timeout command.

## Current Limitations

- The current script is a Claude Code adapter, not yet a generic multi-agent runner.
- YAML parsing is intentionally lightweight and supports the simple nested shape used by benchmark configs.
- Claude stream monitoring is best-effort and optimized for Claude Code `stream-json`.
- The script does not currently aggregate cost, token usage, or pass-rate history into a structured report.

## Planned Direction

Two natural next steps:

1. Add more benchmarks, such as compiler, database, Redis-like, web framework, and bugfix suites.
2. Split the coding-agent layer into adapters so the same benchmark can run with Claude Code, Codex, OpenCode, or other agents.

A future adapter interface could look like:

```bash
agent_start "$prompt" "$output_file"
agent_resume "$session_id" "$feedback" "$output_file"
agent_extract_session_id "$output_file"
agent_monitor_stream "$output_file"
```

That would keep the core loop independent from any single coding agent.
