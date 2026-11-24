#!/bin/bash
# Stage 25 — build the economy DRM/TUI stack.
#
# This stage runs while the toolchain from stage 20 is still installed. No SDL,
# Mesa, Cairo or Pango is linked into the base UI.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./config.sh
. scripts/lib.sh

mkdir -p "$ROOT/usr/local/bin" "$ROOT/usr/share/cpz/apps" \
         "$ROOT/usr/share/cpz/icons"
rm -rf "$ROOT/tmp/cpz-src"
mkdir -p "$ROOT/tmp/cpz-src"
cp -a src/. "$ROOT/tmp/cpz-src/"

DRM_CFLAGS=$(in_root "pkg-config --cflags libdrm")
DRM_LIBS=$(in_root "pkg-config --libs libdrm")
FT_CFLAGS=$(in_root "pkg-config --cflags freetype2")
FT_LIBS=$(in_root "pkg-config --libs freetype2")
XKB_CFLAGS=$(in_root "pkg-config --cflags xkbcommon")
XKB_LIBS=$(in_root "pkg-config --libs xkbcommon")
NC_CFLAGS=$(in_root "pkg-config --cflags ncursesw")
NC_LIBS=$(in_root "pkg-config --libs ncursesw")

log "building cpz-session (DRM broker)"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra $DRM_CFLAGS cpz-session.c -o cpz-session \
        -ludev $DRM_LIBS"

log "building cpz-term (DRM terminal)"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra $DRM_CFLAGS $FT_CFLAGS $XKB_CFLAGS \
        term/cpz-term.c -o cpz-term \
        -ltsm $DRM_LIBS $FT_LIBS $XKB_LIBS -lutil"

log "building cpz-shell, launcher, help, settings, ctl"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra cpz-shell.c -o cpz-shell"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra $NC_CFLAGS cpz-launcher.c -o cpz-launcher $NC_LIBS"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra $NC_CFLAGS cpz-help.c -o cpz-help $NC_LIBS"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra $NC_CFLAGS cpz-settings.c -o cpz-settings $NC_LIBS"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra cpz-ctl.c -o cpz-ctl"

log "building providers"
for prov in battery clock network bluetooth volume; do
    in_root "cd /tmp/cpz-src && \
        gcc -O2 -Wall -Wextra $NC_CFLAGS cpz-$prov.c -o cpz-$prov $NC_LIBS"
done

log "building cpz-backlight"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra cpz-backlight.c -o cpz-backlight"

in_root "install -m 0755 /tmp/cpz-src/cpz-session /tmp/cpz-src/cpz-term \
         /tmp/cpz-src/cpz-shell /tmp/cpz-src/cpz-launcher \
         /tmp/cpz-src/cpz-help /tmp/cpz-src/cpz-settings /tmp/cpz-src/cpz-ctl \
         /tmp/cpz-src/cpz-battery /tmp/cpz-src/cpz-clock \
         /tmp/cpz-src/cpz-network /tmp/cpz-src/cpz-bluetooth \
         /tmp/cpz-src/cpz-volume /tmp/cpz-src/cpz-backlight \
         /usr/local/bin/"
in_root "strip /usr/local/bin/cpz-session /usr/local/bin/cpz-term \
         /usr/local/bin/cpz-shell /usr/local/bin/cpz-launcher \
         /usr/local/bin/cpz-help /usr/local/bin/cpz-settings /usr/local/bin/cpz-ctl \
         /usr/local/bin/cpz-battery /usr/local/bin/cpz-clock \
         /usr/local/bin/cpz-network /usr/local/bin/cpz-bluetooth \
         /usr/local/bin/cpz-volume /usr/local/bin/cpz-backlight"

