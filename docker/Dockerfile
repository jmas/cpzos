# Builder for cpz-arch.
#
# The image is trivial by design: it is Arch Linux ARM itself, plus the few
# tools needed to assemble a disk image without loop devices (Docker Desktop on
# macOS has no losetup). Scripts run inside it as root and write to the
# bind-mounted build directory.

FROM debian:bookworm-slim AS fetch

# The ALARM mirror presents a certificate that does not match
# os.archlinuxarm.org, so plain HTTP plus the published MD5 is the only working
# path. The tarball is a bootstrap only: `pacman -Syu base` inside the builder
# installs the rootfs from the current package set either way.
ARG ALARM_TARBALL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /rootfs \
 && cd /tmp \
 && curl -fsSL "$ALARM_TARBALL"      -o alarm.tar.gz \
 && curl -fsSL "$ALARM_TARBALL.md5"  -o alarm.md5 \
 && expected=$(cut -d' ' -f1 alarm.md5) \
 && actual=$(md5sum alarm.tar.gz | cut -d' ' -f1) \
 && [ "$expected" = "$actual" ] \
 && tar -xzf alarm.tar.gz -C /rootfs \
 && rm -f alarm.tar.gz alarm.md5

FROM scratch

COPY --from=fetch /rootfs/ /

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8

# One-time tooling for the builder only (never installed into the target):
#   mtools      FAT32 boot partition on a plain file (no loop device)
#   e2fsprogs   mke2fs -d to populate ext4 from a directory tree
#   sfdisk      MBR with a deterministic disk identifier
#   xz/zstd     compression
# pacman 7 downloads as an unprivileged user by default; inside a container
# that user cannot write to bind mounts, so the sandbox is disabled here.
RUN sed -i -e '/^DownloadUser/d' -e '/^CheckSpace/d' /etc/pacman.conf \
 && cp /etc/pacman.conf /etc/pacman-cpz.conf \
 && pacman-key --init \
 && pacman-key --populate archlinuxarm \
 && pacman -Syy --noconfirm --needed \
      mtools e2fsprogs util-linux xz zstd ca-certificates git \
 && rm -rf /var/cache/pacman/pkg/*

CMD ["/bin/bash"]
