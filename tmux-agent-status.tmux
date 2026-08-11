#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmux set-option -g @agent_status_plugin_dir "$CURRENT_DIR"

pane_loop='P/i'
case "$(tmux display-message -p '#{P/i:#{pane_id}}' 2>/dev/null)" in
  P/i:*) pane_loop='P' ;;
esac
agent_body='#{?@agent_icon,#{?#{==:#{@agent_ready},1},#{?@agent_color,#[fg=colour#{@agent_color}],#[fg=colour114]}#[bold] #{@agent_icon},#{?#{@agent_pulse},#[fg=colour#{@agent_pulse}],#[fg=colour238]}#[nobold] #{@agent_icon}},}'
agent_segment="#{${pane_loop}:${agent_body}}"

append_segment() {
  local option="$1" format
  format="$(tmux show-option -gwqv "$option")"
  case "$format" in
    *'@agent_icon'*) return 0 ;;
  esac
  tmux set-option -agw "$option" "$agent_segment"
}

append_segment window-status-format
append_segment window-status-current-format

if [ "$(tmux show-option -gqv @agent_status_start)" != off ]; then
  tmux run-shell -b "$CURRENT_DIR/scripts/agent-monitor.sh"
fi
