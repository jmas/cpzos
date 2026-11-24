/*
 * cpz-shell — UI registry, provider broker and tmux panel updater.
 *
 * Protocol: one line per message, key=value pairs separated by '&', values
 * percent-encoded. No JSON. The shell also writes /run/cpz/ui.state for the
 * launcher; the launcher never talks to the socket.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-shell.c -o cpz-shell
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "cpz-query.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/inotify.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define DEFAULT_SOCKET "/run/cpz/ui.sock"
#define STATE_PATH "/run/cpz/ui.state"
#define MAX_APPS 128
#define MAX_WIDGETS 128
#define MAX_CLIENTS 32
#define MAX_NOTIFICATIONS 16
#define MAX_ARGS 8
#define MAX_LINE 65536

struct app {
	char id[64];
	char name[128];
	char desc[256];
	char category[64];
	char icon[64];
	char type[16];
	char exec[MAX_ARGS][PATH_MAX];
	int argc;
	int order;
	int single;
	int hidden;
	int provider;
};

struct widget {
	char app[64];
	char id[64];
	char kind[32];
	char text[96];
	int level;
	int charging;
	int order;
	int priority;
	int valid;
};

struct notification {
	char text[256];
	int level;
};

struct client {
	int fd;
	int provider;
	char app[64];
	char buf[MAX_LINE];
	size_t len;
};

struct shell {
	char socket_path[PATH_MAX];
	char system_apps[PATH_MAX];
	char user_apps[PATH_MAX];
	char state_path[PATH_MAX];
	struct app apps[MAX_APPS];
	int napps;
	struct widget widgets[MAX_WIDGETS];
	int nwidgets;
	struct notification notifications[MAX_NOTIFICATIONS];
	int nnotifications;
	struct client clients[MAX_CLIENTS];
	int nclients;
	int listen_fd;
	int inotify_fd;
	int watch_system, watch_user;
	char status_right[512];
	volatile sig_atomic_t quit;
	int debug;
};

static void logmsg(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

static void on_signal(int sig)
{
	(void)sig;
	/* The shell's quit flag is set through a global because signal handlers
	 * cannot receive the shell pointer safely. */
	extern volatile sig_atomic_t cpz_shell_stop;
	cpz_shell_stop = 1;
}
volatile sig_atomic_t cpz_shell_stop;

static void copy_str(char *dst, size_t len, const char *src)
{
	snprintf(dst, len, "%s", src ? src : "");
}

static int parse_manifest(const char *path, struct app *a)
{
	FILE *f = fopen(path, "r");
	char line[1024];

	if (!f)
		return -1;
	memset(a, 0, sizeof(*a));
	while (fgets(line, sizeof(line), f)) {
		line_trim(line);
		if (!line[0] || line[0] == '#')
			continue;
		char *eq = strchr(line, '=');
		if (!eq)
			continue;
		*eq = '\0';
		const char *key = line;
		const char *val = eq + 1;
		if (!strcmp(key, "id"))
			copy_str(a->id, sizeof(a->id), val);
		else if (!strcmp(key, "name"))
			copy_str(a->name, sizeof(a->name), val);
		else if (!strcmp(key, "desc"))
			copy_str(a->desc, sizeof(a->desc), val);
		else if (!strcmp(key, "category"))
			copy_str(a->category, sizeof(a->category), val);
		else if (!strcmp(key, "icon"))
			copy_str(a->icon, sizeof(a->icon), val);
		else if (!strcmp(key, "type"))
			copy_str(a->type, sizeof(a->type), val);
		else if (!strcmp(key, "order"))
			a->order = atoi(val);
		else if (!strcmp(key, "single"))
			a->single = atoi(val) != 0;
		else if (!strcmp(key, "hidden"))
			a->hidden = atoi(val) != 0;
		else if (!strcmp(key, "provider"))
			a->provider = atoi(val) != 0;
		else if (!strcmp(key, "exec") && a->argc < MAX_ARGS)
			copy_str(a->exec[a->argc++], sizeof(a->exec[0]), val);
	}
	fclose(f);
	if (!a->type[0])
		copy_str(a->type, sizeof(a->type), "tui");
	if (!a->order)
		a->order = 500;
	if (!a->name[0])
		copy_str(a->name, sizeof(a->name), a->id);
	return a->id[0] && a->argc ? 0 : -1;
}

