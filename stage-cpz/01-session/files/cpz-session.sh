# CPZ-session bootstrap. Only tty1 starts the kiosk session; SSH and tty2 stay
# plain recovery shells.

[ -n "${TMUX:-}" ] && return 0

if [ "$(tty 2>/dev/null || true)" != "/dev/tty1" ]; then
	return 0
fi

cd "$HOME" 2>/dev/null || return 0

exec tmux new -A -s main
