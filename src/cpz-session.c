/*
 * cpz-session — the Cardputer Zero appliance session supervisor.
 *
 * This process does NOT own DRM and does not draw. It:
 *
 *   - finds the connected output (internal SPI panel or HDMI),
 *   - exports the SDL/KMSDRM environment for the selected card,
 *   - starts cpz-ui (or a requested fullscreen app) and restarts it when it
 *     exits or crashes,
 *   - moves the session to the other output by stopping the current child and
 *     starting a fresh one (a process boundary, not a live modeset),
 *   - owns the panel backlight state,
 *   - exposes /run/cpz/session.sock for the launcher.
 *
 * The important design rule is that only one child owns the display at a time.
 * A crash cannot leave the display "handed over" forever, because the child is
 * just a process: when it dies, the supervisor starts the UI again.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-session.c -o cpz-session -ludev
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
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "cpz-json.h"

#define DEFAULT_UI      "/usr/local/bin/cpz-ui"
#define DEFAULT_SOCKET  "/run/cpz/session.sock"
#define DEFAULT_BACKLIGHT "/usr/local/bin/cpz-backlight"
#define MAX_CMD         2048
#define MAX_ARGS        32

enum output {
	OUT_NONE = 0,
	OUT_PANEL,
	OUT_HDMI,
};

enum mode {
	MODE_NONE = 0,
	MODE_UI,
	MODE_APP,
};

struct session {
	char ui[PATH_MAX];
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
	int once;
	int ready_sent;

	int ctl_fd;
	int sfd;
	struct udev *udev;
	struct udev_monitor *udev_mon;
	int udev_fd;

	char app_cmd[MAX_CMD];
	uint64_t restart_at_ms;
};

static void logmsg(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

#define dbg(...) do { if (s->debug) logmsg(__VA_ARGS__); } while (0)

static uint64_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

/*
 * The launcher writes this file once a second. A frozen UI still leaves the
 * supervisor healthy (and therefore the hardware watchdog quiet), so the
 * supervisor watches the launcher itself and restarts it when it stops
 * responding.
 */
#define UI_HEARTBEAT "/run/cpz/ui.heartbeat"

static void touch_ui_heartbeat(void)
{
	int fd = open(UI_HEARTBEAT, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd >= 0) {
		(void)write(fd, "1", 1);
		close(fd);
	}
}

static int ui_heartbeat_stale(void)
{
	struct stat st;
	if (stat(UI_HEARTBEAT, &st) < 0)
		return 0;
	return now_ms() / 1000 > (uint64_t)st.st_mtime + 5;
}