static int app_cmp(const void *pa, const void *pb)
{
	const struct app *a = pa;
	const struct app *b = pb;
	int c = strcasecmp(a->category, b->category);
	if (c)
		return c;
	if (a->order != b->order)
		return a->order - b->order;
	return strcasecmp(a->name, b->name);
}

static void scan_dir(struct shell *s, const char *dir)
{
	glob_t g;
	char pattern[PATH_MAX];

	snprintf(pattern, sizeof(pattern), "%s/*.app", dir);
	if (glob(pattern, 0, NULL, &g) != 0)
		return;
	for (size_t i = 0; i < g.gl_pathc && s->napps < MAX_APPS; i++) {
		struct app a;
		if (parse_manifest(g.gl_pathv[i], &a) == 0)
			s->apps[s->napps++] = a;
	}
	globfree(&g);
}

static void scan_apps(struct shell *s)
{
	s->napps = 0;
	scan_dir(s, s->system_apps);
	scan_dir(s, s->user_apps);
	qsort(s->apps, (size_t)s->napps, sizeof(s->apps[0]), app_cmp);
}

static void add_kv(char *buf, size_t len, const char *key, const char *value)
{
	char enc[1024];
	url_encode(value ? value : "", enc, sizeof(enc));
	size_t used = strlen(buf);
	if (used && buf[used - 1] != ' ')
		strncat(buf, " ", len - used - 1);
	strncat(buf, key, len - strlen(buf) - 1);
	strncat(buf, "=", len - strlen(buf) - 1);
	strncat(buf, enc, len - strlen(buf) - 1);
}

static void write_state(struct shell *s)
{
	char tmp[PATH_MAX];
	FILE *f;
	char line[4096];

	mkdir("/run/cpz", 0755);
	snprintf(tmp, sizeof(tmp), "%s.tmp", s->state_path);
	f = fopen(tmp, "w");
	if (!f)
		return;
	fputs("# cpz ui state\n", f);
	for (int i = 0; i < s->napps; i++) {
		struct app *a = &s->apps[i];
		if (a->hidden)
			continue;
		line[0] = '\0';
		strncat(line, "app ", sizeof(line) - 1);
		add_kv(line, sizeof(line), "id", a->id);
		add_kv(line, sizeof(line), "name", a->name);
		add_kv(line, sizeof(line), "desc", a->desc);
		add_kv(line, sizeof(line), "type", a->type);
		add_kv(line, sizeof(line), "icon", a->icon);
		add_kv(line, sizeof(line), "category", a->category);
		char num[16];
		snprintf(num, sizeof(num), "%d", a->order);
		add_kv(line, sizeof(line), "order", num);
		snprintf(num, sizeof(num), "%d", a->single);
		add_kv(line, sizeof(line), "single", num);
		for (int k = 0; k < a->argc; k++)
			add_kv(line, sizeof(line), "exec", a->exec[k]);
		fprintf(f, "%s\n", line);
	}
	for (int i = 0; i < s->nwidgets; i++) {
		struct widget *w = &s->widgets[i];
		if (!w->valid)
			continue;
		line[0] = '\0';
		strncat(line, "status ", sizeof(line) - 1);
		add_kv(line, sizeof(line), "app", w->app);
		add_kv(line, sizeof(line), "id", w->id);
		add_kv(line, sizeof(line), "kind", w->kind);
		add_kv(line, sizeof(line), "text", w->text);
		char num[16];
		snprintf(num, sizeof(num), "%d", w->level);
		add_kv(line, sizeof(line), "level", num);
		snprintf(num, sizeof(num), "%d", w->charging);
		add_kv(line, sizeof(line), "charging", num);
		snprintf(num, sizeof(num), "%d", w->order);
		add_kv(line, sizeof(line), "order", num);
		snprintf(num, sizeof(num), "%d", w->priority);
		add_kv(line, sizeof(line), "priority", num);
		fprintf(f, "%s\n", line);
	}
	for (int i = 0; i < s->nnotifications; i++) {
		line[0] = '\0';
		strncat(line, "notify ", sizeof(line) - 1);
		char num[16];
		snprintf(num, sizeof(num), "%d", s->notifications[i].level);
		add_kv(line, sizeof(line), "level", num);
		add_kv(line, sizeof(line), "text", s->notifications[i].text);
		fprintf(f, "%s\n", line);
	}
	fputs("end\n", f);
	fclose(f);
	rename(tmp, s->state_path);
}

