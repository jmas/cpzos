# shellcheck shell=sh
# CPZ-session bootstrap.
#
# tty1 is the CPZ kmscon session. kmscon runs its child on a pty, so the CPZ
# terminal is identified by the tty1 pty name recorded by cpz-login, not by
# /dev/tty1. The tty2 kmscon recovery login, SSH and a debug boot stay plain
# shells.

[ -n "${TMUX:-}" ] && return 0
[ -f /etc/cpz-debug-boot ] && return 0
[ -n "${SSH_CONNECTION:-}" ] && return 0

tty_name=$(tty 2>/dev/null || true)
marker=/run/cpz-kmscon/session.tty1.tty
[ -r "$marker" ] || return 0
[ "$tty_name" = "$(cat "$marker" 2>/dev/null || true)" ] || return 0

cd "$HOME" 2>/dev/null || return 0

# Recommend a new password while the image password is unchanged. The prompt
# never blocks the session; Imager or rpi-preseed password changes update
# /etc/shadow, so the reminder clears itself.
if [ -x /usr/local/bin/cpz-first-login ]; then
	/usr/local/bin/cpz-first-login || true
fi

# Load /etc/tmux.conf (base-index 1) before creating the first session.
tmux start-server 2>/dev/null || true

# Suppress the hooks while restoring a saved layout.
tmux set -g @cpz_restoring 1 2>/dev/null || true

if ! tmux has-session -t '=main' 2>/dev/null; then
	tmux new-session -d -s main -n shell
	tmux set-option -w -t '=main:1' @cpz_main 1
	/usr/local/bin/cpz-session-restore main || true
fi

tmux set -g @cpz_restoring 0 2>/dev/null || true

/usr/local/bin/cpz-session-ensure main

exec tmux attach-session -t '=main'
