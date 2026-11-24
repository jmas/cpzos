#!/bin/bash
# Stage 25 — build the SDL2/KMSDRM graphics stack.
#
# This stage runs while the toolchain from stage 20 is still installed.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./config.sh
. scripts/lib.sh

mkdir -p "$ROOT/usr/local/bin" "$ROOT/usr/local/lib" "$ROOT/usr/local/include"
rm -rf "$ROOT/tmp/cpz-src"
mkdir -p "$ROOT/tmp/cpz-src"
cp -a src/. "$ROOT/tmp/cpz-src/"

log "building cpz-session"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra cpz-session.c cpz-json.c -o cpz-session -ludev"

log "building cpz-menud and cpz-menu"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra cpz-menud.c cpz-json.c -o cpz-menud"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra cpz-menu.c cpz-json.c -o cpz-menu"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra cpz-sessionctl.c -o cpz-sessionctl"

log "building system providers: battery, clock, network, bluetooth"
for prov in battery clock network bluetooth; do
    in_root "cd /tmp/cpz-src && \
        gcc -O2 -Wall -Wextra cpz-$prov.c cpz-json.c -o cpz-$prov"
done

SDL_CFLAGS=$(in_root "pkg-config --cflags sdl2")
SDL_LIBS=$(in_root "pkg-config --libs sdl2")
TTF_CFLAGS=$(in_root "pkg-config --cflags SDL2_ttf")
TTF_LIBS=$(in_root "pkg-config --libs SDL2_ttf")
UI_CFLAGS=$(in_root "pkg-config --cflags cairo pangocairo")
UI_LIBS=$(in_root "pkg-config --libs cairo pangocairo")

log "building cpz-ui (SDL2 + cairo/pango), cpz-term and cpz-sdlprobe"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra $SDL_CFLAGS $UI_CFLAGS cpz-ui.c cpz-json.c -o cpz-ui \
        $SDL_LIBS $UI_LIBS -lm"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra $SDL_CFLAGS $TTF_CFLAGS cpz-sdlprobe.c -o cpz-sdlprobe \
        $SDL_LIBS $TTF_LIBS"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra $SDL_CFLAGS $TTF_CFLAGS -I/usr/include cpz-term.c -o cpz-term \
        $SDL_LIBS $TTF_LIBS -ltsm -lutil"

log "building cpz-backlight"
in_root "cd /tmp/cpz-src && \
    gcc -O2 -Wall -Wextra cpz-backlight.c -o cpz-backlight"

in_root "install -m 0755 /tmp/cpz-src/cpz-session /tmp/cpz-src/cpz-ui \
         /tmp/cpz-src/cpz-menud /tmp/cpz-src/cpz-menu \
         /tmp/cpz-src/cpz-sessionctl \
         /tmp/cpz-src/cpz-battery /tmp/cpz-src/cpz-clock \
         /tmp/cpz-src/cpz-network /tmp/cpz-src/cpz-bluetooth \
         /tmp/cpz-src/cpz-term /tmp/cpz-src/cpz-sdlprobe \
         /tmp/cpz-src/cpz-backlight /usr/local/bin/"
in_root "strip /usr/local/bin/cpz-session /usr/local/bin/cpz-ui \
         /usr/local/bin/cpz-menud /usr/local/bin/cpz-menu \
         /usr/local/bin/cpz-sessionctl \
         /usr/local/bin/cpz-battery /usr/local/bin/cpz-clock \
         /usr/local/bin/cpz-network /usr/local/bin/cpz-bluetooth \
         /usr/local/bin/cpz-term /usr/local/bin/cpz-sdlprobe \
         /usr/local/bin/cpz-backlight"