static void run_tmux(char *const argv[])
{
	pid_t pid = fork();
	if (pid == 0) {
		execv("/usr/bin/tmux", argv);
		_exit(127);
	}
	if (pid > 0)
		while (waitpid(pid, NULL, 0) < 0 && errno == EINTR)
			;
}

static int widget_cmp(const void *pa, const void *pb)
{
	const struct widget *a = pa;
	const struct widget *b = pb;
	if (a->priority != b->priority)
		return b->priority - a->priority;
	if (a->order != b->order)
		return a->order - b->order;
	return strcmp(a->id, b->id);
}

static void build_status_right(struct shell *s, char *out, size_t len)
{
	struct widget *sorted[MAX_WIDGETS];
	int n = 0;
	size_t used = 0;

	for (int i = 0; i < s->nwidgets; i++)
		if (s->widgets[i].valid)
			sorted[n++] = &s->widgets[i];
	qsort(sorted, (size_t)n, sizeof(sorted[0]), widget_cmp);
	out[0] = '\0';
	for (int i = 0; i < n && used + 2 < len; i++) {
		char piece[160];
		struct widget *w = sorted[i];
		if (!strcmp(w->kind, "battery")) {
			snprintf(piece, sizeof(piece), "%s%d%%%s",
				 w->charging ? "+" : "", w->level,
				 i + 1 < n ? "  " : "");
		} else if (!strcmp(w->kind, "text")) {
			snprintf(piece, sizeof(piece), "%s%s", w->text,
				 i + 1 < n ? "  " : "");
		} else {
			continue;
		}
		size_t add = strlen(piece);
		if (used + add >= len)
			break;
		memcpy(out + used, piece, add + 1);
		used += add;
	}
}

static void update_panel(struct shell *s)
{
	char status[512];

	build_status_right(s, status, sizeof(status));
	if (!strcmp(status, s->status_right))
		return;
	snprintf(s->status_right, sizeof(s->status_right), "%s", status);
	char *argv[8] = { "tmux", "-L", "cpz", "set-option", "-g",
			  "status-right", status, NULL };
	run_tmux(argv);
}

static void refresh(struct shell *s)
{
	write_state(s);
	update_panel(s);
}

static struct widget *find_widget(struct shell *s, const char *app,
				  const char *id)
{
	for (int i = 0; i < s->nwidgets; i++)
		if (!strcmp(s->widgets[i].app, app) &&
		    !strcmp(s->widgets[i].id, id))
			return &s->widgets[i];
	return NULL;
}

static void remove_app_widgets(struct shell *s, const char *app)
{
	for (int i = 0; i < s->nwidgets; i++)
		if (!strcmp(s->widgets[i].app, app))
			s->widgets[i].valid = 0;
}

static void add_notification(struct shell *s, const char *text, int level)
{
	if (!text || !*text)
		return;
	if (s->nnotifications >= MAX_NOTIFICATIONS) {
		memmove(&s->notifications[0], &s->notifications[1],
			sizeof(s->notifications[0]) * (MAX_NOTIFICATIONS - 1));
		s->nnotifications = MAX_NOTIFICATIONS - 1;
	}
	copy_str(s->notifications[s->nnotifications].text,
		 sizeof(s->notifications[s->nnotifications].text), text);
	s->notifications[s->nnotifications].level = level;
	s->nnotifications++;
}

