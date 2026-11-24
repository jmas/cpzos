#!/bin/sh
# Create the tmux server and the Home window. Runs as cpz.
set -eu

export HOME="${HOME:-/home/cpz}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export TMUX_TMPDIR="${TMUX_TMPDIR:-/run/cpz}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

if command -v flock >/dev/null 2>&1 && [ -d /run/cpz ]; then
    exec 9>/run/cpz/tmux.lock
    flock 9
fi

/usr/bin/tmux -L cpz start-server 2>/dev/null || true
if ! /usr/bin/tmux -L cpz has-session -t main 2>/dev/null; then
    /usr/bin/tmux -L cpz new-session -d -s main -n Home \
        /usr/local/bin/cpz-launcher
fi
