/*
 * cpz-session — DRM broker and appliance supervisor.
 *
 * The session is the only process that owns DRM. It selects the panel or HDMI,
 * sets the mode, creates two dumb buffers and hands the DRM fd plus buffer
 * metadata to cpz-term, which runs as the unprivileged cpz user. cpz-term
 * renders and page-flips; the session restarts it on output changes or crashes.
 *
 * It also owns the panel backlight and exposes /run/cpz/session.sock for
 * cpz-ctl (output switch, terminal restart, optional GUI handover, power).
 *
 * Build: gcc -O2 -Wall -Wextra cpz-session.c -o cpz-session \
 *            -ludev -ldrm
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <grp.h>
#include <libudev.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#define DEFAULT_TERM      "/usr/local/bin/cpz-term"
#define DEFAULT_SOCKET    "/run/cpz/session.sock"
#define DEFAULT_BACKLIGHT "/usr/local/bin/cpz-backlight"
#define TERM_HEARTBEAT "/run/cpz/term.heartbeat"
#define MAX_CMD           2048
#define MAX_ARGS          32

enum output {
	OUT_NONE = 0,
	OUT_PANEL,
	OUT_HDMI,
};

enum mode {
	MODE_NONE = 0,
	MODE_TERM,
	MODE_GUI,
};

struct drm_state {
	int fd;
	uint32_t crtc_id;
	uint32_t conn_id;
	uint32_t width;
	uint32_t height;
	uint32_t stride;
	uint64_t size;
	uint32_t fb[2];
	uint32_t handle[2];
	uint64_t offset[2];
	int front;
	drmModeModeInfo mode;
};

struct session {
	char term[PATH_MAX];
	char socket_path[PATH_MAX];
	char backlight[PATH_MAX];
	char drm_root[PATH_MAX];

	pid_t child;
	enum mode mode;
	enum output out;
	int card_index;
	char card[32];
	char output_name[128];

	int force;              /* 0 auto, 1 panel, 2 hdmi */
	int pending_switch;
	int quit;
	int debug;
	int ready_sent;

	int ctl_fd;
	int sfd;
	struct udev *udev;
	struct udev_monitor *udev_mon;
	int udev_fd;

	struct drm_state drm;
};