static void handle_line(struct shell *s, struct client *c, char *line)
{
	char op[32] = "";
	char app[64] = "";
	char id[64] = "";
	char kind[32] = "";
	char text[256] = "";

	if (kv_get(line, "op", op, sizeof(op)) < 0)
		return;
	if (!strcmp(op, "hello")) {
		c->provider = 1;
		kv_get(line, "app", c->app, sizeof(c->app));
	} else if (!strcmp(op, "clear") && c->provider) {
		kv_get(line, "app", app, sizeof(app));
		remove_app_widgets(s, app[0] ? app : c->app);
		refresh(s);
	} else if (!strcmp(op, "widget") && c->provider) {
		kv_get(line, "app", app, sizeof(app));
		if (!app[0])
			copy_str(app, sizeof(app), c->app);
		kv_get(line, "id", id, sizeof(id));
		if (!id[0])
			return;
		struct widget *w = find_widget(s, app, id);
		int created = 0;
		if (!w) {
			if (s->nwidgets >= MAX_WIDGETS)
				return;
			w = &s->widgets[s->nwidgets++];
			memset(w, 0, sizeof(*w));
			copy_str(w->app, sizeof(w->app), app);
			copy_str(w->id, sizeof(w->id), id);
			created = 1;
		}
		kv_get(line, "kind", kind, sizeof(kind));
		kv_get(line, "text", text, sizeof(text));
		if (kind[0])
			copy_str(w->kind, sizeof(w->kind), kind);
		if (text[0] || !created)
			copy_str(w->text, sizeof(w->text), text);
		w->level = kv_int(line, "level", w->level);
		w->charging = kv_bool(line, "charging", w->charging);
		w->order = kv_int(line, "order", w->order ? w->order : 500);
		w->priority = kv_int(line, "priority", w->priority ? w->priority : 50);
		w->valid = 1;
		refresh(s);
	} else if (!strcmp(op, "notify")) {
		kv_get(line, "text", text, sizeof(text));
		add_notification(s, text, kv_int(line, "level", 0));
		refresh(s);
	} else if (!strcmp(op, "bye")) {
		remove_app_widgets(s, c->app);
		refresh(s);
	}
}

static void client_remove(struct shell *s, int idx)
{
	struct client *c = &s->clients[idx];
	if (c->provider && c->app[0])
		remove_app_widgets(s, c->app);
	if (c->fd >= 0)
		close(c->fd);
	s->clients[idx] = s->clients[--s->nclients];
	refresh(s);
}

static void client_read(struct shell *s, int idx)
{
	struct client *c = &s->clients[idx];
	ssize_t n = read(c->fd, c->buf + c->len,
			 sizeof(c->buf) - c->len - 1);
	if (n <= 0) {
		client_remove(s, idx);
		return;
	}
	c->len += (size_t)n;
	c->buf[c->len] = '\0';
	for (;;) {
		char *nl = strchr(c->buf, '\n');
		if (!nl)
			break;
		*nl = '\0';
		if (c->buf[0])
			handle_line(s, c, c->buf);
		size_t used = (size_t)(nl - c->buf) + 1;
		memmove(c->buf, c->buf + used, c->len - used + 1);
		c->len -= used;
	}
	if (c->len + 1 >= sizeof(c->buf))
		c->len = 0;
}

static int open_socket(struct shell *s)
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
	return fd;
}

static void accept_client(struct shell *s)
{
	for (;;) {
		int fd = accept4(s->listen_fd, NULL, NULL,
				 SOCK_NONBLOCK | SOCK_CLOEXEC);
		if (fd < 0)
			return;
		if (s->nclients >= MAX_CLIENTS) {
			close(fd);
			continue;
		}
		struct client *c = &s->clients[s->nclients++];
		memset(c, 0, sizeof(*c));
		c->fd = fd;
	}
}

static void setup_inotify(struct shell *s)
{
	s->inotify_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	if (s->inotify_fd < 0)
		return;
	s->watch_system = inotify_add_watch(s->inotify_fd, s->system_apps,
					   IN_CREATE | IN_DELETE |
					   IN_MOVED_TO | IN_MOVED_FROM |
					   IN_CLOSE_WRITE);
	s->watch_user = inotify_add_watch(s->inotify_fd, s->user_apps,
					  IN_CREATE | IN_DELETE |
					  IN_MOVED_TO | IN_MOVED_FROM |
					  IN_CLOSE_WRITE);
}

