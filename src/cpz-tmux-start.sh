#!/bin/sh
# Create the tmux server and the Home window. Runs as cpz.
set -eu

export HOME="${HOME:-/home/cpz}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export TMUX_TMPDIR="${TMUX_TMPDIR:-/run/cpz}"
mkdir -p "$TMUX_TMPDIR" 2>/dev/null || true

# No lock file: the single systemd unit is the only writer. A lock held by a
# stale helper would keep the unit in "activating" forever.
if /usr/bin/tmux -L cpz has-session -t main 2>/dev/null; then
    exit 0
fi
exec /usr/bin/tmux -L cpz new-session -d -s main -n Home \
    /usr/local/bin/cpz-launcher