static void logmsg(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

#define dbg(...) do { if (s->debug) logmsg(__VA_ARGS__); } while (0)

static int term_heartbeat_stale(void)
{
	struct stat st;
	if (stat(TERM_HEARTBEAT, &st) < 0)
		return 0;
	return (uint64_t)time(NULL) > (uint64_t)st.st_mtime + 5;
}

static int read_text(const char *path, char *buf, size_t len)
{
	FILE *f = fopen(path, "r");
	size_t n;

	if (!f)
		return -1;
	if (!fgets(buf, (int)len, f)) {
		fclose(f);
		return -1;
	}
	fclose(f);
	n = strlen(buf);
	while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
		buf[--n] = '\0';
	return 0;
}

static const char *output_name(enum output out)
{
	switch (out) {
	case OUT_PANEL: return "panel";
	case OUT_HDMI:  return "hdmi";
	default:        return "none";
	}
}

/*
 * Find a connected output. HDMI wins over the panel unless forced. Card
 * numbers are never assumed: the index comes from the sysfs connector name.
 */
static int find_output(struct session *s)
{
	glob_t g;
	enum output found = OUT_NONE;
	int found_index = -1;
	char found_card[32] = "";
	char found_name[128] = "";
	int ret = -1;
	char pattern[PATH_MAX + 32];

	snprintf(pattern, sizeof(pattern), "%s/card[0-9]*-*/status", s->drm_root);
	if (glob(pattern, 0, NULL, &g) != 0)
		return -1;

	for (size_t i = 0; i < g.gl_pathc; i++) {
		char status[32];
		char path[PATH_MAX];
		char name[128];
		char *slash;
		char *base;
		int idx;
		enum output type;

		snprintf(path, sizeof(path), "%s", g.gl_pathv[i]);
		slash = strrchr(path, '/');
		if (!slash)
			continue;
		*slash = '\0';
		base = strrchr(path, '/');
		base = base ? base + 1 : path;
		snprintf(name, sizeof(name), "%.*s", (int)sizeof(name) - 1, base);

		if (sscanf(name, "card%d-", &idx) != 1)
			continue;
		if (strstr(name, "HDMI"))
			type = OUT_HDMI;
		else if (strstr(name, "SPI"))
			type = OUT_PANEL;
		else
			continue;

		if (read_text(g.gl_pathv[i], status, sizeof(status)) < 0)
			continue;
		if (strcmp(status, "connected") != 0)
			continue;

		{
			char modes_path[PATH_MAX];
			char first_mode[64];
			snprintf(modes_path, sizeof(modes_path), "%s", g.gl_pathv[i]);
			char *dot = strrchr(modes_path, '/');
			if (dot)
				snprintf(dot + 1,
					 sizeof(modes_path) - (size_t)(dot + 1 - modes_path),
					 "modes");
			if (read_text(modes_path, first_mode, sizeof(first_mode)) < 0 ||
			    first_mode[0] == '\0')
				continue;
		}

		if (type == OUT_PANEL && s->force != 2) {
			if (found != OUT_HDMI) {
				found = OUT_PANEL;
				found_index = idx;
				snprintf(found_card, sizeof(found_card), "card%d", idx);
				snprintf(found_name, sizeof(found_name), "%s", name);
			}
		} else if (type == OUT_HDMI && s->force != 1) {
			found = OUT_HDMI;
			found_index = idx;
			snprintf(found_card, sizeof(found_card), "card%d", idx);
			snprintf(found_name, sizeof(found_name), "%s", name);
			break;
		}
	}
	globfree(&g);

	if (found != OUT_NONE && found_index >= 0) {
		s->out = found;
		s->card_index = found_index;
		snprintf(s->card, sizeof(s->card), "%s", found_card);
		snprintf(s->output_name, sizeof(s->output_name), "%s", found_name);
		ret = 0;
	} else {
		s->out = OUT_NONE;
		s->card_index = -1;
		s->card[0] = '\0';
		s->output_name[0] = '\0';
	}
	return ret;
}

static int set_backlight(struct session *s, int on)
{
	pid_t pid;
	int status;

	if (access(s->backlight, X_OK) != 0)
		return 0;

	pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		execl(s->backlight, s->backlight, on ? "on" : "off", (char *)NULL);
		_exit(127);
	}
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
	return 0;
}

static void notify_systemd(const char *text)
{
	const char *sock = getenv("NOTIFY_SOCKET");
	struct sockaddr_un sa;
	int fd;

	if (!sock || !*sock)
		return;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	if (sock[0] == '@') {
		sa.sun_path[0] = '\0';
		snprintf(sa.sun_path + 1, sizeof(sa.sun_path) - 1, "%s", sock + 1);
	} else {
		snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", sock);
	}
	fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (fd < 0)
		return;
	(void)sendto(fd, text, strlen(text), MSG_NOSIGNAL,
		     (struct sockaddr *)&sa, sizeof(sa));
	close(fd);
}

static uint32_t connector_type_for(enum output out)
{
	return out == OUT_PANEL ? DRM_MODE_CONNECTOR_SPI
				: DRM_MODE_CONNECTOR_HDMIA;
}

static int pick_mode(drmModeConnector *conn, enum output out,
		     drmModeModeInfo *mode)
{
	int best = -1;

	for (int i = 0; i < conn->count_modes; i++) {
		drmModeModeInfo *m = &conn->modes[i];
		if (!(m->type & DRM_MODE_TYPE_PREFERRED) && best >= 0)
			continue;
		if (out == OUT_HDMI && (m->hdisplay > 1920 || m->vdisplay > 1080))
			continue;
		*mode = *m;
		if (m->type & DRM_MODE_TYPE_PREFERRED)
			return 0;
		best = i;
	}
	if (best >= 0) {
		*mode = conn->modes[best];
		return 0;
	}
	if (conn->count_modes > 0) {
		*mode = conn->modes[0];
		return 0;
	}
	return -1;
}