static void handle_inotify(struct shell *s)
{
	char buf[4096];
	(void)read(s->inotify_fd, buf, sizeof(buf));
	scan_apps(s);
	refresh(s);
}

static void usage(FILE *out)
{
	fputs("usage: cpz-shell [--socket PATH] [--apps DIR] "
	      "[--user-apps DIR] [--dump] [--selftest]\n", out);
}

int main(int argc, char **argv)
{
	struct shell s;
	int dump = 0;
	int selftest = 0;

	memset(&s, 0, sizeof(s));
	snprintf(s.socket_path, sizeof(s.socket_path), "%s", DEFAULT_SOCKET);
	snprintf(s.state_path, sizeof(s.state_path), "%s", STATE_PATH);
	snprintf(s.system_apps, sizeof(s.system_apps), "%s",
		 "/usr/share/cpz/apps");
	const char *home = getenv("HOME");
	snprintf(s.user_apps, sizeof(s.user_apps), "%s/.local/share/cpz/apps",
		 home ? home : "/home/cpz");
	s.listen_fd = -1;
	s.inotify_fd = -1;
	signal(SIGPIPE, SIG_IGN);

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--socket") && i + 1 < argc)
			snprintf(s.socket_path, sizeof(s.socket_path), "%s", argv[++i]);
		else if (!strcmp(argv[i], "--apps") && i + 1 < argc)
			snprintf(s.system_apps, sizeof(s.system_apps), "%s", argv[++i]);
		else if (!strcmp(argv[i], "--user-apps") && i + 1 < argc)
			snprintf(s.user_apps, sizeof(s.user_apps), "%s", argv[++i]);
		else if (!strcmp(argv[i], "--dump"))
			dump = 1;
		else if (!strcmp(argv[i], "--selftest"))
			selftest = 1;
		else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(stdout);
			return 0;
		} else {
			usage(stderr);
			return 2;
		}
	}

	scan_apps(&s);
	if (dump || selftest) {
		if (selftest) {
			printf("cpz-shell selftest: ok (%d apps)\n", s.napps);
		} else {
			write_state(&s);
			FILE *f = fopen(s.state_path, "r");
			if (f) {
				char buf[1024];
				while (fgets(buf, sizeof(buf), f))
					fputs(buf, stdout);
				fclose(f);
			}
		}
		return 0;
	}

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	s.listen_fd = open_socket(&s);
	if (s.listen_fd < 0) {
		logmsg("cpz-shell: socket: %s\n", strerror(errno));
		return 1;
	}
	setup_inotify(&s);
	refresh(&s);

	while (!cpz_shell_stop) {
		struct pollfd pfd[2 + MAX_CLIENTS];
		int nfds = 0;
		int listen_idx = -1, inotify_idx = -1, client_start;

		pfd[nfds].fd = s.listen_fd;
		pfd[nfds].events = POLLIN;
		listen_idx = nfds++;
		if (s.inotify_fd >= 0) {
			pfd[nfds].fd = s.inotify_fd;
			pfd[nfds].events = POLLIN;
			inotify_idx = nfds++;
		}
		client_start = nfds;
		for (int i = 0; i < s.nclients; i++) {
			pfd[nfds].fd = s.clients[i].fd;
			pfd[nfds].events = POLLIN;
			nfds++;
		}
		int r = poll(pfd, (nfds_t)nfds, 1000);
		if (r < 0 && errno == EINTR)
			continue;
		if (r < 0)
			break;
		if (listen_idx >= 0 && (pfd[listen_idx].revents & POLLIN))
			accept_client(&s);
		if (inotify_idx >= 0 && (pfd[inotify_idx].revents & POLLIN))
			handle_inotify(&s);
		for (int i = s.nclients - 1; i >= 0; i--) {
			if (pfd[client_start + i].revents & (POLLIN | POLLHUP))
				client_read(&s, i);
		}
	}

	for (int i = s.nclients - 1; i >= 0; i--)
		client_remove(&s, i);
	if (s.listen_fd >= 0)
		close(s.listen_fd);
	if (s.inotify_fd >= 0)
		close(s.inotify_fd);
	unlink(s.socket_path);
	return 0;
}
