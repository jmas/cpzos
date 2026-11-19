# shellcheck shell=sh
# CPZ session bootstrap for the tty1 login shell.
#
# login(1) has already created the PAM/logind session on tty1. Replacing this
# shell with cpz-cage gives cage the seat and keeps the session cgroup sane.
# tty2/tty3 recovery logins, SSH and the debug image stay plain shells.
[ -n "${TMUX:-}" ] && return 0
[ -f /etc/cpz-debug-boot ] && return 0
[ -n "${SSH_CONNECTION:-}" ] && return 0

tty_name=$(tty 2>/dev/null || true)
[ "$tty_name" = /dev/tty1 ] || return 0

exec /usr/local/bin/cpz-session-supervise
