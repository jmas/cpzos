#!/bin/bash -e

IMG_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.img"
INFO_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.info"
SBOM_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.sbom"
BMAP_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.bmap"

# Build the shipped initramfs with an explicit module list and without the
# large systemd hardware database. MODULES=most copies every storage/network
# driver and its firmware; MODULES=list keeps only the root-media module below
# and whatever the rpi-sys-mods hook adds. The full hwdb.bin is only needed by
# udev after switch_root, so the zz-cpz-trim hook drops it from the initramfs.
# xz is used instead of zstd because the hwdb-free archive is under 8 MiB with
# xz, while zstd leaves it just above that target.
# The Pi kernel has the SD/eMMC, NVMe, USB storage and ext4 drivers built in;
# CM5 eMMC/SD needs sdhci_of_dwcmshc. MODULES=dep is intentionally set only
# after the build: inside the chroot it would guess against the build host, not
# the CM0.
initramfs_conf="${ROOTFS_DIR}/etc/initramfs-tools/initramfs.conf"
if [ -f "$initramfs_conf" ]; then
	sed -i 's/^MODULES=.*/MODULES=list/' "$initramfs_conf"
	sed -i 's/^COMPRESS=.*/COMPRESS=xz/' "$initramfs_conf"
fi
install -d "${ROOTFS_DIR}/etc/initramfs-tools"
cat > "${ROOTFS_DIR}/etc/initramfs-tools/modules" <<'EOF'
# CM5 eMMC/SD controller. All other root-media drivers used by the CPZ image
# (CM4 sdhci/mmc, NVMe, USB storage, ext4) are built into the RPi kernel.
sdhci_of_dwcmshc
EOF
install -d "${ROOTFS_DIR}/etc/initramfs-tools/hooks"
install -m 0755 files/zz-cpz-trim \
	"${ROOTFS_DIR}/etc/initramfs-tools/hooks/zz-cpz-trim"

on_chroot <<- EOF
	update-initramfs -k all -c
	if hash hardlink 2>/dev/null; then
		hardlink -t /usr/share/doc
	fi
	if [ -f /usr/lib/systemd/system/apt-listchanges.service ]; then
		python3 -m apt_listchanges.populate_database --profile apt
		systemctl disable apt-listchanges.timer
	fi
	install -m 755 -o systemd-timesync -g systemd-timesync -d /var/lib/systemd/timesync
	install -m 644 -o systemd-timesync -g systemd-timesync /dev/null /var/lib/systemd/timesync/clock
EOF

if [ -f "${ROOTFS_DIR}/etc/initramfs-tools/update-initramfs.conf" ]; then
	sed -i 's/^update_initramfs=.*/update_initramfs=yes/' "${ROOTFS_DIR}/etc/initramfs-tools/update-initramfs.conf"
	# On the device, dep is accurate: it sees the real root device. Keep the
	# image's explicit list for the build, but make future updates automatic.
	sed -i 's/^MODULES=.*/MODULES=dep/' "$initramfs_conf"
fi

# Guard the optimisation: a regression back to most/all modules is visible
# here and fails the build instead of silently adding a second of boot time.
for initramfs in initramfs8 initramfs_2712; do
	initramfs_file="${ROOTFS_DIR}/boot/firmware/${initramfs}"
	[ -f "$initramfs_file" ] || continue
	initramfs_size=$(stat -c %s "$initramfs_file")
	if [ "$initramfs_size" -gt $((8 * 1024 * 1024)) ]; then
		echo "ERROR: ${initramfs} is ${initramfs_size} bytes; expected < 8 MiB." >&2
		echo "ERROR: check MODULES=list, zz-cpz-trim and /etc/initramfs-tools/modules." >&2
		exit 1
	fi
done

rm -f "${ROOTFS_DIR}/usr/bin/qemu-arm-static"

if [ "${USE_QEMU}" != "1" ]; then
	if [ -e "${ROOTFS_DIR}/etc/ld.so.preload.disabled" ]; then
		mv "${ROOTFS_DIR}/etc/ld.so.preload.disabled" "${ROOTFS_DIR}/etc/ld.so.preload"
	fi
fi

rm -f "${ROOTFS_DIR}/etc/network/interfaces.dpkg-old"

rm -f "${ROOTFS_DIR}/etc/apt/sources.list~"
rm -f "${ROOTFS_DIR}/etc/apt/trusted.gpg~"

rm -f "${ROOTFS_DIR}/etc/passwd-"
rm -f "${ROOTFS_DIR}/etc/group-"
rm -f "${ROOTFS_DIR}/etc/shadow-"
rm -f "${ROOTFS_DIR}/etc/gshadow-"
rm -f "${ROOTFS_DIR}/etc/subuid-"
rm -f "${ROOTFS_DIR}/etc/subgid-"

