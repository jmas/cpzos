#!/bin/bash -e

# Old kernels leave the APT index but remain in the official package pool.
# Install the entire pinned dependency set before any rolling kernel packages.
install -d "${ROOTFS_DIR}/var/tmp" "${ROOTFS_DIR}/etc/apt/preferences.d"
DOWNLOAD_DIR=$(mktemp -d "${ROOTFS_DIR}/var/tmp/cardputerzero-kernel.XXXXXX")
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
MANIFEST="${PWD}/files/kernel-packages.sha256"

# The kernel packages are pinned by both name and SHA-256, so a valid cached
# copy is byte-for-byte the same package. Keep the cache in work/ (outside the
# image) so repeated builds skip the Raspberry Pi archive download entirely.
CACHE_DIR="${WORK_DIR:?}/cache/kernel-debs"
mkdir -p "$CACHE_DIR"

fetch_kernel_package() {
    local sha=$1 filename=$2 dest=$3
    local cached="${CACHE_DIR}/${filename}"
    local part="${cached}.part"

    if ! [ -f "$cached" ] ||
        ! printf '%s  %s\n' "$sha" "$cached" | sha256sum --check --status; then
        rm -f "$part"
        if ! curl --fail --location --silent --show-error --retry 3 \
            --connect-timeout 30 --max-time 600 \
            "https://archive.raspberrypi.com/debian/pool/main/l/linux/${filename}" \
            -o "$part"; then
            rm -f "$part"
            return 1
        fi

        if ! printf '%s  %s\n' "$sha" "$part" | sha256sum --check --status; then
            echo "ERROR: checksum mismatch for ${filename}" >&2
            rm -f "$part"
            return 1
        fi
        mv "$part" "$cached"
    fi

    # Hardlink when work/ and the rootfs are on the same filesystem (the usual
    # Docker volume layout), otherwise copy the cached package.
    ln "$cached" "$dest" 2>/dev/null || cp "$cached" "$dest"
}

while read -r sha filename; do
    fetch_kernel_package "$sha" "$filename" "${DOWNLOAD_DIR}/${filename}"
done < "$MANIFEST"
(cd "$DOWNLOAD_DIR" && sha256sum --check "$MANIFEST")

install -m 644 files/kernel.pref \
    "${ROOTFS_DIR}/etc/apt/preferences.d/cardputerzero-kernel"
CHROOT_DOWNLOAD_DIR="${DOWNLOAD_DIR#"${ROOTFS_DIR}"}"
on_chroot << EOF
set -e
cd '${CHROOT_DOWNLOAD_DIR}'
packages=()
for deb in ./*.deb; do
    packages+=("\$(dpkg-deb -f "\$deb" Package)")
done
apt-get install -y --no-install-recommends \
    --allow-downgrades --allow-change-held-packages ./*.deb
kernel_version="\$(dpkg-query -W -f='\${Version}' linux-image-rpi-v8 2>/dev/null || true)"
printf 'Installed kernel version: %s\n' "\$kernel_version"
apt-mark hold "\${packages[@]}"
EOF