static int create_dumb(struct drm_state *d, int i)
{
	struct drm_mode_create_dumb creq;
	struct drm_mode_map_dumb mreq;
	uint32_t fb;

	memset(&creq, 0, sizeof(creq));
	creq.width = d->width;
	creq.height = d->height;
	creq.bpp = 32;
	if (drmIoctl(d->fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0)
		return -1;
	d->handle[i] = creq.handle;
	d->stride = creq.pitch;
	d->size = creq.size;
	if (drmModeAddFB(d->fd, d->width, d->height, 24, 32, d->stride,
			 d->handle[i], &fb) < 0)
		return -1;
	d->fb[i] = fb;
	memset(&mreq, 0, sizeof(mreq));
	mreq.handle = d->handle[i];
	if (drmIoctl(d->fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0)
		return -1;
	d->offset[i] = mreq.offset;
	return 0;
}

static void destroy_drm(struct session *s)
{
	struct drm_state *d = &s->drm;

	if (d->fd < 0)
		return;
	for (int i = 0; i < 2; i++) {
		if (d->fb[i])
			drmModeRmFB(d->fd, d->fb[i]);
		if (d->handle[i]) {
			struct drm_mode_destroy_dumb dreq = { .handle = d->handle[i] };
			drmIoctl(d->fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
		}
	}
	drmDropMaster(d->fd);
	close(d->fd);
	memset(d, 0, sizeof(*d));
	d->fd = -1;
}

/*
 * Set the selected mode on the selected card and create two dumb buffers.
 * The first buffer is filled with the shell background before it is scanned
 * out, so the panel never shows uninitialised memory.
 */
static int setup_drm(struct session *s)
{
	char path[PATH_MAX];
	drmModeRes *res = NULL;
	drmModeConnector *conn = NULL;
	drmModeEncoder *enc = NULL;
	struct drm_state *d = &s->drm;
	int rc = -1;

	memset(d, 0, sizeof(*d));
	d->fd = -1;
	snprintf(path, sizeof(path), "/dev/dri/%s", s->card);
	d->fd = open(path, O_RDWR | O_CLOEXEC);
	if (d->fd < 0) {
		logmsg("cpz-session: open %s: %s\n", path, strerror(errno));
		return -1;
	}
	if (drmSetMaster(d->fd) < 0) {
		logmsg("cpz-session: drmSetMaster: %s\n", strerror(errno));
		goto out;
	}
	res = drmModeGetResources(d->fd);
	if (!res)
		goto out;

	for (int i = 0; i < res->count_connectors; i++) {
		drmModeConnector *c = drmModeGetConnector(d->fd, res->connectors[i]);
		if (!c)
			continue;
		if (c->connector_type == connector_type_for(s->out) &&
		    c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) {
			conn = c;
			break;
		}
		drmModeFreeConnector(c);
	}
	if (!conn) {
		logmsg("cpz-session: no connector for %s\n", output_name(s->out));
		goto out;
	}
	d->conn_id = conn->connector_id;
	if (pick_mode(conn, s->out, &d->mode) < 0)
		goto out;

	if (conn->encoder_id)
		enc = drmModeGetEncoder(d->fd, conn->encoder_id);
	if (enc && enc->crtc_id) {
		d->crtc_id = enc->crtc_id;
	} else if (res->count_crtcs > 0) {
		d->crtc_id = res->crtcs[0];
	} else {
		goto out;
	}
	if (enc) {
		drmModeFreeEncoder(enc);
		enc = NULL;
	}

	d->width = d->mode.hdisplay;
	d->height = d->mode.vdisplay;
	if (create_dumb(d, 0) < 0 || create_dumb(d, 1) < 0)
		goto out;

	{
		void *map = mmap(NULL, d->size, PROT_READ | PROT_WRITE,
				 MAP_SHARED, d->fd, d->offset[0]);
		if (map == MAP_FAILED)
			goto out;
		uint32_t *p = map;
		uint32_t bg = 0x000e1116; /* XRGB8888 */
		for (uint32_t y = 0; y < d->height; y++)
			for (uint32_t x = 0; x < d->width; x++)
				p[y * (d->stride / 4) + x] = bg;
		munmap(map, d->size);
	}

	if (drmModeSetCrtc(d->fd, d->crtc_id, d->fb[0], 0, 0,
			   &d->conn_id, 1, &d->mode) < 0) {
		logmsg("cpz-session: drmModeSetCrtc: %s\n", strerror(errno));
		goto out;
	}
	d->front = 0;
	logmsg("cpz-session: %s %s %ux%u@%u\n", output_name(s->out),
	       s->output_name, d->width, d->height, d->mode.vrefresh);
	rc = 0;
out:
	if (conn)
		drmModeFreeConnector(conn);
	if (res)
		drmModeFreeResources(res);
	if (rc < 0)
		destroy_drm(s);
	return rc;
}

static void read_setting(const char *key, char *out, size_t len,
			 const char *def)
{
	static const char *paths[] = {
		"/home/cpz/.config/cpz/settings.conf",
		"/etc/cpz/settings.conf",
		NULL,
	};
	char line[256];

	snprintf(out, len, "%s", def);
	for (int i = 0; paths[i]; i++) {
		FILE *f = fopen(paths[i], "r");
		if (!f)
			continue;
		while (fgets(line, sizeof(line), f)) {
			char *eq = strchr(line, '=');
			if (!eq)
				continue;
			*eq = '\0';
			if (strcmp(line, key))
				continue;
			char *v = eq + 1;
			size_t n = strlen(v);
			while (n && (v[n - 1] == '\n' || v[n - 1] == '\r'))
				v[--n] = '\0';
			snprintf(out, len, "%s", v);
			fclose(f);
			return;
		}
		fclose(f);
	}
}

static void export_term_env(struct session *s)
{
	char buf[64];
	char setting[64];
	struct drm_state *d = &s->drm;

	setenv("CPZ_DRM_FD", "3", 1);
	setenv("CPZ_DRM_CARD", s->card, 1);
	setenv("CPZ_OUTPUT", output_name(s->out), 1);
	setenv("CPZ_OUTPUT_NAME", s->output_name, 1);
	snprintf(buf, sizeof(buf), "%u", d->width);
	setenv("CPZ_FB_WIDTH", buf, 1);
	snprintf(buf, sizeof(buf), "%u", d->height);
	setenv("CPZ_FB_HEIGHT", buf, 1);
	snprintf(buf, sizeof(buf), "%u", d->stride);
	setenv("CPZ_FB_STRIDE", buf, 1);
	snprintf(buf, sizeof(buf), "%llu", (unsigned long long)d->size);
	setenv("CPZ_FB_SIZE", buf, 1);
	snprintf(buf, sizeof(buf), "%u", d->crtc_id);
	setenv("CPZ_CRTC_ID", buf, 1);
	snprintf(buf, sizeof(buf), "%u", d->fb[0]);
	setenv("CPZ_FB0_ID", buf, 1);
	snprintf(buf, sizeof(buf), "%u", d->fb[1]);
	setenv("CPZ_FB1_ID", buf, 1);
	snprintf(buf, sizeof(buf), "%llu", (unsigned long long)d->offset[0]);
	setenv("CPZ_FB0_OFFSET", buf, 1);
	snprintf(buf, sizeof(buf), "%llu", (unsigned long long)d->offset[1]);
	setenv("CPZ_FB1_OFFSET", buf, 1);
	setenv("CPZ_FB_FORMAT", "xrgb8888", 1);
	read_setting(s->out == OUT_PANEL ? "font_size_panel" : "font_size_hdmi",
		     setting, sizeof(setting),
		     s->out == OUT_PANEL ? "10" : "24");
	setenv("CPZ_FONT_PX", setting, 1);
	read_setting("layout", setting, sizeof(setting), "us,ua");
	setenv("XKB_DEFAULT_LAYOUT", setting, 1);
	setenv("XKB_DEFAULT_OPTIONS", "grp:alt_shift_toggle", 1);
	setenv("TERM", "xterm-256color", 1);
	setenv("COLORTERM", "truecolor", 1);
	setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
	setenv("LANG", "C.UTF-8", 1);
	setenv("LC_ALL", "C.UTF-8", 1);
}

static void drop_to_user(void)
{
	struct passwd *pw = getpwnam("cpz");

	if (geteuid() == 0 && pw) {
		setgid(pw->pw_gid);
		initgroups(pw->pw_name, pw->pw_gid);
		setuid(pw->pw_uid);
		chdir(pw->pw_dir);
		setenv("HOME", pw->pw_dir, 1);
		setenv("USER", pw->pw_name, 1);
		setenv("LOGNAME", pw->pw_name, 1);
		setenv("XDG_RUNTIME_DIR", "/run/user/1000", 1);
		setenv("TMUX_TMPDIR", "/run/cpz", 1);
	}
}

static int spawn_term(struct session *s)
{
	pid_t pid;
	int devnull;

	if (s->drm.fd < 0 && setup_drm(s) < 0)
		return -1;

	export_term_env(s);
	unlink(TERM_HEARTBEAT);
	pid = fork();
	if (pid < 0) {
		logmsg("cpz-session: fork: %s\n", strerror(errno));
		return -1;
	}
	if (pid == 0) {
		prctl(PR_SET_PDEATHSIG, SIGTERM);
		/* Keep the DRM fd in a fixed slot across exec. */
		if (s->drm.fd != 3) {
			if (dup2(s->drm.fd, 3) < 0)
				_exit(127);
		}
		fcntl(3, F_SETFD, 0);
		devnull = open("/dev/null", O_RDWR);
		if (devnull >= 0) {
			dup2(devnull, STDIN_FILENO);
			dup2(devnull, STDOUT_FILENO);
			if (devnull > STDERR_FILENO)
				close(devnull);
		}
		drop_to_user();
		execl(s->term, s->term, (char *)NULL);
		logmsg("cpz-session: exec %s: %s\n", s->term, strerror(errno));
		_exit(127);
	}
	s->child = pid;
	s->mode = MODE_TERM;
	logmsg("cpz-session: terminal pid %d on %s\n", (int)pid,
	       output_name(s->out));
	if (!s->ready_sent) {
		notify_systemd("READY=1");
		s->ready_sent = 1;
	}
	return 0;
}

static void stop_child(struct session *s)
{
	int status;
	int i;

	if (s->child <= 0)
		return;
	kill(s->child, SIGTERM);
	for (i = 0; i < 100; i++) {
		pid_t p = waitpid(s->child, &status, WNOHANG);
		if (p == s->child || (p < 0 && errno == ECHILD))
			break;
		usleep(20 * 1000);
	}
	if (i == 100) {
		kill(s->child, SIGKILL);
		while (waitpid(s->child, &status, 0) < 0 && errno == EINTR)
			;
	}
	logmsg("cpz-session: stopped pid %d\n", (int)s->child);
	s->child = 0;
	s->mode = MODE_NONE;
}

static void start_term(struct session *s)
{
	if (s->drm.fd < 0 && setup_drm(s) < 0) {
		logmsg("cpz-session: no DRM; retrying\n");
		return;
	}
	set_backlight(s, s->out == OUT_PANEL);
	spawn_term(s);
}

static void rescan_output(struct session *s, int reason)
{
	enum output old = s->out;
	char old_card[32];
	int old_index = s->card_index;

	snprintf(old_card, sizeof(old_card), "%s", s->card);
	find_output(s);
	if (s->out == old && s->card_index == old_index)
		return;

	logmsg("cpz-session: output %s (%s) -> %s (%s), reason %d\n",
	       output_name(old), old_card, output_name(s->out), s->card, reason);

	if (s->mode == MODE_GUI) {
		s->pending_switch = 1;
		return;
	}
	stop_child(s);
	destroy_drm(s);
	if (s->out == OUT_NONE)
		return;
	start_term(s);
}

static int run_gui(struct session *s, const char *cmd)
{
	char buf[MAX_CMD];
	char *argv[MAX_ARGS];
	int argc = 0;
	pid_t pid;
	char *p;

	if (!cmd || cmd[0] != '/' || strstr(cmd, "..")) {
		logmsg("cpz-session: refusing gui '%s'\n", cmd ? cmd : "");
		return -1;
	}
	snprintf(buf, sizeof(buf), "%s", cmd);
	for (p = strtok(buf, " \t"); p && argc < MAX_ARGS - 1; p = strtok(NULL, " \t"))
		argv[argc++] = p;
	argv[argc] = NULL;
	if (!argc)
		return -1;

	stop_child(s);
	destroy_drm(s);
	pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		prctl(PR_SET_PDEATHSIG, SIGTERM);
		/* GUI apps are trusted local programs and may need DRM master. */
		char idx[16];
		snprintf(idx, sizeof(idx), "%d", s->card_index);
		setenv("CPZ_OUTPUT", output_name(s->out), 1);
		setenv("CPZ_DRM_CARD", s->card, 1);
		setenv("SDL_VIDEODRIVER", "kmsdrm", 1);
		setenv("SDL_KMSDRM_DEVICE_INDEX", idx, 1);
		execl(argv[0], argv[0], argv[1], argv[2], argv[3], argv[4],
		      argv[5], argv[6], argv[7], argv[8], argv[9], (char *)NULL);
		_exit(127);
	}
	s->child = pid;
	s->mode = MODE_GUI;
	logmsg("cpz-session: gui pid %d: %s\n", (int)pid, argv[0]);
	return 0;
}

static int open_control(struct session *s)
{
	struct sockaddr_un sa;
	int fd;

	if (strlen(s->socket_path) >= sizeof(sa.sun_path))
		return -1;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", s->socket_path);
	mkdir("/run/cpz", 0755);
	unlink(s->socket_path);
	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	if (fd < 0)
		return -1;
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0 ||
	    listen(fd, 16) < 0) {
		close(fd);
		return -1;
	}
	chmod(s->socket_path, 0660);
	{
		struct group *gr = getgrnam("cpz");
		if (gr)
			chown(s->socket_path, 0, gr->gr_gid);
	}
	return fd;
}

static void handle_control(struct session *s, int fd, char *line)
{
	char reply[256];

	if (!strcmp(line, "status")) {
		snprintf(reply, sizeof(reply), "ok %s %s %s\n",
			 s->mode == MODE_TERM ? "term" :
			 s->mode == MODE_GUI ? "gui" : "none",
			 output_name(s->out), s->card);
		(void)write(fd, reply, strlen(reply));
	} else if (!strncmp(line, "output ", 7)) {
		const char *arg = line + 7;
		if (!strcmp(arg, "panel"))
			s->force = 1;
		else if (!strcmp(arg, "hdmi"))
			s->force = 2;
		else
			s->force = 0;
		(void)write(fd, "ok\n", 3);
		rescan_output(s, 1);
	} else if (!strcmp(line, "restart-term")) {
		(void)write(fd, "ok\n", 3);
		stop_child(s);
		destroy_drm(s);
		start_term(s);
	} else if (!strncmp(line, "gui ", 4)) {
		(void)write(fd, "ok\n", 3);
		run_gui(s, line + 4);
	} else if (!strcmp(line, "poweroff") || !strcmp(line, "reboot")) {
		(void)write(fd, "ok\n", 3);
		pid_t p = fork();
		if (p == 0) {
			execl("/usr/bin/systemctl", "systemctl",
			      !strcmp(line, "reboot") ? "reboot" : "poweroff",
			      (char *)NULL);
			_exit(127);
		}
	} else {
		(void)write(fd, "err unknown\n", 12);
	}
}

static void accept_control(struct session *s)
{
	for (;;) {
		int fd = accept4(s->ctl_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
		char buf[MAX_CMD + 1];
		ssize_t n;

		if (fd < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				return;
			if (errno == EINTR)
				continue;
			return;
		}
		n = read(fd, buf, sizeof(buf) - 1);
		if (n > 0) {
			buf[n] = '\0';
			char *nl = strchr(buf, '\n');
			if (nl)
				*nl = '\0';
			handle_control(s, fd, buf);
		}
		close(fd);
	}
}

static void setup_udev(struct session *s)
{
	s->udev = udev_new();
	if (!s->udev)
		return;
	s->udev_mon = udev_monitor_new_from_netlink(s->udev, "udev");
	if (!s->udev_mon)
		return;
	udev_monitor_filter_add_match_subsystem_devtype(s->udev_mon, "drm", NULL);
	if (udev_monitor_enable_receiving(s->udev_mon) < 0) {
		udev_monitor_unref(s->udev_mon);
		s->udev_mon = NULL;
		return;
	}
	s->udev_fd = udev_monitor_get_fd(s->udev_mon);
}

static void handle_udev(struct session *s)
{
	int changed = 0;

	while (s->udev_mon) {
		struct udev_device *dev = udev_monitor_receive_device(s->udev_mon);
		if (!dev)
			break;
		const char *action = udev_device_get_action(dev);
		if (action && (!strcmp(action, "change") || !strcmp(action, "add") ||
			       !strcmp(action, "remove")))
			changed = 1;
		udev_device_unref(dev);
	}
	if (changed)
		rescan_output(s, 2);
}

static void usage(FILE *out)
{
	fputs("usage: cpz-session [--term PATH] [--socket PATH] "
	      "[--backlight PATH] [--output auto|panel|hdmi] "
	      "[--probe] [--debug]\n", out);
}

int main(int argc, char **argv)
{
	struct session s;
	struct signalfd_siginfo si;
	sigset_t mask;
	int timeout = 1000;

	memset(&s, 0, sizeof(s));
	s.drm.fd = -1;
	snprintf(s.term, sizeof(s.term), "%s", DEFAULT_TERM);
	snprintf(s.socket_path, sizeof(s.socket_path), "%s", DEFAULT_SOCKET);
	snprintf(s.backlight, sizeof(s.backlight), "%s", DEFAULT_BACKLIGHT);
	snprintf(s.drm_root, sizeof(s.drm_root), "%s",
		 getenv("CPZ_DRM_ROOT") && *getenv("CPZ_DRM_ROOT") ?
		 getenv("CPZ_DRM_ROOT") : "/sys/class/drm");

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--term") && i + 1 < argc)
			snprintf(s.term, sizeof(s.term), "%s", argv[++i]);
		else if (!strcmp(argv[i], "--socket") && i + 1 < argc)
			snprintf(s.socket_path, sizeof(s.socket_path), "%s", argv[++i]);
		else if (!strcmp(argv[i], "--backlight") && i + 1 < argc)
			snprintf(s.backlight, sizeof(s.backlight), "%s", argv[++i]);
		else if (!strcmp(argv[i], "--output") && i + 1 < argc) {
			if (!strcmp(argv[++i], "panel"))
				s.force = 1;
			else if (!strcmp(argv[i], "hdmi"))
				s.force = 2;
			else
				s.force = 0;
		} else if (!strcmp(argv[i], "--probe")) {
			find_output(&s);
			printf("%s %s %d\n", output_name(s.out), s.card,
			       s.card_index);
			return s.out == OUT_NONE ? 1 : 0;
		} else if (!strcmp(argv[i], "--debug"))
			s.debug = 1;
		else if (!strcmp(argv[i], "--version")) {
			printf("cpz-session 1.0.0 (drm broker)\n");
			return 0;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(stdout);
			return 0;
		} else {
			usage(stderr);
			return 2;
		}
	}

	if (!s.force) {
		char configured[32];
		read_setting("output", configured, sizeof(configured), "auto");
		if (!strcmp(configured, "panel"))
			s.force = 1;
		else if (!strcmp(configured, "hdmi"))
			s.force = 2;
	}

	signal(SIGPIPE, SIG_IGN);
	sigemptyset(&mask);
	sigaddset(&mask, SIGCHLD);
	sigaddset(&mask, SIGTERM);
	sigaddset(&mask, SIGINT);
	sigaddset(&mask, SIGHUP);
	sigprocmask(SIG_BLOCK, &mask, NULL);
	s.sfd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);

	s.ctl_fd = open_control(&s);
	if (s.ctl_fd < 0) {
		logmsg("cpz-session: control socket: %s\n", strerror(errno));
		return 1;
	}
	setup_udev(&s);

	if (find_output(&s) < 0) {
		logmsg("cpz-session: no output; waiting\n");
	} else {
		start_term(&s);
	}

	while (!s.quit) {
		struct pollfd pfd[3];
		int nfds = 0;
		int idx_ctl = -1, idx_udev = -1, idx_sig = -1;

		pfd[nfds].fd = s.ctl_fd;
		pfd[nfds].events = POLLIN;
		idx_ctl = nfds++;
		if (s.udev_fd > 0) {
			pfd[nfds].fd = s.udev_fd;
			pfd[nfds].events = POLLIN;
			idx_udev = nfds++;
		}
		pfd[nfds].fd = s.sfd;
		pfd[nfds].events = POLLIN;
		idx_sig = nfds++;

		int r = poll(pfd, (nfds_t)nfds, timeout);
		if (r < 0 && errno != EINTR) {
			logmsg("cpz-session: poll: %s\n", strerror(errno));
			break;
		}
		if (idx_ctl >= 0 && (pfd[idx_ctl].revents & POLLIN))
			accept_control(&s);
		if (idx_udev >= 0 && (pfd[idx_udev].revents & POLLIN))
			handle_udev(&s);
		if (idx_sig >= 0 && (pfd[idx_sig].revents & POLLIN)) {
			while (read(s.sfd, &si, sizeof(si)) == sizeof(si)) {
				if (si.ssi_signo == SIGCHLD) {
					int status;
					pid_t p;
					while ((p = waitpid(-1, &status, WNOHANG)) > 0) {
						if (p != s.child)
							continue;
						int was_gui = s.mode == MODE_GUI;
						s.child = 0;
						s.mode = MODE_NONE;
						if (was_gui || s.pending_switch) {
							s.pending_switch = 0;
							destroy_drm(&s);
							find_output(&s);
							if (s.out != OUT_NONE)
								start_term(&s);
						} else {
							usleep(200 * 1000);
							start_term(&s);
						}
					}
				} else if (si.ssi_signo == SIGHUP) {
					rescan_output(&s, 3);
				} else {
					s.quit = 1;
				}
			}
		}
		if (s.child > 0 && s.mode == MODE_TERM && term_heartbeat_stale()) {
			logmsg("cpz-session: terminal heartbeat lost; restarting\n");
			stop_child(&s);
			start_term(&s);
		}
		notify_systemd("WATCHDOG=1");
	}

	stop_child(&s);
	destroy_drm(&s);
	if (s.ctl_fd >= 0)
		close(s.ctl_fd);
	if (s.udev_mon)
		udev_monitor_unref(s.udev_mon);
	if (s.udev)
		udev_unref(s.udev);
	if (s.sfd >= 0)
		close(s.sfd);
	unlink(s.socket_path);
	return 0;
}
