# shellcheck shell=sh
# Load the system language selected in Settings > System > Language.
# cpz-settings writes /etc/locale.conf through cpz-locale-apply; login shells
# and tty2/tty3 recovery consoles read it here before CPZ starts.
if [ -r /etc/locale.conf ]; then
	. /etc/locale.conf
	export LANG LC_MESSAGES LC_TIME
fi