log "installing manifests and real-image icons"
for m in src/manifests/*.app; do
    install -m 0644 "$m" "$ROOT/usr/share/cpz/apps/$(basename "$m")"
done
chown -R root:root "$ROOT/usr/share/cpz/apps"
chmod -R go-w "$ROOT/usr/share/cpz/apps"
in_root "install -m 0644 /tmp/cpz-src/icons/*.rgba /usr/share/cpz/icons/"
in_root "install -m 0644 /tmp/cpz-src/icons/icons.map /usr/share/cpz/icons.map"

rm -rf "$ROOT/tmp/cpz-src"

log "running build-time selftests"
log "terminal: $(in_root "/usr/local/bin/cpz-term --selftest" | head -1)"
log "shell:    $(in_root "/usr/local/bin/cpz-shell --selftest --apps /usr/share/cpz/apps" | head -1)"
log "launcher: $(in_root "/usr/local/bin/cpz-launcher --selftest" | head -1)"
log "help:     $(in_root "/usr/local/bin/cpz-help --selftest" | head -1)"
log "settings: $(in_root "/usr/local/bin/cpz-settings --selftest" | head -1)"
log "ctl:      $(in_root "/usr/local/bin/cpz-ctl --selftest" | head -1)"
log "battery:  $(in_root "/usr/local/bin/cpz-battery --selftest" | head -1)"
log "clock:    $(in_root "/usr/local/bin/cpz-clock --selftest" | head -1)"
log "network:  $(in_root "/usr/local/bin/cpz-network --selftest" | head -1)"
log "bt:       $(in_root "/usr/local/bin/cpz-bluetooth --selftest" | head -1)"
log "volume:   $(in_root "/usr/local/bin/cpz-volume --selftest" | head -1)"
in_root "/usr/local/bin/cpz-backlight --selftest" >/dev/null

# Boot report: display/session state, no secrets.
cat > "$ROOT/usr/local/bin/cpz-report" <<'EOF'
#!/bin/sh
set -u
out=/var/log/cpz-report.txt
run() { "$@" 2>&1 || true; }
{
    echo "=== cpz-arch report $(date -u 2>/dev/null)"
    echo "--- cmdline";        run cat /proc/cmdline
    echo "--- kernel";         run uname -a
    echo "--- drm";            run ls -l /dev/dri
    echo "--- connectors";     for c in /sys/class/drm/card*-*; do [ -e "$c" ] || continue; printf '%s %s\n' "$(basename "$c")" "$(cat "$c/status" 2>/dev/null)"; done
    echo "--- modes";          for c in /sys/class/drm/card*-*; do [ -e "$c" ] || continue; printf '%s: %s\n' "$(basename "$c")" "$(head -1 "$c/modes" 2>/dev/null)"; done
    echo "--- backlight";      run /usr/local/bin/cpz-backlight status
    echo "--- session";        run systemctl --no-pager --full status cpz-session
    echo "--- session probe";  run /usr/local/bin/cpz-session --probe
    echo "--- terminal probe";  run /usr/local/bin/cpz-term --probe
    echo "--- journal";        run journalctl -b -u cpz-session --no-pager
    echo "--- modules";        run lsmod
    echo "--- network";        run ip -4 addr
    echo "--- routes";         run ip route
    echo "--- sshd";           run systemctl --no-pager --full status sshd
} > "$out" 2>&1
mkdir -p /mnt/cpz-boot
if mount /dev/mmcblk0p1 /mnt/cpz-boot 2>/dev/null; then
    cp "$out" /mnt/cpz-boot/cpz-report.txt 2>/dev/null || true
    sync
    umount /mnt/cpz-boot 2>/dev/null || true
fi
exit 0
EOF
chmod 0755 "$ROOT/usr/local/bin/cpz-report"

install -d "$ROOT/etc/profile.d"
cat > "$ROOT/etc/profile.d/00-cpz.sh" <<'EOF'
# The economy session is a terminal. Interactive shells get the same runtime
# directory and tmux socket as the Home session.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export TMUX_TMPDIR="${TMUX_TMPDIR:-/run/cpz}"
EOF
chmod 0644 "$ROOT/etc/profile.d/00-cpz.sh"

log "economy TUI stack installed"
