# tmux-agent-status

Show coding-agent state, attention, and activity directly in the tmux window list.

Each agent pane contributes an icon to its window:

- a bright, bold icon means the agent is ready or needs input;
- a dim breathing icon means it is working;
- no icon means no supported agent is running in that pane.

The plugin discovers Claude Code, Codex, Pi, and OpenCode processes, follows agents launched through wrapper shells, tracks multiple agent panes per window, and wraps overflowing window lists across up to five status rows. Lifecycle hooks are optional: a read-only tmux control-mode listener keeps state current when hooks are unavailable.

## Requirements

- tmux 3.4 or newer; tmux 3.7 or newer is recommended for pane-index ordering
- Bash 5 or newer
- a UTF-8 locale for the Claude and Codex icons
- `ps`, `awk`, `sed`, and either `md5`, `md5sum`, or `cksum`
- `lsof` for Claude background-task detection and exact Codex thread selection
- `jq` for the hook installer and semantic Codex titles
- optional: `sqlite3`, `curl`, and Ollama for generated window titles

On macOS, install current Bash and tmux with Homebrew:

```sh
brew install bash tmux
```

## Installation with TPM

Add the plugin after your theme and before TPM initialization:

```tmux
set -g @plugin 'jesse-merhi/tmux-agent-status'

# Keep this last.
run '~/.tmux/plugins/tpm/tpm'
```

Reload tmux, then press `prefix + I` to install it.

The monitor starts automatically and appends its pane-ordered icon segment to both window-status formats. Reloading the plugin does not duplicate the segment.

## Agent hooks

Automatic discovery works without agent configuration. Hooks make transitions immediate and preserve working state while Claude has background tasks.

Install user-level hooks for both Claude Code and Codex:

```sh
~/.tmux/plugins/tmux-agent-status/scripts/install-hooks.sh
```

The installer safely merges `~/.claude/settings.json` and `~/.codex/hooks.json`, preserves unrelated hooks and settings, creates timestamped backups before changes, and is idempotent. Select one agent with `--claude` or `--codex`; preview changes with `--dry-run`.

Codex requires one additional trust step for user-installed command hooks: start Codex, open `/hooks`, review the new definitions, and trust them. Codex will skip untrusted hooks. See the [Codex hooks documentation](https://developers.openai.com/codex/hooks).

The hook command is:

```sh
~/.tmux/plugins/tmux-agent-status/scripts/agent-attention.sh STATE ICON
```

Supported states are `register`, `busy`, `ready`, `pending`, `claude-stop`, and `off`.

### Claude Code

Wire these lifecycle events to the command in Claude Code settings:

| Event | Command |
| --- | --- |
| `SessionStart` | `agent-attention.sh register '✳'` |
| `UserPromptSubmit` | `agent-attention.sh busy '✳'` |
| `Stop` | `agent-attention.sh claude-stop '✳'` |
| `Notification` | `agent-attention.sh ready '✳'` |
| `SessionEnd` | `agent-attention.sh off` |

`claude-stop` reads Claude's hook JSON from standard input and keeps the icon busy while that session still has a task output file open for writing.

### Codex

The installer adds native Codex lifecycle hooks for `SessionStart`, `UserPromptSubmit`, `Stop`, and `SessionEnd`. These register the pane, switch to working as soon as a prompt is submitted, switch to ready when the turn stops, and clear the icon when the session ends. Existing `notify` configuration is left untouched.

The control-mode listener remains a fallback and detects subsequent output between lifecycle events.

## Options

Set options before the plugin declaration.

```tmux
# Pipe-separated process-name regular expression.
set -g @agent_status_agents 'claude|codex|pi|opencode'

# Status wrapping. Set both to 2 to keep two rows at all times.
set -g @agent_status_wrap on
set -g @agent_status_min_lines 1
set -g @agent_status_max_lines 5

# Window naming.
set -g @agent_status_rename_windows on
set -g @agent_status_rename_manual_windows off
set -g @agent_status_label_command '/absolute/path/to/optional-label-command'

# Optional local-model titles; disabled when the model is empty.
set -g @agent_status_ollama_model ''
set -g @agent_status_ollama_url 'http://127.0.0.1:11434'

# Other behavior.
set -g @agent_status_pulse_interval '0.22'
set -g @agent_status_codex_db "$HOME/.codex/state_5.sqlite"
set -g @agent_status_start on
```

Unknown process names included in `@agent_status_agents` use a green `●`. Claude uses orange `✳`; Codex uses purple `⬢`.

Set the window-local `@agent_rename_lock` option to `1` to protect a deliberate manual name:

```sh
tmux set-option -w @agent_rename_lock 1
```

## Development

Run static checks and behavior tests:

```sh
shellcheck tmux-agent-status.tmux scripts/*.sh tests/*.sh
tests/run.sh
docker build -f tests/Dockerfile -t tmux-agent-status-fresh .
docker run --rm tmux-agent-status-fresh
```

Tests use throwaway tmux servers and clean them up on exit. The Docker test runs the complete suite from Ubuntu 24.04 with a fresh non-root home, including both agents' hook installation, generated commands, renderer behavior, and the resulting tmux busy, ready, and off states.
