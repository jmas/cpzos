#!/bin/bash -e

# Install a pinned kmscon from trixie-backports.
#
# kmscon is not in Trixie main, but 10.0.4 is available for arm64 in
# trixie-backports. The version is pinned so an image rebuild does not silently
# change the DRM/console layer. If the backports package disappears, build the
# same upstream release from a pinned tarball instead of falling back to the
# old 9.0 release.
KMSCON_VERSION="${KMSCON_VERSION:-10.0.4-1~bpo13+1}"
LIBTSM_VERSION="${LIBTSM_VERSION:-4.8.0-0.1~bpo13+1}"

on_chroot << CHROOT
set -e
export DEBIAN_FRONTEND=noninteractive

if [ ! -f /etc/apt/sources.list.d/trixie-backports.sources ]; then
	cat > /etc/apt/sources.list.d/trixie-backports.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
EOF
fi

apt-get update

if ! apt-cache madison kmscon | grep -q "${KMSCON_VERSION}"; then
	echo "ERROR: kmscon ${KMSCON_VERSION} is not available in trixie-backports" >&2
	echo "Available versions:" >&2
	apt-cache madison kmscon >&2 || true
	exit 1
fi

apt-get install -y --no-install-recommends -t trixie-backports \
	"kmscon=${KMSCON_VERSION}" \
	"libtsm4=${LIBTSM_VERSION}"

apt-mark hold kmscon libtsm4
command -v kmscon
CHROOT