rm -f "${ROOTFS_DIR}"/var/cache/debconf/*-old
rm -f "${ROOTFS_DIR}"/var/lib/dpkg/*-old

rm -f "${ROOTFS_DIR}/var/lib/dbus/machine-id"

# Mark the image as first boot so systemd runs first-boot services such as
# rpi-resize. Do not bake a real machine-id into the image.
echo "uninitialized" > "${ROOTFS_DIR}/etc/machine-id"

ln -nsf /proc/mounts "${ROOTFS_DIR}/etc/mtab"

# Release version, also shown by cpz-settings -> About.
printf '%s\n' "${CPZ_VERSION:-unknown}" > "${ROOTFS_DIR}/etc/cpz-version"

find "${ROOTFS_DIR}/var/log/" -type f -exec cp /dev/null {} \;

update_issue "$(basename "${EXPORT_DIR}")"
# Record the final mtime after every package operation. cpz-first-login and
# cpz-settings compare it with /etc/shadow to detect the factory password.
stat -c %Y "${ROOTFS_DIR}/etc/shadow" >"${ROOTFS_DIR}/etc/cpz/shadow-mtime"
install -m 644 "${ROOTFS_DIR}/etc/rpi-issue" "${ROOTFS_DIR}/boot/firmware/issue.txt"
if ! [ -L "${ROOTFS_DIR}/boot/issue.txt" ]; then
	ln -s firmware/issue.txt "${ROOTFS_DIR}/boot/issue.txt"
fi

cp "$ROOTFS_DIR/etc/rpi-issue" "$INFO_FILE"

printf "\nCPZ version: %s\n" "${CPZ_VERSION:-unknown}" >> "$INFO_FILE"

{
	if [ -f "$ROOTFS_DIR/usr/share/doc/raspberrypi-kernel/changelog.Debian.gz" ]; then
		firmware=$(zgrep "firmware as of" \
			"$ROOTFS_DIR/usr/share/doc/raspberrypi-kernel/changelog.Debian.gz" | \
			head -n1 | sed  -n 's|.* \([^ ]*\)$|\1|p')
		printf "\nFirmware: https://github.com/raspberrypi/firmware/tree/%s\n" "$firmware"

		kernel="$(curl -s -L "https://github.com/raspberrypi/firmware/raw/$firmware/extra/git_hash")"
		printf "Kernel: https://github.com/raspberrypi/linux/tree/%s\n" "$kernel"

		uname="$(curl -s -L "https://github.com/raspberrypi/firmware/raw/$firmware/extra/uname_string7")"
		printf "Uname string: %s\n" "$uname"
	fi

	printf "\nPackages:\n"
	dpkg -l --root "$ROOTFS_DIR"
} >> "$INFO_FILE"

if hash syft 2>/dev/null; then
	syft scan dir:"${ROOTFS_DIR}" \
		--base-path="${ROOTFS_DIR}" \
		--source-name="${IMG_NAME}${IMG_SUFFIX}" \
		--source-version="${IMG_DATE}" \
		-o spdx-json="${SBOM_FILE}"
fi

ROOT_DEV="$(awk "\$2 == \"${ROOTFS_DIR}\" {print \$1}" /etc/mtab)"

unmount "${ROOTFS_DIR}"
zerofree "${ROOT_DEV}"

unmount_image "${IMG_FILE}"

if hash bmaptool 2>/dev/null; then
	bmaptool create \
		-o "${BMAP_FILE}" \
		"${IMG_FILE}"
fi

mkdir -p "${DEPLOY_DIR}"

rm -f "${DEPLOY_DIR}/${ARCHIVE_FILENAME}${IMG_SUFFIX}.*"
rm -f "${DEPLOY_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.img"

case "${DEPLOY_COMPRESSION}" in
zip)
	pushd "${STAGE_WORK_DIR}" > /dev/null
	zip -"${COMPRESSION_LEVEL}" \
	"${DEPLOY_DIR}/${ARCHIVE_FILENAME}${IMG_SUFFIX}.zip" "$(basename "${IMG_FILE}")"
	popd > /dev/null
	;;
gz)
	pigz --force -"${COMPRESSION_LEVEL}" "$IMG_FILE" --stdout > \
	"${DEPLOY_DIR}/${ARCHIVE_FILENAME}${IMG_SUFFIX}.img.gz"
	;;
xz)
	xz --compress --force --threads 0 --memlimit-compress=50% -"${COMPRESSION_LEVEL}" \
	--stdout "$IMG_FILE" > "${DEPLOY_DIR}/${ARCHIVE_FILENAME}${IMG_SUFFIX}.img.xz"
	;;
none | *)
	cp "$IMG_FILE" "$DEPLOY_DIR/"
;;
esac

if [ -f "${SBOM_FILE}" ]; then
	xz -c "${SBOM_FILE}" > "$DEPLOY_DIR/$(basename "${SBOM_FILE}").xz"
fi
if [ -f "${BMAP_FILE}" ]; then
	cp "$BMAP_FILE" "$DEPLOY_DIR/"
fi
cp "$INFO_FILE" "$DEPLOY_DIR/"
