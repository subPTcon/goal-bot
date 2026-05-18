# goal-bot

`goal-bot` is a small automation loop for driving a coding agent against a benchmark task.

The current implementation supports Claude Code and Codex. It asks the selected agent to make an initial code change, runs the configured setup and evaluation commands, then feeds failures back into the same agent session until the task passes or the iteration limit is reached.

## Workflow

Given a `goal.yaml`, `goal-bot.sh` does the following:

1. Reads `goal.description`, `setup.command`, `evaluate.command`, and `config`.
2. Starts the configured coding agent with the goal prompt in non-interactive mode.
3. Captures an agent session id when available.
4. Runs `setup.command` in the configured working directory.·
5. Runs `evaluate.command` if setup succeeds.
6. Exits successfully if evaluation returns exit code `0`.
7. If setup or evaluation fails, resumes the agent session with the failure output.
8. Repeats until success or `config.max_iterations`.

The script logs each run to `.goal-bot/run.log` and stores raw agent streams and command outputs under `.goal-bot/`.

## Usage

```bash
bash goal-bot.sh benchmarks/json-parser/goal.yaml
```

For Claude Code, `claude` must be installed and authenticated:

```bash
claude -p "say hi" --output-format stream-json --verbose --max-turns 1
```

For Codex, `codex` must be installed and authenticated:

```bash
codex exec --json --skip-git-repo-check "say hi"
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
  agent: claude
  max_iterations: 30
  max_turns_initial: 8
  max_turns_feedback: 6
  agent_idle_timeout_seconds: 90
  working_dir: ./benchmarks/json-parser
  model: sonnet
```

Supported config fields:

- `agent`: coding agent to use. Supported values: `claude`, `codex`.
- `working_dir`: directory where the agent, setup, and evaluate commands run.
- `max_iterations`: maximum setup/evaluate/fix cycles.
- `max_turns_per_iteration`: fallback turn limit if specific limits are not set.
- `max_turns_initial`: agent turn limit for the first implementation attempt. Currently this is applied to Claude Code; Codex uses its own default stop behavior.
- `max_turns_feedback`: agent turn limit for each failure feedback attempt. Currently this is applied to Claude Code; Codex uses its own default stop behavior.
- `agent_idle_timeout_seconds`: kill an agent call if its output stops growing for this many seconds. Set to `0` to disable.
- `claude_idle_timeout_seconds`: backward-compatible alias for `agent_idle_timeout_seconds`.
- `model`: passed to `claude --model` or `codex --model`.

When switching agents, make sure `model` is valid for that agent. For example, `sonnet` is a Claude Code alias and is not a useful Codex model name.

To run the same benchmark with Codex:

```yaml
config:
  agent: codex
  model: gpt-5.3-codex
```

You can also omit `model` to use the selected agent's default.

Relative `working_dir` is resolved from the launch directory first, then from the `goal.yaml` directory.

## Logging

Main log:

```bash
.goal-bot/run.log
```

Raw agent stream files:

```bash
.goal-bot/claude-initial.json
.goal-bot/claude-feedback-1.json
.goal-bot/codex-initial.json
.goal-bot/codex-feedback-1.json
```

Command outputs:

```bash
.goal-bot/setup-1.out
.goal-bot/evaluate-1.out
```

During agent execution, the script prints and logs a compact view of the stream:

```text
goal-bot: claude init: cwd=... model=... permission=...
goal-bot: claude says: ...
goal-bot: claude tool: Read: /path/to/file
goal-bot: codex thread started: 019e...
goal-bot: codex says: Implementing the validator now...
goal-bot: codex command started: /bin/zsh -lc 'gcc ...'
goal-bot: codex command completed: exit=0 status=completed | /bin/zsh -lc 'gcc ...'
goal-bot: codex file change completed: status=completed update: /path/to/file
goal-bot: tool result stdout: ...
```

Heartbeat output shows whether the agent is still producing stream data:

```text
goal-bot: still waiting for initial claude run (45s elapsed, 18 lines, 32089 bytes)...
goal-bot: still waiting for initial codex run (45s elapsed, 18 lines, 32089 bytes)...
```

If line and byte counts stop changing for `agent_idle_timeout_seconds`, the script terminates that agent process and continues the outer loop when possible.

## Agent Behavior Notes

Claude Code can exit nonzero for reasons that are not fatal to the outer loop, such as reaching `--max-turns`. If a `session_id` was captured, `goal-bot` continues to setup/evaluate and uses the results as feedback.

Codex is run through `codex exec --json` and resumed through `codex exec resume --json`. If a Codex CLI version does not emit a session id, `goal-bot` falls back to `codex exec resume --last`.

The prompt wrapper intentionally tells the agent to avoid exhaustive benchmark exploration. The outer loop is responsible for running tests and providing focused failure feedback.

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

- The current script supports Claude Code and Codex directly; broader agent support should be added through adapters.
- YAML parsing is intentionally lightweight and supports the simple nested shape used by benchmark configs.
- Agent stream monitoring is best-effort. Claude Code `stream-json` events are parsed more richly than generic Codex JSONL events.
- The script does not currently aggregate cost, token usage, or pass-rate history into a structured report.

## Planned Direction

Two natural next steps:

1. Add more benchmarks, such as compiler, database, Redis-like, web framework, and bugfix suites.
2. Split the coding-agent layer into separate adapter files so the same benchmark can run with Claude Code, Codex, OpenCode, or other agents.

A future adapter interface could look like:

```bash
agent_start "$prompt" "$output_file"
agent_resume "$session_id" "$feedback" "$output_file"
agent_extract_session_id "$output_file"
agent_monitor_stream "$output_file"
```

That would keep the core loop independent from any single coding agent.