# Installed apps: static, root-owned manifests scanned by cpz-menud. The
# launcher no longer contains any application names.
log "installing app manifests into /usr/share/cpz/apps"
install -d -m 0755 "$ROOT/usr/share/cpz/apps"
for appdir in src/apps/*; do
    [ -d "$appdir" ] || continue
    app=$(basename "$appdir")
    install -d -m 0755 "$ROOT/usr/share/cpz/apps/$app"
    install -m 0644 "$appdir/app.json" "$ROOT/usr/share/cpz/apps/$app/app.json"
    if [ -f "$appdir/icon.png" ]; then
        install -m 0644 "$appdir/icon.png" "$ROOT/usr/share/cpz/apps/$app/icon.png"
    fi
done
in_root "chown -R root:root /usr/share/cpz/apps"
in_root "chmod -R go-w /usr/share/cpz/apps"

# Provider tokens. They live in /etc so they survive the tmpfs; cpz-menud
# copies them into /run/cpz/menu at startup. Only provider apps need one.
log "creating provider tokens in /etc/cpz/menu"
install -d -m 0755 "$ROOT/etc/cpz/menu"
for app in battery clock network bluetooth; do
    token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-48)
    printf '%s\n' "$token" > "$ROOT/etc/cpz/menu/$app.token"
    chmod 0600 "$ROOT/etc/cpz/menu/$app.token"
    chown root:root "$ROOT/etc/cpz/menu/$app.token"
done

# iPod-like UI font: Noto Sans (humanist, open apertures, single-storey g,
# full Latin/Greek/Cyrillic) plus a fallback chain for symbols, emoji and the
# major non-Latin scripts. Shipped as files (OFL), not pulled from a package,
# so the UI does not depend on a distro font update. The CJK file is the
# largest and is shared by both weights.
in_root "install -d /usr/share/fonts/cpz /usr/share/licenses/noto"
in_root "install -m 0644 /tmp/cpz-src/fonts/Noto*.ttf \
         /tmp/cpz-src/fonts/Noto*.otf /usr/share/fonts/cpz/"
in_root "install -m 0644 /tmp/cpz-src/fonts/OFL-Noto.txt /usr/share/licenses/noto/OFL.txt"
in_root "fc-cache -f >/dev/null 2>&1 || true"
rm -rf "$ROOT/tmp/cpz-src"

# Functional checks that need no display.
log "session: $(in_root "/usr/local/bin/cpz-session --version")"
log "menu daemon: $(in_root "/usr/local/bin/cpz-menud --version")"
log "menu CLI: $(in_root "/usr/local/bin/cpz-menu --version")"
log "menu model: $(in_root "/usr/local/bin/cpz-menud --selftest" | head -1)"
log "battery provider: $(in_root "/usr/local/bin/cpz-battery --version")"
log "clock provider: $(in_root "/usr/local/bin/cpz-clock --version")"
log "network provider: $(in_root "/usr/local/bin/cpz-network --version")"
log "bluetooth provider: $(in_root "/usr/local/bin/cpz-bluetooth --version")"
log "SDL probe selftest: $(in_root "/usr/local/bin/cpz-sdlprobe --selftest" | head -1)"
log "terminal selftest: $(in_root "/usr/local/bin/cpz-term --selftest" | head -1)"
in_root "/usr/local/bin/cpz-backlight --selftest" >/dev/null

# Boot report. Writes the display/session state to the FAT boot partition so a
# dark panel can be diagnosed from another machine.
cat > "$ROOT/usr/local/bin/cpz-report" <<'EOF'
#!/bin/sh
# Collect the display/session state after boot. No secrets are written.
set -u
out=/var/log/cpz-report.txt

run() { "$@" 2>&1 || true; }

{
    echo "=== cpz-arch report $(date -u 2>/dev/null)"
    echo "--- cmdline";        run cat /proc/cmdline
    echo "--- kernel";         run uname -a
    echo "--- drm devices";    run ls -l /dev/dri
    echo "--- connectors";     for c in /sys/class/drm/card*-*; do [ -e "$c" ] || continue; printf '%s %s\n' "$(basename "$c")" "$(cat "$c/status" 2>/dev/null)"; done
    echo "--- connector modes"; for c in /sys/class/drm/card*-*; do [ -e "$c" ] || continue; printf '%s: %s\n' "$(basename "$c")" "$(head -1 "$c/modes" 2>/dev/null)"; done
    echo "--- framebuffers";   for f in /sys/class/graphics/fb*; do [ -e "$f" ] || continue; printf '%s %s blank=%s\n' "$(basename "$f")" "$(cat "$f/name" 2>/dev/null)" "$(cat "$f/blank" 2>/dev/null)"; done
    echo "--- active vt";      run cat /sys/class/tty/tty0/active
    echo "--- backlight";      run /usr/local/bin/cpz-backlight status
    run cat /sys/class/backlight/backlight/brightness
    echo "--- session";        run systemctl --no-pager --full status cpz-session
    echo "--- session probe";  run /usr/local/bin/cpz-session --probe
    echo "--- session journal"; run journalctl -b -u cpz-session --no-pager
    echo "--- session socket"; run ls -l /run/cpz
    echo "--- sdl probe";      run env SDL_VIDEODRIVER=dummy /usr/local/bin/cpz-sdlprobe --selftest
    echo "--- modules";        run lsmod
    echo "--- network";        run ip -4 addr
    echo "--- routes";         run ip route
    echo "--- sshd";           run systemctl --no-pager --full status sshd
    echo "--- dmesg (drm/spi/panel)"; run dmesg
} > "$out" 2>&1

mkdir -p /mnt/cpz-boot
if mount /dev/mmcblk0p1 /mnt/cpz-boot 2>/dev/null; then
    cp "$out" /mnt/cpz-boot/cpz-report.txt 2>/dev/null || true
    run cp /boot/config.txt /mnt/cpz-boot/cpz-config.txt
    run cat /proc/cmdline
    sync
    umount /mnt/cpz-boot 2>/dev/null || true
fi
exit 0
EOF
chmod 0755 "$ROOT/usr/local/bin/cpz-report"

# SDL2 applications in an interactive shell use the KMS/DRM lane. The session
# supervisor sets the device index for its children; an interactive shell gets
# the auto-selected device.
install -d "$ROOT/etc/profile.d"
cat > "$ROOT/etc/profile.d/00-sdl.sh" <<'EOF'
# SDL2/KMSDRM graphics lane. Interactive shells and anything they start inherit it.
export SDL_VIDEODRIVER=kmsdrm
export SDL_VIDEO_DRIVER=kmsdrm
export XKB_DEFAULT_LAYOUT="${XKB_DEFAULT_LAYOUT:-us,ua}"
export XKB_DEFAULT_OPTIONS="${XKB_DEFAULT_OPTIONS:-grp:alt_shift_toggle}"
EOF

log "graphics stack installed"