static int read_text(const char *path, char *buf, size_t len)
{
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	if (!fgets(buf, (int)len, f)) {
		fclose(f);
		return -1;
	}
	fclose(f);
	size_t n = strlen(buf);
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
 * Find a connected output. HDMI wins over the panel unless the user forced an
 * output. Card numbers are never assumed: the index is derived from the sysfs
 * connector name because card0/card1 ordering changes with probe order.
 *
 * Do not poke the connector's `status` sysfs file here. On vc4 that makes the
 * driver re-read EDID/ELD and can disturb an active HDMI link. This stack does
 * not force HDMI off on the command line, so there is nothing to un-force.
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

		/* A connector can be "connected" with no usable mode (bad
		 * EDID, a dock that is still waking up). Do not pick it. */
		{
			char modes_path[PATH_MAX];
			char first_mode[64];
			snprintf(modes_path, sizeof(modes_path), "%s", g.gl_pathv[i]);
			char *dot = strrchr(modes_path, '/');
			if (dot)
				snprintf(dot + 1, sizeof(modes_path) - (size_t)(dot + 1 - modes_path),
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
			break; /* HDMI is preferred; no need to keep looking */
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
		ret = -1;
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

static void export_env(struct session *s)
{
	char idx[16];
	char card[64];

	snprintf(idx, sizeof(idx), "%d", s->card_index);
	snprintf(card, sizeof(card), "/dev/dri/%s", s->card);

	setenv("SDL_VIDEODRIVER", "kmsdrm", 1);
	setenv("SDL_VIDEO_DRIVER", "kmsdrm", 1);
	/* SDL2 hint and the SDL3 property used by sdl2-compat. */
	setenv("SDL_KMSDRM_DEVICE_INDEX", idx, 1);
	setenv("SDL_VIDEO_KMSDRM_DEVICE_INDEX", idx, 1);
	setenv("SDL_KMSDRM_REQUIRE_DRM_MASTER", "1", 1);
	setenv("CPZ_OUTPUT", output_name(s->out), 1);
	setenv("CPZ_OUTPUT_NAME", s->output_name, 1);
	setenv("CPZ_DRM_CARD", card, 1);
	setenv("CPZ_DRM_CARD_INDEX", idx, 1);
	setenv("XKB_DEFAULT_LAYOUT", "us,ua", 1);
	setenv("XKB_DEFAULT_OPTIONS", "grp:alt_shift_toggle", 1);
	setenv("LANG", "C.UTF-8", 0);
	setenv("LC_ALL", "C.UTF-8", 0);
}

/* sd_notify without linking libsystemd. */
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

static int spawn_child(struct session *s, const char *path, char *const argv[],
		       enum mode mode)
{
	pid_t pid;

	export_env(s);
	pid = fork();
	if (pid < 0) {
		logmsg("cpz-session: fork: %s\n", strerror(errno));
		return -1;
	}
	if (pid == 0) {
		sigset_t none;
		prctl(PR_SET_PDEATHSIG, SIGTERM);
		sigemptyset(&none);
		sigprocmask(SIG_SETMASK, &none, NULL);
		execv(path, argv);
		logmsg("cpz-session: exec %s: %s\n", path, strerror(errno));
		_exit(127);
	}

	s->child = pid;
	s->mode = mode;
	s->restart_at_ms = 0;
	logmsg("cpz-session: started %s (pid %d) on %s (%s, card %d)\n",
	       mode == MODE_UI ? "UI" : "app", (int)pid,
	       output_name(s->out), s->output_name, s->card_index);
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

static int start_ui(struct session *s)
{
	/* The splash belongs to the first launcher of a boot. Restarts after an
	 * app, a crash or an output switch go straight to the menu. */
	char *argv[] = { s->ui, NULL, NULL };

	if (!s->ready_sent)
		argv[1] = "--splash";

	if (s->out == OUT_NONE)
		return -1;
	set_backlight(s, s->out == OUT_PANEL);
	touch_ui_heartbeat();
	int ret = spawn_child(s, s->ui, argv, MODE_UI);
	if (ret == 0 && !s->ready_sent) {
		notify_systemd("READY=1");
		s->ready_sent = 1;
	}
	return ret;
}

static int split_command(const char *line, char *buf, size_t buflen,
			 char *argv[], int maxargs)
{
	char *p, *save = NULL;
	int argc = 0;

	snprintf(buf, buflen, "%s", line);
	for (p = strtok_r(buf, " \t", &save); p; p = strtok_r(NULL, " \t", &save)) {
		if (argc >= maxargs - 1)
			break;
		argv[argc++] = p;
	}
	argv[argc] = NULL;
	return argc;
}

static int command_allowed(const char *path)
{
	static const char *prefixes[] = {
		"/usr/local/bin/",
		"/usr/local/sbin/",
		"/usr/bin/",
		"/usr/sbin/",
		"/bin/",
		"/sbin/",
		NULL,
	};

	if (!path || path[0] != '/' || strstr(path, ".."))
		return 0;
	for (int i = 0; prefixes[i]; i++) {
		size_t n = strlen(prefixes[i]);

		if (!strncmp(path, prefixes[i], n) && path[n])
			return 1;
	}
	return 0;
}

/*
 * A `run` action is a short background command. It must not take the display:
 * the shell stays visible. The child is detached, its stdio is discarded and
 * it is reaped by the normal SIGCHLD path (it is not s->child).
 */
static int spawn_background(struct session *s, char *const argv[])
{
	pid_t pid;

	if (!command_allowed(argv[0])) {
		logmsg("cpz-session: refusing '%s' (not in allowlist)\n",
		       argv[0] ? argv[0] : "");
		return -1;
	}
	pid = fork();
	if (pid < 0) {
		logmsg("cpz-session: fork run: %s\n", strerror(errno));
		return -1;
	}
	if (pid == 0) {
		int devnull;
		sigset_t none;

		setsid();
		prctl(PR_SET_PDEATHSIG, SIGTERM);
		sigemptyset(&none);
		sigprocmask(SIG_SETMASK, &none, NULL);
		devnull = open("/dev/null", O_RDWR);
		if (devnull >= 0) {
			dup2(devnull, STDIN_FILENO);
			dup2(devnull, STDOUT_FILENO);
			dup2(devnull, STDERR_FILENO);
			if (devnull > STDERR_FILENO)
				close(devnull);
		}
		execv(argv[0], argv);
		_exit(127);
	}
	logmsg("cpz-session: ran background %s (pid %d)\n", argv[0], (int)pid);
	(void)s;
	return 0;
}

static void start_app_argv(struct session *s, char *const argv[])
{
	enum output old;
	char old_card[32];

	if (!argv[0] || !command_allowed(argv[0])) {
		logmsg("cpz-session: refusing '%s' (not in allowlist)\n",
		       argv[0] ? argv[0] : "");
		return;
	}

	old = s->out;
	snprintf(old_card, sizeof(old_card), "%s", s->card);
	snprintf(s->app_cmd, sizeof(s->app_cmd), "%s", argv[0]);

	stop_child(s);
	/* Re-scan: the app must open the output that is connected now. */
	find_output(s);
	if (s->out == OUT_NONE) {
		logmsg("cpz-session: no output for '%s'; restarting UI\n",
		       argv[0]);
		if (start_ui(s) < 0)
			s->quit = 1;
		return;
	}
	if (s->out != old || strcmp(old_card, s->card) != 0)
		set_backlight(s, s->out == OUT_PANEL);

	if (spawn_child(s, argv[0], argv, MODE_APP) < 0) {
		if (start_ui(s) < 0)
			s->quit = 1;
	}
}

static void launch_app(struct session *s, const char *cmdline)
{
	char buf[MAX_CMD];
	char *argv[MAX_ARGS];
	int argc;

	if (!cmdline || !*cmdline)
		return;
	argc = split_command(cmdline, buf, sizeof(buf), argv, MAX_ARGS);
	if (argc > 0)
		start_app_argv(s, argv);
}

static void run_app(struct session *s, const char *cmdline)
{
	char buf[MAX_CMD];
	char *argv[MAX_ARGS];
	int argc;

	if (!cmdline || !*cmdline)
		return;
	argc = split_command(cmdline, buf, sizeof(buf), argv, MAX_ARGS);
	if (argc > 0)
		spawn_background(s, argv);
}

/* Parse {"argv":["/abs/path","arg"]} from a launch-json/run-json line. */
static void json_command(struct session *s, const char *json, int foreground)
{
	jv *o;
	jv *arr;
	int n;
	char *argv[MAX_ARGS];
	int argc = 0;

	o = jv_parse(json, strlen(json), NULL);
	if (!o)
		return;
	arr = jv_get(o, "argv");
	n = jv_len(arr);
	if (!arr || arr->type != JV_ARRAY || n < 1 || n >= MAX_ARGS) {
		jv_free(o);
		return;
	}
	for (int i = 0; i < n; i++) {
		const char *str = jv_str(jv_at(arr, i));

		if (!str) {
			jv_free(o);
			return;
		}
		argv[argc++] = (char *)str;
	}
	argv[argc] = NULL;
	if (foreground)
		start_app_argv(s, argv);
	else
		spawn_background(s, argv);
	jv_free(o);
}

static void handle_status(struct session *s, int fd)
{
	char msg[256];
	snprintf(msg, sizeof(msg), "ok %s %s %s %d\n",
		 s->mode == MODE_UI ? "ui" :
		 s->mode == MODE_APP ? "app" : "none",
		 output_name(s->out), s->card, s->card_index);
	(void)write(fd, msg, strlen(msg));
}

static void handle_control_line(struct session *s, int fd, char *line)
{
	size_t n = strlen(line);
	while (n && (line[n - 1] == '\n' || line[n - 1] == '\r'))
		line[--n] = '\0';

	if (!strcmp(line, "ping")) {
		(void)write(fd, "ok\n", 3);
	} else if (!strcmp(line, "status")) {
		handle_status(s, fd);
	} else if (!strncmp(line, "launch ", 7)) {
		const char *cmd = line + 7;
		while (*cmd == ' ')
			cmd++;
		(void)write(fd, "ok\n", 3);
		launch_app(s, cmd);
	} else if (!strncmp(line, "launch-json ", 12)) {
		const char *json = line + 12;
		while (*json == ' ')
			json++;
		(void)write(fd, "ok\n", 3);
		json_command(s, json, 1);
	} else if (!strncmp(line, "run-json ", 9)) {
		const char *json = line + 9;
		while (*json == ' ')
			json++;
		(void)write(fd, "ok\n", 3);
		json_command(s, json, 0);
	} else if (!strncmp(line, "run ", 4)) {
		const char *cmd = line + 4;
		while (*cmd == ' ')
			cmd++;
		(void)write(fd, "ok\n", 3);
		run_app(s, cmd);
	} else if (!strcmp(line, "home")) {
		(void)write(fd, "ok\n", 3);
		if (s->mode == MODE_APP) {
			stop_child(s);
			find_output(s);
			if (start_ui(s) < 0)
				s->quit = 1;
		}
	} else if (!strncmp(line, "output ", 7)) {
		const char *arg = line + 7;
		if (!strcmp(arg, "panel"))
			s->force = 1;
		else if (!strcmp(arg, "hdmi"))
			s->force = 2;
		else
			s->force = 0;
		(void)write(fd, "ok\n", 3);
		if (s->mode == MODE_UI) {
			stop_child(s);
			find_output(s);
			if (start_ui(s) < 0)
				s->quit = 1;
		} else {
			s->pending_switch = 1;
		}
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
		if (fd < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				return;
			if (errno == EINTR)
				continue;
			return;
		}
		char buf[MAX_CMD + 1];
		ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
		if (n > 0) {
			buf[n] = '\0';
			handle_control_line(s, fd, buf);
		}
		close(fd);
	}
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

	if (!strcmp(s->socket_path, DEFAULT_SOCKET))
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

	struct group *gr = getgrnam("video");
	if (gr)
		chown(s->socket_path, 0, gr->gr_gid);
	return fd;
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

	logmsg("cpz-session: output %s (%s, card %d) -> %s (%s, card %d), reason %d\n",
	       output_name(old), old_card, old_index,
	       output_name(s->out), s->card, s->card_index, reason);

	if (s->mode == MODE_APP) {
		/* Never move a running app's DRM state or turn its backlight off.
		 * Switch after it exits. */
		s->pending_switch = 1;
		return;
	}

	set_backlight(s, s->out == OUT_PANEL);

	if (s->mode == MODE_UI) {
		stop_child(s);
		if (s->out != OUT_NONE && start_ui(s) < 0)
			s->quit = 1;
	} else if (s->mode == MODE_NONE && s->out != OUT_NONE) {
		/* The UI was stopped while the old output disappeared. The new
		 * output is ready: bring the launcher back. */
		if (start_ui(s) < 0)
			s->quit = 1;
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
		rescan_output(s, 1);
}

static void handle_child(struct session *s)
{
	int status;
	pid_t p;

	while ((p = waitpid(-1, &status, WNOHANG)) > 0) {
		if (p != s->child)
			continue;
		enum mode old = s->mode;
		s->child = 0;
		s->mode = MODE_NONE;
		logmsg("cpz-session: %s pid %d exited (status %d)\n",
		       old == MODE_UI ? "UI" : "app", (int)p, status);
		if (s->quit || s->once) {
			if (s->once)
				s->quit = 1;
			continue;
		}
		if (old == MODE_APP) {
			find_output(s);
			if (s->pending_switch) {
				s->pending_switch = 0;
				logmsg("cpz-session: applying deferred output switch\n");
			}
			if (s->out != OUT_NONE && start_ui(s) < 0)
				s->quit = 1;
		} else if (old == MODE_UI) {
			/* Crash or clean exit: restart the launcher. */
			s->restart_at_ms = now_ms() + 200;
		}
	}
}

static int session_loop(struct session *s)
{
	sigset_t mask;
	struct timespec now;
	uint64_t last_poll = 0;

	sigemptyset(&mask);
	sigaddset(&mask, SIGCHLD);
	sigaddset(&mask, SIGTERM);
	sigaddset(&mask, SIGINT);
	sigaddset(&mask, SIGHUP);
	sigprocmask(SIG_BLOCK, &mask, NULL);
	s->sfd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
	if (s->sfd < 0) {
		logmsg("cpz-session: signalfd: %s\n", strerror(errno));
		return 1;
	}

	/* Wait for the first usable output. The panel probes several seconds
	 * after the kernel starts; there is no point in exiting early. Keep
	 * reading signalfd so `systemctl stop` is not delayed by this wait. */
	for (int i = 0; i < 300 && !s->quit; i++) {
		struct pollfd p = { .fd = s->sfd, .events = POLLIN };
		if (poll(&p, 1, 100) > 0 && (p.revents & POLLIN)) {
			struct signalfd_siginfo si;
			while (read(s->sfd, &si, sizeof(si)) == sizeof(si)) {
				if (si.ssi_signo == SIGCHLD)
					handle_child(s);
				else
					s->quit = 1;
			}
		}
		if (s->quit)
			break;
		if (find_output(s) == 0 && s->out != OUT_NONE)
			break;
	}
	if (s->out == OUT_NONE) {
		logmsg("cpz-session: no connected DRM output after 30 s\n");
		return 1;
	}

	if (start_ui(s) < 0)
		return 1;

	while (!s->quit) {
		struct pollfd fds[4];
		int nfds = 0;
		int ctl_i = -1, udev_i = -1, sig_i = -1;

		fds[nfds].fd = s->sfd;
		fds[nfds].events = POLLIN;
		sig_i = nfds++;

		if (s->ctl_fd >= 0) {
			fds[nfds].fd = s->ctl_fd;
			fds[nfds].events = POLLIN;
			ctl_i = nfds++;
		}
		if (s->udev_fd >= 0) {
			fds[nfds].fd = s->udev_fd;
			fds[nfds].events = POLLIN;
			udev_i = nfds++;
		}

		int n = poll(fds, (nfds_t)nfds, 500);
		if (n < 0 && errno != EINTR) {
			logmsg("cpz-session: poll: %s\n", strerror(errno));
			break;
		}

		if (n > 0 && sig_i >= 0 && (fds[sig_i].revents & POLLIN)) {
			struct signalfd_siginfo si;
			while (read(s->sfd, &si, sizeof(si)) == sizeof(si)) {
				if (si.ssi_signo == SIGCHLD)
					handle_child(s);
				else
					s->quit = 1;
			}
		}
		if (n > 0 && ctl_i >= 0 && (fds[ctl_i].revents & POLLIN))
			accept_control(s);
		if (n > 0 && udev_i >= 0 && (fds[udev_i].revents & POLLIN))
			handle_udev(s);

		clock_gettime(CLOCK_MONOTONIC, &now);
		uint64_t ms = (uint64_t)now.tv_sec * 1000 +
			      (uint64_t)now.tv_nsec / 1000000;

		notify_systemd("WATCHDOG=1");

		if (ms - last_poll >= 2000) {
			last_poll = ms;
			/* Cheap sysfs rescan. It does not call
			 * drmModeGetConnector(), so it does not make vc4 re-read
			 * EDID. It covers udev races and systems without a
			 * working udev monitor. */
			if (s->mode != MODE_APP)
				rescan_output(s, 2);
			if (s->mode == MODE_UI && s->child > 0 &&
			    ui_heartbeat_stale()) {
				logmsg("cpz-session: UI heartbeat lost; restarting launcher\n");
				stop_child(s);
				touch_ui_heartbeat();
				if (start_ui(s) < 0)
					s->quit = 1;
			}
			/* Recover if the UI was stopped while no output existed and
			 * the udev event that brought it back was missed. */
			if (s->child == 0 && s->mode == MODE_NONE &&
			    !s->restart_at_ms) {
				find_output(s);
				if (s->out != OUT_NONE && start_ui(s) < 0)
					s->quit = 1;
			}
		}

		if (s->child == 0 && s->mode == MODE_NONE && !s->quit) {
			if (s->restart_at_ms && ms >= s->restart_at_ms) {
				s->restart_at_ms = 0;
				find_output(s);
				if (s->out != OUT_NONE && start_ui(s) < 0)
					s->quit = 1;
			}
		}
	}

	stop_child(s);
	return 0;
}

static void usage(FILE *out)
{
	fputs("usage: cpz-session [--ui PATH] [--socket PATH] [--backlight PATH]\n"
	      "                   [--output auto|panel|hdmi] [--probe] [--once]\n"
	      "                   [--debug] [--version]\n", out);
}

int main(int argc, char **argv)
{
	struct session s;
	int i;
	int do_probe = 0;

	memset(&s, 0, sizeof(s));
	snprintf(s.ui, sizeof(s.ui), "%s", DEFAULT_UI);
	snprintf(s.socket_path, sizeof(s.socket_path), "%s", DEFAULT_SOCKET);
	snprintf(s.backlight, sizeof(s.backlight), "%s", DEFAULT_BACKLIGHT);
	snprintf(s.drm_root, sizeof(s.drm_root), "%s",
		 getenv("CPZ_DRM_ROOT") && *getenv("CPZ_DRM_ROOT") ?
		 getenv("CPZ_DRM_ROOT") : "/sys/class/drm");
	s.ctl_fd = -1;
	s.sfd = -1;
	s.udev_fd = -1;
	s.card_index = -1;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--ui") && i + 1 < argc) {
			snprintf(s.ui, sizeof(s.ui), "%s", argv[++i]);
		} else if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
			snprintf(s.socket_path, sizeof(s.socket_path), "%s", argv[++i]);
		} else if (!strcmp(argv[i], "--backlight") && i + 1 < argc) {
			snprintf(s.backlight, sizeof(s.backlight), "%s", argv[++i]);
		} else if (!strcmp(argv[i], "--output") && i + 1 < argc) {
			const char *o = argv[++i];
			if (!strcmp(o, "panel"))
				s.force = 1;
			else if (!strcmp(o, "hdmi"))
				s.force = 2;
			else
				s.force = 0;
		} else if (!strcmp(argv[i], "--once")) {
			s.once = 1;
		} else if (!strcmp(argv[i], "--probe")) {
			do_probe = 1;
		} else if (!strcmp(argv[i], "--debug")) {
			s.debug = 1;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(stdout);
			return 0;
		} else if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-V")) {
			printf("cpz-session 0.4.0\n");
			return 0;
		} else {
			logmsg("cpz-session: unknown argument '%s'\n", argv[i]);
			usage(stderr);
			return 2;
		}
	}

	if (do_probe) {
		if (find_output(&s) == 0 && s.out != OUT_NONE) {
			printf("output=%s card=%s index=%d connector=%s\n",
			       output_name(s.out), s.card, s.card_index,
			       s.output_name);
			return 0;
		}
		printf("output=none\n");
		return 1;
	}

	if (access(s.ui, X_OK) != 0) {
		logmsg("cpz-session: UI not found or not executable: %s\n", s.ui);
		return 1;
	}

	s.ctl_fd = open_control(&s);
	if (s.ctl_fd < 0)
		logmsg("cpz-session: control socket disabled: %s\n", strerror(errno));

	setup_udev(&s);

	logmsg("cpz-session: starting (ui %s, socket %s)\n",
	       s.ui, s.socket_path);
	int ret = session_loop(&s);

	if (s.ctl_fd >= 0) {
		close(s.ctl_fd);
		unlink(s.socket_path);
	}
	if (s.udev_mon)
		udev_monitor_unref(s.udev_mon);
	if (s.udev)
		udev_unref(s.udev);
	if (s.sfd >= 0)
		close(s.sfd);
	return ret;
}
