#!/bin/bash -e

# Install the CPZ graphics session.
#
# The session is a Wayland kiosk, not a desktop: cage runs one fullscreen
# terminal (foot) on tty1, and the CPZ tmux session lives inside it. Programs
# launched from tmux open as Wayland/X11 windows on top of the terminal and
# return to it when they close. There is no per-application graphics mode.
#
# cage pulls wlroots, libinput and the Wayland stack. Xwayland is installed
# explicitly: the Raspberry Pi build does not depend on it. The Mesa DRI
# drivers are needed for GLES on HDMI and for the software kms_swrast fallback
# on the panel. foot is the terminal; it uses wl_shm, so it also works on the
# panel with the pixman renderer.

on_chroot << 'CHROOT'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends \
	cage \
	foot \
	libgl1-mesa-dri \
	xauth \
	xwayland
CHROOT
