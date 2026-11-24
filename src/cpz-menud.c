/*
 * cpz-menud — the Cardputer Zero menu and status model daemon.
 *
 * One atomic model: root-owned static manifests under /usr/share/cpz/apps plus
 * live runtime registrations from provider apps. The UI subscribes and gets a
 * snapshot; it never reads manifests itself. The daemon owns ordering,
 * validation, TTL/liveness, icon caching and the generation counter.
 *
 * Protocol: NDJSON over /run/cpz/menu.sock, v1, one message per line, at most
 * 64 KiB per message. See docs/MENU-RFC.md.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-menud.c cpz-json.c -o cpz-menud
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "cpz-json.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/inotify.h>
#endif

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0
#endif

#define MENUD_VERSION "0.1.0"
#define DEFAULT_SOCKET "/run/cpz/menu.sock"
#define DEFAULT_APPS "/usr/share/cpz/apps"
#define DEFAULT_RUN "/run/cpz/menu"
#define DEFAULT_ETC "/etc/cpz/menu"
#define MAX_MSG 65536
#define MAX_APPS 64
#define MAX_CLIENTS 32
#define MAX_ITEMS_PER_APP 64
#define MAX_TOTAL_ITEMS 512
#define MAX_ICONS 256
#define MAX_LABEL 80
#define MAX_DETAIL 160
#define MAX_BADGE 4
#define MAX_STATUS_TEXT 8
#define MAX_ID 96
#define MAX_APP 64
#define MAX_ARGV 32
#define MAX_CHOICES 8
#define NOTIFY_MS 250
#define DEFAULT_TTL_MS 10000
#define MAX_DEPTH 4

enum action_kind {
	ACT_NONE = 0,
	ACT_EXEC,
	ACT_RUN,
	ACT_INFO,
	ACT_CHOICE,
};

struct choice {
	char *label;
	char *detail;
	char *icon;
	int kind;		/* ACT_EXEC or ACT_RUN */
	char **argv;
	int argc;
};

struct action {
	int kind;
	char **argv;
	int argc;
	char *info_title;
	char *info_text;
	char *info_icon;
	char *info_severity;
	char *busy;
	struct choice *choices;
	int nchoices;
};

struct menu_item {
	char *id;
	char *label;
	char *detail;
	char *parent;
	char *icon;		/* builtin:name, png:<hash>, or raw hash */
	char *badge;
	char *confirm;
	int order;
	int enabled;
	int visible;
	unsigned has_label:1, has_detail:1, has_parent:1, has_icon:1;
	unsigned has_badge:1, has_order:1, has_enabled:1, has_visible:1;
	unsigned has_confirm:1;
	struct action act;
};

struct widget {
	char *id;
	char *kind;		/* battery, clock, glyph, png, text */
	char *text;
	char *name;
	char *hash;
	int level;
	int charging;
	int order;
	int priority;
	int system;
	unsigned has_id:1, has_kind:1, has_text:1, has_name:1, has_hash:1;
	unsigned has_level:1, has_charging:1, has_order:1, has_priority:1;
	unsigned has_system:1;
};

struct manifest {
	char *app;
	struct menu_item *items;
	int nitems;
};

struct registration {
	int used;
	char *app;
	struct menu_item *items;
	int nitems;
	struct widget *status;
	int nstatus;
	int one_shot;
	uint64_t ttl_ms;
	uint64_t expires;
};

struct icon {
	char hash[17];
	unsigned char *data;
	size_t len;
};

enum role {
	ROLE_NONE = 0,
	ROLE_UI,
	ROLE_PROVIDER,
	ROLE_ADMIN,
};

struct client {
	int fd;
	int role;
	char app[MAX_APP];
	int subscribed;
	int reg;		/* provider registration index, -1 */
	char *buf;
	size_t len;
	size_t cap;
	uint64_t win_start;
	int win_count;
};

struct menud {
	char socket_path[PATH_MAX];
	char apps_dir[PATH_MAX];
	char run_dir[PATH_MAX];
	char etc_dir[PATH_MAX];
	int listen_fd;
	int inotify_fd;
	int debug;
	int insecure;
	struct manifest manifests[MAX_APPS];
	int nmanifests;
	struct registration regs[MAX_APPS];
	struct icon icons[MAX_ICONS];
	int nicons;
	struct client clients[MAX_CLIENTS];
	uint64_t generation;
	int dirty;
	uint64_t notify_at;
	uint64_t reload_at;
	uint64_t bad_log_gen;
	int selftest;
	volatile sig_atomic_t stop;
	volatile sig_atomic_t reload;
};

static struct menud g;

static void logmsg(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	fputs("cpz-menud: ", stderr);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

static uint64_t now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static void *xcalloc(size_t n, size_t sz)
{
	void *p;

	if (n == 0)
		n = 1;
	p = calloc(n, sz);

	if (!p) {
		fputs("cpz-menud: out of memory\n", stderr);
		abort();
	}
	return p;
}

static char *xstrdup(const char *s)
{
	size_t n;
	char *p;

	if (!s)
		return NULL;
	n = strlen(s) + 1;
	p = xcalloc(n, 1);
	memcpy(p, s, n);
	return p;
}

static void set_str(char **dst, const char *src)
{
	free(*dst);
	*dst = xstrdup(src);
}

static int set_str_checked(char **dst, const char *src, size_t max,
			   const char *what, char *err, size_t errlen)
{
	if (!src)
		return 0;
	if (strlen(src) > max) {
		snprintf(err, errlen, "%s is too long (max %zu bytes)", what, max);
		return -1;
	}
	set_str(dst, src);
	return 0;
}

static void action_free(struct action *a)
{
	for (int i = 0; i < a->argc; i++)
		free(a->argv[i]);
	free(a->argv);
	free(a->info_title);
	free(a->info_text);
	free(a->info_icon);
	free(a->info_severity);
	free(a->busy);
	for (int i = 0; i < a->nchoices; i++) {
		free(a->choices[i].label);
		free(a->choices[i].detail);
		free(a->choices[i].icon);
		for (int k = 0; k < a->choices[i].argc; k++)
			free(a->choices[i].argv[k]);
		free(a->choices[i].argv);
	}
	free(a->choices);
	memset(a, 0, sizeof(*a));
}

static void item_free(struct menu_item *it)
{
	free(it->id);
	free(it->label);
	free(it->detail);
	free(it->parent);
	free(it->icon);
	free(it->badge);
	free(it->confirm);
	action_free(&it->act);
	memset(it, 0, sizeof(*it));
}

static void widget_free(struct widget *w)
{
	free(w->id);
	free(w->kind);
	free(w->text);
	free(w->name);
	free(w->hash);
	memset(w, 0, sizeof(*w));
}

static void action_copy(struct action *dst, const struct action *src)
{
	memset(dst, 0, sizeof(*dst));
	dst->kind = src->kind;
	dst->argc = src->argc;
	if (src->argc > 0) {
		dst->argv = xcalloc((size_t)src->argc, sizeof(char *));
		for (int i = 0; i < src->argc; i++)
			dst->argv[i] = xstrdup(src->argv[i]);
	}
	dst->info_title = xstrdup(src->info_title);
	dst->info_text = xstrdup(src->info_text);
	dst->info_icon = xstrdup(src->info_icon);
	dst->info_severity = xstrdup(src->info_severity);
	dst->busy = xstrdup(src->busy);
	dst->nchoices = src->nchoices;
	if (src->nchoices > 0) {
		dst->choices = xcalloc((size_t)src->nchoices,
				       sizeof(struct choice));
		for (int i = 0; i < src->nchoices; i++) {
			struct choice *c = &dst->choices[i];
			const struct choice *s = &src->choices[i];

			c->label = xstrdup(s->label);
			c->detail = xstrdup(s->detail);
			c->icon = xstrdup(s->icon);
			c->kind = s->kind;
			c->argc = s->argc;
			if (s->argc > 0) {
				c->argv = xcalloc((size_t)s->argc,
						  sizeof(char *));
				for (int k = 0; k < s->argc; k++)
					c->argv[k] = xstrdup(s->argv[k]);
			}
		}
	}
}

static void item_copy(struct menu_item *dst, const struct menu_item *src)
{
	memset(dst, 0, sizeof(*dst));
	dst->id = xstrdup(src->id);
	dst->label = xstrdup(src->label);
	dst->detail = xstrdup(src->detail);
	dst->parent = xstrdup(src->parent);
	dst->icon = xstrdup(src->icon);
	dst->badge = xstrdup(src->badge);
	dst->confirm = xstrdup(src->confirm);
	dst->order = src->order;
	dst->enabled = src->enabled;
	dst->visible = src->visible;
	dst->has_label = src->has_label;
	dst->has_detail = src->has_detail;
	dst->has_parent = src->has_parent;
	dst->has_icon = src->has_icon;
	dst->has_badge = src->has_badge;
	dst->has_order = src->has_order;
	dst->has_enabled = src->has_enabled;
	dst->has_visible = src->has_visible;
	dst->has_confirm = src->has_confirm;
	action_copy(&dst->act, &src->act);
}

static void item_apply(struct menu_item *dst, const struct menu_item *ov)
{
	if (ov->has_label)
		set_str(&dst->label, ov->label);
	if (ov->has_detail)
		set_str(&dst->detail, ov->detail);
	if (ov->has_parent) {
		set_str(&dst->parent, ov->parent);
		dst->has_parent = 1;
	}
	if (ov->has_icon)
		set_str(&dst->icon, ov->icon);
	if (ov->has_badge)
		set_str(&dst->badge, ov->badge);
	if (ov->has_confirm)
		set_str(&dst->confirm, ov->confirm);
	if (ov->has_order)
		dst->order = ov->order;
	if (ov->has_enabled)
		dst->enabled = ov->enabled;
	if (ov->has_visible)
		dst->visible = ov->visible;
	if (ov->act.kind != ACT_NONE) {
		action_free(&dst->act);
		action_copy(&dst->act, &ov->act);
	}
}

static void widget_copy(struct widget *dst, const struct widget *src)
{
	memset(dst, 0, sizeof(*dst));
	dst->id = xstrdup(src->id);
	dst->kind = xstrdup(src->kind);
	dst->text = xstrdup(src->text);
	dst->name = xstrdup(src->name);
	dst->hash = xstrdup(src->hash);
	dst->level = src->level;
	dst->charging = src->charging;
	dst->order = src->order;
	dst->priority = src->priority;
	dst->system = src->system;
	dst->has_id = src->has_id;
	dst->has_kind = src->has_kind;
	dst->has_text = src->has_text;
	dst->has_name = src->has_name;
	dst->has_hash = src->has_hash;
	dst->has_level = src->has_level;
	dst->has_charging = src->has_charging;
	dst->has_order = src->has_order;
	dst->has_priority = src->has_priority;
	dst->has_system = src->has_system;
}

static void registration_clear(struct registration *r)
{
	if (!r->used)
		return;
	for (int i = 0; i < r->nitems; i++)
		item_free(&r->items[i]);
	free(r->items);
	for (int i = 0; i < r->nstatus; i++)
		widget_free(&r->status[i]);
	free(r->status);
	free(r->app);
	memset(r, 0, sizeof(*r));
}

static void manifest_clear(struct manifest *m)
{
	for (int i = 0; i < m->nitems; i++)
		item_free(&m->items[i]);
	free(m->items);
	free(m->app);
	memset(m, 0, sizeof(*m));
}

static void bump_generation(void)
{
	g.generation++;
	g.dirty = 1;
	if (!g.notify_at)
		g.notify_at = now_ms() + NOTIFY_MS;
}

/* ------------------------------------------------------------------- icons */

static const unsigned char png_sig[8] = {
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a
};

static int png_valid(const unsigned char *p, size_t n, char *err,
		     size_t errlen)
{
	unsigned w, h;
	int depth, color;

	if (n < 33 || memcmp(p, png_sig, 8) != 0) {
		snprintf(err, errlen, "not a PNG");
		return -1;
	}
	if (p[12] != 'I' || p[13] != 'H' || p[14] != 'D' || p[15] != 'R') {
		snprintf(err, errlen, "missing IHDR");
		return -1;
	}
	w = ((unsigned)p[16] << 24) | ((unsigned)p[17] << 16) |
	    ((unsigned)p[18] << 8) | p[19];
	h = ((unsigned)p[20] << 24) | ((unsigned)p[21] << 16) |
	    ((unsigned)p[22] << 8) | p[23];
	depth = p[24];
	color = p[25];
	if (w != h || w < 12 || w > 96) {
		snprintf(err, errlen, "PNG must be square 12..96 px");
		return -1;
	}
	if (depth != 8 || color != 6) {
		snprintf(err, errlen, "PNG must be 8-bit RGBA");
		return -1;
	}
	return 0;
}

static void hash_bytes(const unsigned char *p, size_t n, char out[17])
{
	uint64_t h = 1469598103934665603ULL;

	for (size_t i = 0; i < n; i++) {
		h ^= p[i];
		h *= 1099511628211ULL;
	}
	snprintf(out, 17, "%016llx", (unsigned long long)h);
}

static const char *icon_add(const unsigned char *data, size_t len)
{
	char hash[17];

	hash_bytes(data, len, hash);
	for (int i = 0; i < g.nicons; i++)
		if (!strcmp(g.icons[i].hash, hash))
			return g.icons[i].hash;
	if (g.nicons >= MAX_ICONS) {
		logmsg("icon cache full, dropping %s\n", hash);
		return NULL;
	}
	struct icon *ic = &g.icons[g.nicons++];

	snprintf(ic->hash, sizeof(ic->hash), "%s", hash);
	ic->data = xcalloc(len, 1);
	memcpy(ic->data, data, len);
	ic->len = len;
	return ic->hash;
}

static const struct icon *icon_find(const char *hash)
{
	for (int i = 0; i < g.nicons; i++)
		if (!strcmp(g.icons[i].hash, hash))
			return &g.icons[i];
	return NULL;
}

/*
 * Resolve an icon field. Icons belong to the app that owns the menu item:
 * a relative path is looked up inside /usr/share/cpz/apps/<app>/, validated
 * and copied into the daemon cache, and the snapshot only carries the hash.
 * `builtin:` stays for shell-owned status glyphs and severity marks.
 * `..` and absolute paths are rejected.
 */
static int resolve_icon(const char *app, char **icon, char *err, size_t errlen)
{
	char path[PATH_MAX + 512];
	const char *rel;
	struct stat st;
	unsigned char *data;
	FILE *f;
	size_t len;
	const char *hash;

	if (!*icon)
		return 0;
	if (!strncmp(*icon, "builtin:", 8))
		return 0;
	if (!strncmp(*icon, "png:", 4)) {
		if (strlen(*icon + 4) != 16) {
			snprintf(err, errlen, "bad icon hash");
			return -1;
		}
		return 0;
	}
	if (!strncmp(*icon, "hash:", 5)) {
		char tmp[32];

		if (strlen(*icon + 5) != 16) {
			snprintf(err, errlen, "bad icon hash");
			return -1;
		}
		snprintf(tmp, sizeof(tmp), "png:%s", *icon + 5);
		set_str(icon, tmp);
		return 0;
	}
	rel = *icon;
	if (rel[0] == '/' || strstr(rel, "..")) {
		snprintf(err, errlen, "icon path escapes the app directory");
		return -1;
	}
	if (strlen(app) + strlen(rel) + strlen(g.apps_dir) + 4 >= sizeof(path)) {
		snprintf(err, errlen, "icon path too long");
		return -1;
	}
	snprintf(path, sizeof(path), "%s/%s/%s", g.apps_dir, app, rel);
	if (stat(path, &st) < 0) {
		snprintf(err, errlen, "icon not found: %s", path);
		return -1;
	}
	if (!S_ISREG(st.st_mode) || st.st_size <= 0 ||
	    st.st_size > 16 * 1024) {
		snprintf(err, errlen, "icon is not a small regular file");
		return -1;
	}
	f = fopen(path, "rb");
	if (!f) {
		snprintf(err, errlen, "cannot open icon");
		return -1;
	}
	data = xcalloc((size_t)st.st_size, 1);
	len = fread(data, 1, (size_t)st.st_size, f);
	fclose(f);
	if (len != (size_t)st.st_size || png_valid(data, len, err, errlen) < 0) {
		free(data);
		return -1;
	}
	hash = icon_add(data, len);
	free(data);
	if (!hash) {
		snprintf(err, errlen, "icon cache full");
		return -1;
	}
	{
		char tmp[32];

		snprintf(tmp, sizeof(tmp), "png:%s", hash);
		set_str(icon, tmp);
	}
	return 0;
}

/* -------------------------------------------------------------- JSON parse */

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

static int parse_argv(const jv *v, char ***argv, int *argc, char *err,
		      size_t errlen)
{
	int n = jv_len(v);

	if (!v || v->type != JV_ARRAY) {
		snprintf(err, errlen, "argv must be an array");
		return -1;
	}
	if (n < 1 || n > MAX_ARGV) {
		snprintf(err, errlen, "argv must have 1..%d entries", MAX_ARGV);
		return -1;
	}
	*argv = xcalloc((size_t)n, sizeof(char *));
	*argc = 0;
	for (int i = 0; i < n; i++) {
		const char *s = jv_str(jv_at(v, i));

		if (!s) {
			snprintf(err, errlen, "argv[%d] is not a string", i);
			return -1;
		}
		if (i == 0 && !command_allowed(s)) {
			snprintf(err, errlen,
				 "argv[0] is not in the command allowlist");
			return -1;
		}
		(*argv)[(*argc)++] = xstrdup(s);
	}
	return 0;
}

static int parse_action(const jv *a, const char *app, struct action *out,
			char *err, size_t errlen)
{
	const jv *v;

	memset(out, 0, sizeof(*out));
	if (!a || a->type != JV_OBJECT)
		return 0;
	{
		const char *busy = jv_str(jv_get(a, "busy"));

		if (busy)
			set_str(&out->busy, busy);
	}

	v = jv_get(a, "exec");
	if (v) {
		out->kind = ACT_EXEC;
		return parse_argv(v, &out->argv, &out->argc, err, errlen);
	}
	v = jv_get(a, "run");
	if (v) {
		out->kind = ACT_RUN;
		return parse_argv(v, &out->argv, &out->argc, err, errlen);
	}
	v = jv_get(a, "info");
	if (v) {
		if (v->type != JV_OBJECT) {
			snprintf(err, errlen, "info must be an object");
			return -1;
		}
		out->kind = ACT_INFO;
		if (set_str_checked(&out->info_title, jv_str(jv_get(v, "title")),
				    MAX_LABEL, "info.title", err, errlen) < 0)
			return -1;
		if (set_str_checked(&out->info_text, jv_str(jv_get(v, "text")),
				    1024, "info.text", err, errlen) < 0)
			return -1;
		if (set_str_checked(&out->info_icon, jv_str(jv_get(v, "icon")),
				    MAX_ID, "info.icon", err, errlen) < 0)
			return -1;
		if (out->info_icon &&
		    resolve_icon(app, &out->info_icon, err, errlen) < 0) {
			logmsg("info.icon: %s; no icon\n", err);
			free(out->info_icon);
			out->info_icon = NULL;
		}
		if (set_str_checked(&out->info_severity,
				    jv_str(jv_get(v, "severity")), 16,
				    "info.severity", err, errlen) < 0)
			return -1;
		if (!out->info_severity)
			out->info_severity = xstrdup("info");
		return 0;
	}
	v = jv_get(a, "choice");
	if (v) {
		int n = jv_len(v);

		if (v->type != JV_ARRAY || n < 1 || n > MAX_CHOICES) {
			snprintf(err, errlen, "choice must be 1..%d options",
				 MAX_CHOICES);
			return -1;
		}
		out->kind = ACT_CHOICE;
		out->choices = xcalloc((size_t)n, sizeof(struct choice));
		for (int i = 0; i < n; i++) {
			const jv *o = jv_at(v, i);
			const jv *label, *ca, *cv;
			struct choice *c = &out->choices[i];

			if (!o || o->type != JV_OBJECT) {
				snprintf(err, errlen, "choice[%d] is not an object",
					 i);
				return -1;
			}
			label = jv_get(o, "label");
			if (!jv_str(label)) {
				snprintf(err, errlen, "choice[%d] has no label", i);
				return -1;
			}
			if (set_str_checked(&c->label, jv_str(label), MAX_LABEL,
					    "choice.label", err, errlen) < 0)
				return -1;
			if (set_str_checked(&c->detail,
					    jv_str(jv_get(o, "detail")),
					    MAX_DETAIL, "choice.detail",
					    err, errlen) < 0)
				return -1;
			if (set_str_checked(&c->icon,
					    jv_str(jv_get(o, "icon")),
					    MAX_ID, "choice.icon", err, errlen) < 0)
				return -1;
			if (c->icon &&
			    resolve_icon(app, &c->icon, err, errlen) < 0) {
				logmsg("choice[%d].icon: %s; no icon\n", i, err);
				free(c->icon);
				c->icon = NULL;
			}
			ca = jv_get(o, "action");
			cv = ca ? (jv_get(ca, "exec") ? jv_get(ca, "exec") :
				   jv_get(ca, "run")) : NULL;
			if (!cv) {
				snprintf(err, errlen,
					 "choice[%d] needs exec or run", i);
				return -1;
			}
			c->kind = jv_get(ca, "exec") ? ACT_EXEC : ACT_RUN;
			if (parse_argv(cv, &c->argv, &c->argc, err, errlen) < 0)
				return -1;
		}
		out->nchoices = n;
		return 0;
	}
	return 0;
}

static int parse_item(const jv *o, const char *app, struct menu_item *it,
		      int partial, char *err, size_t errlen)
{
	const jv *v;
	const char *s;

	memset(it, 0, sizeof(*it));
	if (!o || o->type != JV_OBJECT) {
		snprintf(err, errlen, "menu item must be an object");
		return -1;
	}
	s = jv_str(jv_get(o, "id"));
	if (!s || !*s) {
		snprintf(err, errlen, "menu item has no id");
		return -1;
	}
	if (strlen(s) > MAX_ID) {
		snprintf(err, errlen, "menu id too long");
		return -1;
	}
	set_str(&it->id, s);

	v = jv_get(o, "label");
	if (v) {
		if (!jv_str(v)) {
			snprintf(err, errlen, "label must be a string");
			return -1;
		}
		if (set_str_checked(&it->label, jv_str(v), MAX_LABEL, "label",
				    err, errlen) < 0)
			return -1;
		it->has_label = 1;
	}
	if (!partial) {
		it->label = it->label ? it->label : xstrdup(it->id);
		it->has_label = 1;
	}

	v = jv_get(o, "detail");
	if (v) {
		if (set_str_checked(&it->detail, jv_str(v), MAX_DETAIL,
				    "detail", err, errlen) < 0)
			return -1;
		it->has_detail = 1;
	}
	v = jv_get(o, "parent");
	if (v) {
		const char *p = jv_str(v);

		if (!p || strlen(p) > MAX_ID) {
			snprintf(err, errlen, "bad parent");
			return -1;
		}
		set_str(&it->parent, p);
		it->has_parent = 1;
	}
	v = jv_get(o, "order");
	if (v) {
		if (v->type != JV_NUMBER) {
			snprintf(err, errlen, "order must be a number");
			return -1;
		}
		it->order = (int)jv_num(v, 0);
		it->has_order = 1;
	}
	v = jv_get(o, "enabled");
	if (v) {
		it->enabled = jv_boolean(v, 1);
		it->has_enabled = 1;
	} else {
		it->enabled = 1;
	}
	v = jv_get(o, "visible");
	if (v) {
		it->visible = jv_boolean(v, 1);
		it->has_visible = 1;
	} else {
		it->visible = 1;
	}
	v = jv_get(o, "icon");
	if (v) {
		if (set_str_checked(&it->icon, jv_str(v), MAX_ID, "icon",
				    err, errlen) < 0)
			return -1;
		it->has_icon = 1;
	}
	v = jv_get(o, "badge");
	if (v) {
		if (set_str_checked(&it->badge, jv_str(v), MAX_BADGE, "badge",
				    err, errlen) < 0)
			return -1;
		it->has_badge = 1;
	}
	v = jv_get(o, "confirm");
	if (v) {
		if (set_str_checked(&it->confirm, jv_str(v), MAX_DETAIL,
				    "confirm", err, errlen) < 0)
			return -1;
		it->has_confirm = 1;
	}
	if (it->has_icon && resolve_icon(app, &it->icon, err, errlen) < 0) {
		logmsg("item %s: %s; no icon\n", it->id, err);
		free(it->icon);
		it->icon = NULL;
		it->has_icon = 0;
	}
	if (parse_action(jv_get(o, "action"), app, &it->act, err, errlen) < 0)
		return -1;
	return 0;
}

static int parse_widget(const jv *o, const char *app, struct widget *w,
			char *err, size_t errlen)
{
	const jv *v;
	const char *s;

	memset(w, 0, sizeof(*w));
	if (!o || o->type != JV_OBJECT) {
		snprintf(err, errlen, "status widget must be an object");
		return -1;
	}
	s = jv_str(jv_get(o, "id"));
	if (!s || !*s || strlen(s) > MAX_ID) {
		snprintf(err, errlen, "status widget has no valid id");
		return -1;
	}
	set_str(&w->id, s);
	w->has_id = 1;

	s = jv_str(jv_get(o, "kind"));
	if (!s || (strcmp(s, "battery") && strcmp(s, "clock") &&
		   strcmp(s, "glyph") && strcmp(s, "png") &&
		   strcmp(s, "text"))) {
		snprintf(err, errlen, "bad status kind");
		return -1;
	}
	set_str(&w->kind, s);
	w->has_kind = 1;

	v = jv_get(o, "text");
	if (v) {
		if (set_str_checked(&w->text, jv_str(v), MAX_STATUS_TEXT,
				    "status text", err, errlen) < 0)
			return -1;
		w->has_text = 1;
	}
	v = jv_get(o, "name");
	if (v) {
		if (set_str_checked(&w->name, jv_str(v), 32, "status name",
				    err, errlen) < 0)
			return -1;
		w->has_name = 1;
	}
	v = jv_get(o, "hash");
	if (!v)
		v = jv_get(o, "icon");
	if (v) {
		s = jv_str(v);
		if (!s || strlen(s) != 16) {
			snprintf(err, errlen, "status hash must be 16 hex chars");
			return -1;
		}
		set_str(&w->hash, s);
		w->has_hash = 1;
	}
	v = jv_get(o, "level");
	if (v) {
		w->level = (int)jv_num(v, 0);
		if (w->level < 0)
			w->level = 0;
		if (w->level > 100)
			w->level = 100;
		w->has_level = 1;
	}
	v = jv_get(o, "charging");
	if (v) {
		w->charging = jv_boolean(v, 0);
		w->has_charging = 1;
	}
	v = jv_get(o, "order");
	if (v) {
		w->order = (int)jv_num(v, 0);
		w->has_order = 1;
	}
	v = jv_get(o, "priority");
	if (v) {
		w->priority = (int)jv_num(v, 0);
		w->has_priority = 1;
	}
	v = jv_get(o, "system");
	if (v) {
		w->system = jv_boolean(v, 0);
		w->has_system = 1;
	}
	/* Notices cannot promote themselves to a reserved system slot. */
	if (w->system &&
	    strcmp(app, "battery") && strcmp(app, "clock") &&
	    strcmp(app, "network") && strcmp(app, "bluetooth")) {
		logmsg("app %s cannot set system:true; ignored\n", app);
		w->system = 0;
	}
	if (!strcmp(w->kind, "battery") && !w->has_level)
		w->level = 100;
	return 0;
}

static int parse_menu_array(const jv *arr, const char *app, int partial,
			    struct menu_item **out, int *nout,
			    char *err, size_t errlen)
{
	int n = jv_len(arr);

	*out = NULL;
	*nout = 0;
	if (!arr)
		return 0;
	if (arr->type != JV_ARRAY) {
		snprintf(err, errlen, "menu must be an array");
		return -1;
	}
	if (n > MAX_ITEMS_PER_APP) {
		snprintf(err, errlen, "too many menu items (%d > %d)", n,
			 MAX_ITEMS_PER_APP);
		return -1;
	}
	if (n == 0)
		return 0;
	*out = xcalloc((size_t)n, sizeof(struct menu_item));
	for (int i = 0; i < n; i++) {
		if (parse_item(jv_at(arr, i), app, &(*out)[i], partial,
			       err, errlen) < 0) {
			for (int k = 0; k < i; k++)
				item_free(&(*out)[k]);
			free(*out);
			*out = NULL;
			return -1;
		}
		(*nout)++;
	}
	return 0;
}

static int parse_status_array(const jv *arr, const char *app,
			      struct widget **out, int *nout,
			      char *err, size_t errlen)
{
	int n = jv_len(arr);

	*out = NULL;
	*nout = 0;
	if (!arr)
		return 0;
	if (arr->type != JV_ARRAY) {
		snprintf(err, errlen, "status must be an array");
		return -1;
	}
	if (n > MAX_ITEMS_PER_APP) {
		snprintf(err, errlen, "too many status widgets");
		return -1;
	}
	if (n == 0)
		return 0;
	*out = xcalloc((size_t)n, sizeof(struct widget));
	for (int i = 0; i < n; i++) {
		if (parse_widget(jv_at(arr, i), app, &(*out)[i], err, errlen) < 0) {
			for (int k = 0; k < i; k++)
				widget_free(&(*out)[k]);
			free(*out);
			*out = NULL;
			return -1;
		}
		(*nout)++;
	}
	return 0;
}

/* --------------------------------------------------------------- manifests */

static int valid_app(const char *app);

static int read_file(const char *path, char **out, size_t *len)
{	FILE *f;
	long sz;
	char *buf;

	*out = NULL;
	*len = 0;
	f = fopen(path, "rb");
	if (!f)
		return -1;
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return -1;
	}
	sz = ftell(f);
	if (sz <= 0 || sz > 256 * 1024) {
		fclose(f);
		return -1;
	}
	rewind(f);
	buf = xcalloc((size_t)sz + 1, 1);
	*len = fread(buf, 1, (size_t)sz, f);
	fclose(f);
	if (*len != (size_t)sz) {
		free(buf);
		return -1;
	}
	*out = buf;
	return 0;
}

static int load_one_manifest(const char *dir, struct manifest *m)
{
	char path[PATH_MAX + 512];
	char *text = NULL;
	size_t len = 0;
	jv *root = NULL;
	char *err = NULL;
	const char *app;
	const jv *menu;

	memset(m, 0, sizeof(*m));
	snprintf(path, sizeof(path), "%s/%s/app.json", g.apps_dir, dir);
	if (read_file(path, &text, &len) < 0) {
		logmsg("skip %s: cannot read app.json\n", dir);
		return -1;
	}
	root = jv_parse(text, len, &err);
	free(text);
	if (!root) {
		logmsg("skip %s: %s\n", dir, err ? err : "bad JSON");
		free(err);
		return -1;
	}
	app = jv_str(jv_get(root, "id"));
	if (!app || !*app)
		app = dir;
	if (!valid_app(app)) {
		logmsg("skip %s: invalid app id\n", dir);
		jv_free(root);
		return -1;
	}
	m->app = xstrdup(app);
	menu = jv_get(root, "menu");
	{
		char buf[256];

		if (parse_menu_array(menu, app, 0, &m->items, &m->nitems,
				     buf, sizeof(buf)) < 0) {
			logmsg("skip %s: %s\n", dir, buf);
			jv_free(root);
			manifest_clear(m);
			return -1;
		}
	}
	jv_free(root);
	return 0;
}

static int cmp_manifest(const void *a, const void *b)
{
	const struct manifest *ma = a;
	const struct manifest *mb = b;

	return strcmp(ma->app, mb->app);
}

static void seed_tokens(void)
{
	DIR *d = opendir(g.etc_dir);
	struct dirent *de;

	if (!d)
		return;
	mkdir("/run/cpz", 0755);
	mkdir(g.run_dir, 0755);
	while ((de = readdir(d)) != NULL) {
		char src[PATH_MAX + 512], dst[PATH_MAX + 512];
		char *data = NULL;
		size_t len = 0;
		size_t n;
		int fd;

		n = strlen(de->d_name);
		if (n < 7 || strcmp(de->d_name + n - 6, ".token"))
			continue;
		snprintf(src, sizeof(src), "%s/%s", g.etc_dir, de->d_name);
		snprintf(dst, sizeof(dst), "%s/%s", g.run_dir, de->d_name);
		if (read_file(src, &data, &len) < 0)
			continue;
		fd = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
		if (fd >= 0) {
			(void)write(fd, data, len);
			close(fd);
		}
		free(data);
	}
	closedir(d);
}

static void load_manifests(void)
{
	DIR *d;
	struct dirent *de;
	int n = 0;

	for (int i = 0; i < g.nmanifests; i++)
		manifest_clear(&g.manifests[i]);
	g.nmanifests = 0;

	d = opendir(g.apps_dir);
	if (!d) {
		logmsg("apps directory %s: %s\n", g.apps_dir, strerror(errno));
	} else {
		while ((de = readdir(d)) != NULL && n < MAX_APPS) {
			struct stat st;
			char path[PATH_MAX + 512];

			if (de->d_name[0] == '.')
				continue;
			snprintf(path, sizeof(path), "%s/%s", g.apps_dir,
				 de->d_name);
			if (stat(path, &st) < 0 || !S_ISDIR(st.st_mode))
				continue;
			if (load_one_manifest(de->d_name,
					      &g.manifests[g.nmanifests]) == 0)
				g.nmanifests++;
		}
		closedir(d);
	}
	qsort(g.manifests, (size_t)g.nmanifests, sizeof(g.manifests[0]),
	      cmp_manifest);
	if (!g.selftest)
		seed_tokens();
	logmsg("loaded %d manifest(s), generation %llu\n", g.nmanifests,
	       (unsigned long long)g.generation);
}

/* --------------------------------------------------------------- model merge */

struct model {
	struct menu_item **items;
	int nitems;
	struct widget **widgets;
	int nwidgets;
};

static int find_item(struct menu_item **items, int n, const char *id)
{
	for (int i = 0; i < n; i++)
		if (!strcmp(items[i]->id, id))
			return i;
	return -1;
}

static int find_widget(struct widget **w, int n, const char *id)
{
	for (int i = 0; i < n; i++)
		if (!strcmp(w[i]->id, id))
			return i;
	return -1;
}

static int item_depth(struct menu_item **items, int n, int idx)
{
	int depth = 1;
	const char *parent = items[idx]->parent;
	int guard = 0;

	while (parent && strcmp(parent, "root") != 0 && guard++ < n + 1) {
		int p = find_item(items, n, parent);

		if (p < 0 || p == idx)
			break;
		depth++;
		parent = items[p]->parent;
	}
	return depth;
}

static int item_cycle(struct menu_item **items, int n, int idx)
{
	const char *start = items[idx]->id;
	const char *parent = items[idx]->parent;
	int guard = 0;

	while (parent && strcmp(parent, "root") != 0 && guard++ < n + 2) {
		int p;

		if (!strcmp(parent, start))
			return 1;
		p = find_item(items, n, parent);
		if (p < 0)
			return 0;
		parent = items[p]->parent;
	}
	return 0;
}

static int child_before(struct menu_item **items, int ia, int ib)
{
	if (items[ia]->order != items[ib]->order)
		return items[ia]->order < items[ib]->order;
	return strcmp(items[ia]->id, items[ib]->id) < 0;
}

/*
 * The snapshot is a flat DFS order. A submenu item is followed by its
 * children, then the next sibling. This makes sibling order deterministic and
 * lets the UI rebuild a tree without sorting.
 */
static void emit_children(struct model *m, const char *parent, int depth,
			  struct menu_item **out, int *n, int *used)
{
	int *idx = xcalloc((size_t)m->nitems, sizeof(int));
	int count = 0;

	for (int i = 0; i < m->nitems; i++) {
		const char *p = m->items[i]->parent;

		if (!p || !*p)
			p = "root";
		if (!used[i] && !strcmp(p, parent))
			idx[count++] = i;
	}
	/* Small n: insertion sort keeps this portable (macOS qsort_r differs). */
	for (int a = 1; a < count; a++) {
		int v = idx[a];
		int b = a - 1;

		while (b >= 0 && child_before(m->items, v, idx[b])) {
			idx[b + 1] = idx[b];
			b--;
		}
		idx[b + 1] = v;
	}
	for (int k = 0; k < count; k++) {
		int i = idx[k];

		if (used[i])
			continue;
		used[i] = 1;
		out[(*n)++] = m->items[i];
		if (depth < MAX_DEPTH)
			emit_children(m, m->items[i]->id, depth + 1, out, n,
				      used);
	}
	free(idx);
}

static int build_model(struct model *m)
{
	int cap = MAX_TOTAL_ITEMS;
	int *used;
	struct menu_item **flat;
	int nflat = 0;
	int log_bad = g.bad_log_gen != g.generation;

	memset(m, 0, sizeof(*m));
	m->items = NULL;
	m->nitems = 0;
	m->widgets = NULL;
	m->nwidgets = 0;

	/* 1. Static manifests are the base. */
	for (int i = 0; i < g.nmanifests; i++) {
		for (int k = 0; k < g.manifests[i].nitems; k++) {
			if (m->nitems >= cap)
				break;
			if (find_item(m->items, m->nitems,
				      g.manifests[i].items[k].id) >= 0) {
				if (log_bad)
					logmsg("duplicate menu id %s from %s; skipped\n",
					       g.manifests[i].items[k].id,
					       g.manifests[i].app);
				continue;
			}
			m->items = realloc(m->items,
					   (size_t)(m->nitems + 1) *
					   sizeof(*m->items));
			m->items[m->nitems] = xcalloc(1, sizeof(struct menu_item));
			item_copy(m->items[m->nitems],
				  &g.manifests[i].items[k]);
			m->nitems++;
		}
	}
	if (!m->items)
		m->items = xcalloc(1, sizeof(*m->items));

	/* 2. Runtime registrations override by id, add runtime-only items. */
	for (int r = 0; r < MAX_APPS; r++) {
		struct registration *reg = &g.regs[r];

		if (!reg->used)
			continue;
		for (int k = 0; k < reg->nitems; k++) {
			int idx = find_item(m->items, m->nitems,
					    reg->items[k].id);

			if (idx >= 0) {
				item_apply(m->items[idx], &reg->items[k]);
				continue;
			}
			if (m->nitems >= cap)
				continue;
			m->items = realloc(m->items,
					   (size_t)(m->nitems + 1) *
					   sizeof(*m->items));
			m->items[m->nitems] = xcalloc(1, sizeof(struct menu_item));
			item_copy(m->items[m->nitems], &reg->items[k]);
			m->nitems++;
		}
	}

	/* 3. Parent/cycle/depth validation. */
	for (int i = 0; i < m->nitems; i++) {
		struct menu_item *it = m->items[i];
		int depth;

		if (!it->parent)
			it->parent = xstrdup("root");
		if (!strcmp(it->parent, "root"))
			continue;
		if (item_cycle(m->items, m->nitems, i) ||
		    find_item(m->items, m->nitems, it->parent) < 0) {
			if (log_bad)
				logmsg("item %s: parent %s is unknown or cyclic; using root\n",
				       it->id, it->parent);
			set_str(&it->parent, "root");
			continue;
		}
		depth = item_depth(m->items, m->nitems, i);
		if (depth > MAX_DEPTH) {
			if (log_bad)
				logmsg("item %s: depth %d > %d; using root\n",
				       it->id, depth, MAX_DEPTH);
			set_str(&it->parent, "root");
		}
	}
	if (log_bad)
		g.bad_log_gen = g.generation;

	/* 4. Flat DFS order. */
	flat = xcalloc((size_t)m->nitems, sizeof(*flat));
	used = xcalloc((size_t)m->nitems, sizeof(int));
	emit_children(m, "root", 1, flat, &nflat, used);
	/* Anything unreachable is attached to root after the tree. */
	for (int i = 0; i < m->nitems; i++)
		if (!used[i])
			flat[nflat++] = m->items[i];
	free(used);
	/* Replace item storage order with the DFS order for snapshot output. */
	{
		struct menu_item **copy = xcalloc((size_t)m->nitems,
						  sizeof(*copy));

		for (int i = 0; i < m->nitems; i++)
			copy[i] = m->items[i];
		for (int i = 0; i < nflat; i++)
			m->items[i] = flat[i];
		free(flat);
		free(copy);
	}

	/* 5. Status widget merge. */
	m->widgets = xcalloc(MAX_TOTAL_ITEMS, sizeof(*m->widgets));
	for (int r = 0; r < MAX_APPS; r++) {
		struct registration *reg = &g.regs[r];

		if (!reg->used)
			continue;
		for (int k = 0; k < reg->nstatus; k++) {
			int idx = find_widget(m->widgets, m->nwidgets,
					      reg->status[k].id);

			if (idx >= 0) {
				widget_free(m->widgets[idx]);
				widget_copy(m->widgets[idx], &reg->status[k]);
			} else {
				m->widgets[m->nwidgets] = xcalloc(
					1, sizeof(struct widget));
				widget_copy(m->widgets[m->nwidgets],
					    &reg->status[k]);
				m->nwidgets++;
			}
		}
	}
	/* Deterministic order; the UI still applies its layout policy. */
	for (int i = 0; i < m->nwidgets; i++) {
		for (int k = i + 1; k < m->nwidgets; k++) {
			int swap = 0;

			if (m->widgets[k]->order < m->widgets[i]->order)
				swap = 1;
			else if (m->widgets[k]->order == m->widgets[i]->order &&
				 strcmp(m->widgets[k]->id, m->widgets[i]->id) < 0)
				swap = 1;
			if (swap) {
				struct widget *tmp = m->widgets[i];

				m->widgets[i] = m->widgets[k];
				m->widgets[k] = tmp;
			}
		}
	}
	return 0;
}

static void model_free(struct model *m)
{
	for (int i = 0; i < m->nitems; i++) {
		item_free(m->items[i]);
		free(m->items[i]);
	}
	free(m->items);
	for (int i = 0; i < m->nwidgets; i++) {
		widget_free(m->widgets[i]);
		free(m->widgets[i]);
	}
	free(m->widgets);
	memset(m, 0, sizeof(*m));
}

/* ---------------------------------------------------------------- snapshot */

static jv *icon_json(const char *icon)
{
	if (!icon)
		return NULL;
	if (!strncmp(icon, "png:", 4)) {
		jv *o = jv_object();

		jv_obj_set(o, "png", jv_string(icon + 4));
		return o;
	}
	return jv_string(icon);
}

static jv *action_json(const struct action *a)
{
	jv *o = jv_object();

	if (a->kind == ACT_EXEC || a->kind == ACT_RUN) {
		jv *arr = jv_array();

		for (int i = 0; i < a->argc; i++)
			jv_arr_add(arr, jv_string(a->argv[i]));
		jv_obj_set(o, a->kind == ACT_EXEC ? "exec" : "run", arr);
	} else if (a->kind == ACT_INFO) {
		jv *info = jv_object();

		if (a->info_title)
			jv_obj_set(info, "title", jv_string(a->info_title));
		if (a->info_text)
			jv_obj_set(info, "text", jv_string(a->info_text));
		if (a->info_icon)
			jv_obj_set(info, "icon", icon_json(a->info_icon));
		if (a->info_severity)
			jv_obj_set(info, "severity",
				   jv_string(a->info_severity));
		jv_obj_set(o, "info", info);
	} else if (a->kind == ACT_CHOICE) {
		jv *arr = jv_array();

		for (int i = 0; i < a->nchoices; i++) {
			const struct choice *c = &a->choices[i];
			jv *co = jv_object();
			jv *ca = jv_object();
			jv *argv = jv_array();

			jv_obj_set(co, "label", jv_string(c->label ? c->label : ""));
			if (c->detail)
				jv_obj_set(co, "detail", jv_string(c->detail));
			if (c->icon)
				jv_obj_set(co, "icon", icon_json(c->icon));
			for (int k = 0; k < c->argc; k++)
				jv_arr_add(argv, jv_string(c->argv[k]));
			jv_obj_set(ca, c->kind == ACT_EXEC ? "exec" : "run",
				   argv);
			jv_obj_set(co, "action", ca);
			jv_arr_add(arr, co);
		}
		jv_obj_set(o, "choice", arr);
	}
	if (a->busy)
		jv_obj_set(o, "busy", jv_string(a->busy));
	return o;
}

static jv *item_json(const struct menu_item *it)
{
	jv *o = jv_object();

	jv_obj_set(o, "id", jv_string(it->id));
	jv_obj_set(o, "label", jv_string(it->label ? it->label : it->id));
	if (it->detail)
		jv_obj_set(o, "detail", jv_string(it->detail));
	jv_obj_set(o, "parent", jv_string(it->parent ? it->parent : "root"));
	jv_obj_set(o, "order", jv_number(it->order));
	if (it->icon) {
		jv *ic = icon_json(it->icon);

		if (ic)
			jv_obj_set(o, "icon", ic);
	}
	if (it->badge)
		jv_obj_set(o, "badge", jv_string(it->badge));
	jv_obj_set(o, "enabled", jv_bool(it->enabled));
	jv_obj_set(o, "visible", jv_bool(it->visible));
	if (it->confirm)
		jv_obj_set(o, "confirm", jv_string(it->confirm));
	if (it->act.kind != ACT_NONE)
		jv_obj_set(o, "action", action_json(&it->act));
	return o;
}

static jv *widget_json(const struct widget *w)
{
	jv *o = jv_object();

	jv_obj_set(o, "id", jv_string(w->id));
	jv_obj_set(o, "kind", jv_string(w->kind));
	if (!strcmp(w->kind, "battery")) {
		jv_obj_set(o, "level", jv_number(w->level));
		jv_obj_set(o, "charging", jv_bool(w->charging));
	} else if (!strcmp(w->kind, "clock") || !strcmp(w->kind, "text")) {
		jv_obj_set(o, "text", jv_string(w->text ? w->text : ""));
	} else if (!strcmp(w->kind, "glyph")) {
		jv_obj_set(o, "name", jv_string(w->name ? w->name : "dot"));
	} else if (!strcmp(w->kind, "png")) {
		jv_obj_set(o, "hash", jv_string(w->hash ? w->hash : ""));
	}
	jv_obj_set(o, "order", jv_number(w->order));
	jv_obj_set(o, "priority", jv_number(w->priority));
	jv_obj_set(o, "system", jv_bool(w->system));
	return o;
}

static jv *snapshot_json(void)
{
	struct model m;
	jv *root = jv_object();
	jv *menu = jv_array();
	jv *status = jv_array();

	build_model(&m);
	jv_obj_set(root, "v", jv_number(1));
	jv_obj_set(root, "generation", jv_number((double)g.generation));
	for (int i = 0; i < m.nitems; i++)
		jv_arr_add(menu, item_json(m.items[i]));
	jv_obj_set(root, "menu", menu);
	for (int i = 0; i < m.nwidgets; i++)
		jv_arr_add(status, widget_json(m.widgets[i]));
	jv_obj_set(root, "status", status);
	model_free(&m);
	return root;
}

/* ------------------------------------------------------------------ socket */

static int send_all(int fd, const char *data, size_t len)
{
	while (len > 0) {
		ssize_t n = write(fd, data, len);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		data += n;
		len -= (size_t)n;
	}
	return 0;
}

static int send_json(struct client *c, jv *v)
{
	size_t len;
	char *s = jv_dump(v, &len);
	int ret;

	if (!s)
		return -1;
	ret = send_all(c->fd, s, len);
	if (ret == 0)
		ret = send_all(c->fd, "\n", 1);
	jv_free_string(s);
	jv_free(v);
	return ret;
}

static void send_error(struct client *c, const char *msg)
{
	jv *o = jv_object();

	jv_obj_set(o, "v", jv_number(1));
	jv_obj_set(o, "error", jv_string(msg));
	send_json(c, o);
}

static void send_ok(struct client *c)
{
	jv *o = jv_object();

	jv_obj_set(o, "v", jv_number(1));
	jv_obj_set(o, "ok", jv_bool(1));
	jv_obj_set(o, "generation", jv_number((double)g.generation));
	send_json(c, o);
}

static void send_snapshot(struct client *c)
{
	send_json(c, snapshot_json());
}

static void send_notice(struct client *c, const char *text,
			const char *severity)
{
	jv *o = jv_object();

	jv_obj_set(o, "v", jv_number(1));
	jv_obj_set(o, "event", jv_string("notice"));
	jv_obj_set(o, "text", jv_string(text));
	if (severity)
		jv_obj_set(o, "severity", jv_string(severity));
	send_json(c, o);
}

static void base64_encode(const unsigned char *in, size_t n, char **out)
{
	static const char tab[] =
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	size_t olen = (n + 2) / 3 * 4;
	char *s = xcalloc(olen + 1, 1);
	size_t o = 0;

	for (size_t i = 0; i < n; i += 3) {
		unsigned v = (unsigned)in[i] << 16;

		if (i + 1 < n)
			v |= (unsigned)in[i + 1] << 8;
		if (i + 2 < n)
			v |= in[i + 2];
		s[o++] = tab[(v >> 18) & 0x3f];
		s[o++] = tab[(v >> 12) & 0x3f];
		s[o++] = i + 1 < n ? tab[(v >> 6) & 0x3f] : '=';
		s[o++] = i + 2 < n ? tab[v & 0x3f] : '=';
	}
	s[o] = '\0';
	*out = s;
}

static void send_icon(struct client *c, const char *hash)
{
	const struct icon *ic = icon_find(hash);
	char *b64;
	jv *o;

	if (!ic) {
		send_error(c, "unknown icon hash");
		return;
	}
	base64_encode(ic->data, ic->len, &b64);
	o = jv_object();
	jv_obj_set(o, "v", jv_number(1));
	jv_obj_set(o, "event", jv_string("icon"));
	jv_obj_set(o, "hash", jv_string(hash));
	jv_obj_set(o, "png", jv_string(b64));
	send_json(c, o);
	free(b64);
}

static int token_ok(const char *app, const char *token)
{
	char path[PATH_MAX + MAX_APP + 16];
	char buf[256];
	FILE *f;
	size_t n;

	if (g.insecure)
		return token && *token;
	if (!app || !*app || !token)
		return 0;
	snprintf(path, sizeof(path), "%s/%s.token", g.run_dir, app);
	f = fopen(path, "r");
	if (!f)
		return 0;
	if (!fgets(buf, sizeof(buf), f)) {
		fclose(f);
		return 0;
	}
	fclose(f);
	n = strlen(buf);
	while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r' ||
		     buf[n - 1] == ' ' || buf[n - 1] == '\t'))
		buf[--n] = '\0';
	return strcmp(buf, token) == 0;
}

static int valid_app(const char *app)
{
	size_t n;

	if (!app || !*app || strlen(app) > MAX_APP)
		return 0;
	if (!strcmp(app, ".") || !strcmp(app, ".."))
		return 0;
	n = strlen(app);
	for (size_t i = 0; i < n; i++) {
		char c = app[i];

		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		      (c >= '0' && c <= '9') || c == '.' || c == '_' ||
		      c == '-'))
			return 0;
	}
	return 1;
}

static int registration_index(const char *app)
{
	for (int i = 0; i < MAX_APPS; i++)
		if (g.regs[i].used && !strcmp(g.regs[i].app, app))
			return i;
	return -1;
}

static int registration_get(const char *app)
{
	int idx = registration_index(app);

	if (idx >= 0)
		return idx;
	for (int i = 0; i < MAX_APPS; i++) {
		if (!g.regs[i].used) {
			memset(&g.regs[i], 0, sizeof(g.regs[i]));
			g.regs[i].used = 1;
			g.regs[i].app = xstrdup(app);
			return i;
		}
	}
	return -1;
}

static int rate_ok(struct client *c)
{
	uint64_t now = now_ms();

	if (!c->win_start || now - c->win_start >= 1000) {
		c->win_start = now;
		c->win_count = 0;
	}
	c->win_count++;
	return c->win_count <= 10;
}

/* ------------------------------------------------------------ protocol ops */

static void do_register(struct client *c, const jv *o)
{
	int idx;
	struct registration *r;
	struct menu_item *items = NULL;
	struct widget *status = NULL;
	int nitems = 0, nstatus = 0;
	char err[256];
	double ttl = 0;

	if (!rate_ok(c)) {
		send_error(c, "rate limit exceeded");
		return;
	}
	if (parse_menu_array(jv_get(o, "menu"), c->app, 1, &items, &nitems,
			     err, sizeof(err)) < 0) {
		send_error(c, err);
		return;
	}
	if (parse_status_array(jv_get(o, "status"), c->app, &status, &nstatus,
			       err, sizeof(err)) < 0) {
		for (int i = 0; i < nitems; i++)
			item_free(&items[i]);
		free(items);
		send_error(c, err);
		return;
	}
	idx = registration_get(c->app);
	if (idx < 0) {
		for (int i = 0; i < nitems; i++)
			item_free(&items[i]);
		free(items);
		for (int i = 0; i < nstatus; i++)
			widget_free(&status[i]);
		free(status);
		send_error(c, "too many provider apps");
		return;
	}
	r = &g.regs[idx];
	registration_clear(r);
	r->used = 1;
	r->app = xstrdup(c->app);
	r->items = items;
	r->nitems = nitems;
	r->status = status;
	r->nstatus = nstatus;
	ttl = jv_num(jv_get(o, "ttl_ms"), 0);
	if (ttl < 0)
		ttl = 0;
	if (ttl > 0) {
		r->one_shot = 1;
		r->ttl_ms = (uint64_t)ttl;
		r->expires = now_ms() + r->ttl_ms;
	}
	c->reg = idx;
	bump_generation();
	send_ok(c);
}

static void do_update(struct client *c, const jv *o)
{
	struct registration *r;
	struct menu_item *items = NULL;
	struct widget *status = NULL;
	int nitems = 0, nstatus = 0;
	char err[256];

	if (!c->app[0] || c->reg < 0 || c->reg >= MAX_APPS ||
	    !g.regs[c->reg].used) {
		send_error(c, "register first");
		return;
	}
	if (!rate_ok(c)) {
		send_error(c, "rate limit exceeded");
		return;
	}
	r = &g.regs[c->reg];
	if (parse_menu_array(jv_get(o, "menu"), c->app, 1, &items, &nitems,
			     err, sizeof(err)) < 0) {
		send_error(c, err);
		return;
	}
	if (parse_status_array(jv_get(o, "status"), c->app, &status, &nstatus,
			       err, sizeof(err)) < 0) {
		for (int i = 0; i < nitems; i++)
			item_free(&items[i]);
		free(items);
		send_error(c, err);
		return;
	}
	if (r->nitems + nitems > MAX_ITEMS_PER_APP ||
	    r->nstatus + nstatus > MAX_ITEMS_PER_APP) {
		for (int i = 0; i < nitems; i++)
			item_free(&items[i]);
		free(items);
		for (int i = 0; i < nstatus; i++)
			widget_free(&status[i]);
		free(status);
		send_error(c, "too many items for app");
		return;
	}
	for (int i = 0; i < nitems; i++) {
		int idx = -1;

		for (int k = 0; k < r->nitems; k++)
			if (!strcmp(r->items[k].id, items[i].id)) {
				idx = k;
				break;
			}
		if (idx >= 0) {
			item_apply(&r->items[idx], &items[i]);
			item_free(&items[i]);
		} else {
			r->items = realloc(r->items,
					   (size_t)(r->nitems + 1) *
					   sizeof(*r->items));
			r->items[r->nitems++] = items[i];
		}
	}
	free(items);
	for (int i = 0; i < nstatus; i++) {
		int idx = -1;

		for (int k = 0; k < r->nstatus; k++)
			if (!strcmp(r->status[k].id, status[i].id)) {
				idx = k;
				break;
			}
		if (idx >= 0) {
			widget_free(&r->status[idx]);
			r->status[idx] = status[i];
		} else {
			r->status = realloc(r->status,
					    (size_t)(r->nstatus + 1) *
					    sizeof(*r->status));
			r->status[r->nstatus++] = status[i];
		}
	}
	free(status);
	if (r->one_shot)
		r->expires = now_ms() + r->ttl_ms;
	bump_generation();
	send_ok(c);
}

static void do_heartbeat(struct client *c)
{
	if (c->reg < 0 || c->reg >= MAX_APPS || !g.regs[c->reg].used) {
		send_error(c, "register first");
		return;
	}
	if (g.regs[c->reg].one_shot)
		g.regs[c->reg].expires = now_ms() + g.regs[c->reg].ttl_ms;
	send_ok(c);
}

static void do_unregister(struct client *c)
{
	if (c->reg >= 0 && c->reg < MAX_APPS && g.regs[c->reg].used) {
		registration_clear(&g.regs[c->reg]);
		bump_generation();
	}
	c->reg = -1;
	send_ok(c);
}

static void do_hello(struct client *c, const jv *o)
{
	const char *role = jv_str(jv_get(o, "role"));

	if (!role) {
		send_error(c, "hello needs a role");
		return;
	}
	if (!strcmp(role, "ui")) {
		c->role = ROLE_UI;
		send_ok(c);
		send_snapshot(c);
	} else if (!strcmp(role, "provider")) {
		const char *app = jv_str(jv_get(o, "app"));
		const char *token = jv_str(jv_get(o, "token"));
		int idx;

		if (!valid_app(app)) {
			send_error(c, "bad app id");
			return;
		}
		if (!token_ok(app, token)) {
			send_error(c, "bad token");
			return;
		}
		idx = registration_get(app);
		if (idx < 0) {
			send_error(c, "too many provider apps");
			return;
		}
		c->role = ROLE_PROVIDER;
		snprintf(c->app, sizeof(c->app), "%s", app);
		c->reg = idx;
		send_ok(c);
	} else if (!strcmp(role, "admin")) {
#ifdef __linux__
		struct ucred cred;
		socklen_t len = sizeof(cred);

		if (getsockopt(c->fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) < 0 ||
		    cred.uid != 0) {
			send_error(c, "admin requires uid 0");
			return;
		}
#endif
		c->role = ROLE_ADMIN;
		send_ok(c);
	} else {
		send_error(c, "unknown role");
	}
}

static void handle_provider_disconnect(struct client *c)
{	if (c->role != ROLE_PROVIDER)
		return;
	if (c->reg < 0 || c->reg >= MAX_APPS || !g.regs[c->reg].used)
		return;
	/*
	 * A one-shot provider (ttl_ms > 0) is kept until expiry, even after the
	 * CLI exits. A connection-bound provider is removed immediately.
	 */
	if (!g.regs[c->reg].one_shot) {
		registration_clear(&g.regs[c->reg]);
		bump_generation();
	}
	c->reg = -1;
}

static void client_close(struct client *c);

static void handle_line(struct client *c, char *line)
{
	jv *o;
	char *err = NULL;
	const char *op;
	double v;

	if (!line[0])
		return;
	o = jv_parse(line, strlen(line), &err);
	if (!o) {
		logmsg("malformed JSON from client: %s\n", err ? err : "?");
		free(err);
		send_error(c, "malformed JSON");
		/* RFC: reject the message and close the provider connection. */
		if (c->role == ROLE_PROVIDER || c->role == ROLE_NONE)
			client_close(c);
		return;
	}
	v = jv_num(jv_get(o, "v"), 1);
	if (v != 1) {
		send_error(c, "unsupported protocol version");
		jv_free(o);
		return;
	}
	op = jv_str(jv_get(o, "op"));
	if (!op) {
		send_error(c, "missing op");
		jv_free(o);
		return;
	}
	if (!strcmp(op, "hello")) {
		if (c->role != ROLE_NONE)
			send_error(c, "already greeted");
		else
			do_hello(c, o);
	} else if (c->role == ROLE_NONE) {
		send_error(c, "hello first");
	} else if (!strcmp(op, "snapshot")) {
		send_snapshot(c);
	} else if (!strcmp(op, "subscribe")) {
		c->subscribed = 1;
		send_snapshot(c);
	} else if (!strcmp(op, "icon")) {
		const char *hash = jv_str(jv_get(o, "hash"));

		if (!hash)
			send_error(c, "icon needs hash");
		else
			send_icon(c, hash);
	} else if (!strcmp(op, "rescan")) {
		if (c->role != ROLE_ADMIN) {
			send_error(c, "rescan requires admin");
		} else {
			load_manifests();
			bump_generation();
			send_ok(c);
		}
	} else if (c->role != ROLE_PROVIDER) {
		send_error(c, "provider op from non-provider");
	} else if (!strcmp(op, "register")) {
		do_register(c, o);
	} else if (!strcmp(op, "update")) {
		do_update(c, o);
	} else if (!strcmp(op, "heartbeat")) {
		do_heartbeat(c);
	} else if (!strcmp(op, "unregister")) {
		do_unregister(c);
	} else if (!strcmp(op, "notice")) {
		const char *text = jv_str(jv_get(o, "text"));
		const char *sev = jv_str(jv_get(o, "severity"));

		if (!text || strlen(text) > 240) {
			send_error(c, "notice text is required (max 240)");
		} else if (!rate_ok(c)) {
			send_error(c, "rate limit exceeded");
		} else {
			for (int i = 0; i < MAX_CLIENTS; i++)
				if (g.clients[i].fd >= 0 &&
				    g.clients[i].role == ROLE_UI &&
				    g.clients[i].subscribed)
					send_notice(&g.clients[i], text, sev);
			send_ok(c);
		}
	} else {
		send_error(c, "unknown op");
	}
	jv_free(o);
}

static void client_close(struct client *c)
{
	if (c->fd >= 0) {
		handle_provider_disconnect(c);
		close(c->fd);
	}
	free(c->buf);
	memset(c, 0, sizeof(*c));
	c->fd = -1;
	c->reg = -1;
}

static void client_read(struct client *c)
{
	char tmp[8192];

	for (;;) {
		ssize_t n = recv(c->fd, tmp, sizeof(tmp), 0);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				return;
			client_close(c);
			return;
		}
		if (n == 0) {
			client_close(c);
			return;
		}
		if (c->len + (size_t)n > MAX_MSG) {
			logmsg("message too large; closing client\n");
			client_close(c);
			return;
		}
		if (c->len + (size_t)n + 1 > c->cap) {
			size_t cap = c->cap ? c->cap * 2 : 4096;

			while (cap < c->len + (size_t)n + 1)
				cap *= 2;
			char *p = realloc(c->buf, cap);

			if (!p) {
				client_close(c);
				return;
			}
			c->buf = p;
			c->cap = cap;
		}
		memcpy(c->buf + c->len, tmp, (size_t)n);
		c->len += (size_t)n;
		c->buf[c->len] = '\0';

		for (;;) {
			char *nl = memchr(c->buf, '\n', c->len);
			size_t line_len;

			if (!nl)
				break;
			line_len = (size_t)(nl - c->buf);
			*nl = '\0';
			if (line_len && c->buf[line_len - 1] == '\r')
				c->buf[line_len - 1] = '\0';
			handle_line(c, c->buf);
			if (c->fd < 0)
				return;
			memmove(c->buf, nl + 1,
				c->len - line_len - 1);
			c->len -= line_len + 1;
			c->buf[c->len] = '\0';
		}
	}
}

static void accept_clients(void)
{
	for (;;) {
		int fd = accept(g.listen_fd, NULL, NULL);
		int slot = -1;

		if (fd < 0) {
			if (errno == EINTR)
				continue;
			return;
		}
		for (int i = 0; i < MAX_CLIENTS; i++)
			if (g.clients[i].fd < 0) {
				slot = i;
				break;
			}
		if (slot < 0) {
			logmsg("too many clients; rejecting\n");
			close(fd);
			continue;
		}
		fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
		fcntl(fd, F_SETFD, FD_CLOEXEC);
#ifdef __linux__
		{
			struct ucred cred;
			socklen_t len = sizeof(cred);

			if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred,
				       &len) == 0)
				logmsg("client pid %d uid %d gid %d connected\n",
				       (int)cred.pid, (int)cred.uid,
				       (int)cred.gid);
		}
#endif
		memset(&g.clients[slot], 0, sizeof(g.clients[slot]));
		g.clients[slot].fd = fd;
		g.clients[slot].role = ROLE_NONE;
		g.clients[slot].reg = -1;
	}
}

static void notify_subscribers(void)
{
	struct model m;
	jv *snap = NULL;
	char *snap_text = NULL;
	size_t snap_len = 0;

	if (!g.dirty)
		return;
	build_model(&m);
	snap = jv_object();
	{
		jv *menu = jv_array();
		jv *status = jv_array();

		jv_obj_set(snap, "v", jv_number(1));
		jv_obj_set(snap, "generation",
			   jv_number((double)g.generation));
		for (int i = 0; i < m.nitems; i++)
			jv_arr_add(menu, item_json(m.items[i]));
		jv_obj_set(snap, "menu", menu);
		for (int i = 0; i < m.nwidgets; i++)
			jv_arr_add(status, widget_json(m.widgets[i]));
		jv_obj_set(snap, "status", status);
	}
	model_free(&m);
	snap_text = jv_dump(snap, &snap_len);
	jv_free(snap);
	if (!snap_text)
		return;

	for (int i = 0; i < MAX_CLIENTS; i++) {
		struct client *c = &g.clients[i];
		jv *changed;

		if (c->fd < 0 || c->role != ROLE_UI || !c->subscribed)
			continue;
		changed = jv_object();
		jv_obj_set(changed, "v", jv_number(1));
		jv_obj_set(changed, "event", jv_string("changed"));
		jv_obj_set(changed, "generation",
			   jv_number((double)g.generation));
		send_json(c, changed);
		if (send_all(c->fd, snap_text, snap_len) == 0)
			send_all(c->fd, "\n", 1);
	}
	jv_free_string(snap_text);
	g.dirty = 0;
	g.notify_at = 0;
}

/* -------------------------------------------------------------- main loop */

static void expire_registrations(void)
{
	uint64_t now = now_ms();
	int changed = 0;

	for (int i = 0; i < MAX_APPS; i++) {
		struct registration *r = &g.regs[i];

		if (r->used && r->one_shot && r->expires &&
		    now >= r->expires) {
			logmsg("provider %s expired\n", r->app);
			registration_clear(r);
			changed = 1;
		}
	}
	if (changed)
		bump_generation();
}

static int open_socket(void)
{
	struct sockaddr_un sa;
	int fd;

	if (strlen(g.socket_path) >= sizeof(sa.sun_path)) {
		logmsg("socket path too long\n");
		return -1;
	}
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", g.socket_path);

	mkdir("/run/cpz", 0755);
	mkdir(g.run_dir, 0755);
	unlink(g.socket_path);

	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0)
		return -1;
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0 ||
	    listen(fd, 16) < 0) {
		close(fd);
		return -1;
	}
	chmod(g.socket_path, 0660);
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
	return fd;
}

static void sd_notify_ready(void)
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
		snprintf(sa.sun_path + 1, sizeof(sa.sun_path) - 1, "%s",
			 sock + 1);
	} else {
		snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", sock);
	}
	fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (fd < 0)
		return;
	(void)sendto(fd, "READY=1", 7, MSG_NOSIGNAL,
		     (struct sockaddr *)&sa, sizeof(sa));
	close(fd);
}

static void on_signal(int sig)
{
	if (sig == SIGHUP)
		g.reload = 1;
	else
		g.stop = 1;
}

static void setup_inotify(void)
{
#ifdef __linux__
	g.inotify_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	if (g.inotify_fd < 0)
		return;
	if (inotify_add_watch(g.inotify_fd, g.apps_dir,
			      IN_CREATE | IN_DELETE | IN_MOVED_FROM |
			      IN_MOVED_TO | IN_CLOSE_WRITE | IN_ATTRIB) < 0) {
		logmsg("inotify cannot watch %s: %s\n", g.apps_dir,
		       strerror(errno));
		close(g.inotify_fd);
		g.inotify_fd = -1;
	}
#endif
}

static void handle_inotify(void)
{
#ifdef __linux__
	char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
	ssize_t n;

	while ((n = read(g.inotify_fd, buf, sizeof(buf))) > 0)
		;
	if (!g.reload_at) {
		logmsg("app directory changed; rescan scheduled\n");
		g.reload_at = now_ms() + 150;
	}
#else
	(void)0;
#endif
}

static int selftest(void)
{
	g.selftest = 1;
	load_manifests();
	if (g.nmanifests == 0) {
		fprintf(stderr, "cpz-menud: no manifests in %s\n", g.apps_dir);
		return 1;
	}
	struct model m;

	build_model(&m);
	printf("manifest=%d items=%d status=%d generation=%llu\n",
	       g.nmanifests, m.nitems, m.nwidgets,
	       (unsigned long long)g.generation);
	/* Exercise the serializer so a malformed item is caught here. */
	jv *snap = snapshot_json();
	size_t len = 0;
	char *text = jv_dump(snap, &len);

	if (!text) {
		fprintf(stderr, "cpz-menud: cannot serialize snapshot\n");
		model_free(&m);
		return 1;
	}
	printf("snapshot=%zu bytes\n", len);
	jv_free_string(text);
	jv_free(snap);
	model_free(&m);
	return 0;
}

static void usage(FILE *out)
{
	fputs("usage: cpz-menud [--socket PATH] [--apps PATH] [--run PATH]\n"
	      "                 [--etc PATH] [--insecure] [--debug]\n"
	      "                 [--selftest] [--version]\n", out);
}

int main(int argc, char **argv)
{
	int selftest_mode = 0;

	memset(&g, 0, sizeof(g));
	snprintf(g.socket_path, sizeof(g.socket_path), "%s", DEFAULT_SOCKET);
	snprintf(g.apps_dir, sizeof(g.apps_dir), "%s", DEFAULT_APPS);
	snprintf(g.run_dir, sizeof(g.run_dir), "%s", DEFAULT_RUN);
	snprintf(g.etc_dir, sizeof(g.etc_dir), "%s", DEFAULT_ETC);
	g.listen_fd = -1;
	g.inotify_fd = -1;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
			snprintf(g.socket_path, sizeof(g.socket_path), "%s",
				 argv[++i]);
		} else if (!strcmp(argv[i], "--apps") && i + 1 < argc) {
			snprintf(g.apps_dir, sizeof(g.apps_dir), "%s", argv[++i]);
		} else if (!strcmp(argv[i], "--run") && i + 1 < argc) {
			snprintf(g.run_dir, sizeof(g.run_dir), "%s", argv[++i]);
		} else if (!strcmp(argv[i], "--etc") && i + 1 < argc) {
			snprintf(g.etc_dir, sizeof(g.etc_dir), "%s", argv[++i]);
		} else if (!strcmp(argv[i], "--insecure")) {
			g.insecure = 1;
		} else if (!strcmp(argv[i], "--debug")) {
			g.debug = 1;
		} else if (!strcmp(argv[i], "--selftest")) {
			selftest_mode = 1;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(stdout);
			return 0;
		} else if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-V")) {
			printf("cpz-menud %s\n", MENUD_VERSION);
			return 0;
		} else {
			fprintf(stderr, "cpz-menud: unknown argument '%s'\n",
				argv[i]);
			usage(stderr);
			return 2;
		}
	}

	g.generation = 1;
	if (selftest_mode)
		return selftest();
	load_manifests();

	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGHUP, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	for (int i = 0; i < MAX_CLIENTS; i++) {
		g.clients[i].fd = -1;
		g.clients[i].reg = -1;
	}
	g.listen_fd = open_socket();
	if (g.listen_fd < 0) {
		logmsg("cannot listen on %s: %s\n", g.socket_path,
		       strerror(errno));
		return 1;
	}
	setup_inotify();
	sd_notify_ready();
	logmsg("listening on %s (%d manifest(s))\n", g.socket_path,
	       g.nmanifests);

	while (!g.stop) {
		struct pollfd fds[2 + MAX_CLIENTS];
		int nfds = 0;
		int listen_i = -1, inotify_i = -1;
		int client_i[MAX_CLIENTS];
		uint64_t now = now_ms();
		int timeout = 1000;

		fds[nfds].fd = g.listen_fd;
		fds[nfds].events = POLLIN;
		listen_i = nfds++;
		if (g.inotify_fd >= 0) {
			fds[nfds].fd = g.inotify_fd;
			fds[nfds].events = POLLIN;
			inotify_i = nfds++;
		}
		for (int i = 0; i < MAX_CLIENTS; i++) {
			client_i[i] = -1;
			if (g.clients[i].fd >= 0) {
				fds[nfds].fd = g.clients[i].fd;
				fds[nfds].events = POLLIN;
				client_i[i] = nfds++;
			}
		}
		if (g.reload_at && g.reload_at > now &&
		    g.reload_at - now < (uint64_t)timeout)
			timeout = (int)(g.reload_at - now);
		if (g.reload_at && g.reload_at <= now)
			timeout = 0;
		if (g.notify_at && g.notify_at > now &&
		    g.notify_at - now < (uint64_t)timeout)
			timeout = (int)(g.notify_at - now);
		if (g.notify_at && g.notify_at <= now)
			timeout = 0;
		if (timeout < 10)
			timeout = 10;

		int pr = poll(fds, (nfds_t)nfds, timeout);
		if (pr < 0) {
			if (errno == EINTR)
				continue;
			logmsg("poll: %s\n", strerror(errno));
			break;
		}
		if (pr > 0 && listen_i >= 0 &&
		    (fds[listen_i].revents & POLLIN))
			accept_clients();
		if (pr > 0 && inotify_i >= 0 &&
		    (fds[inotify_i].revents & POLLIN))
			handle_inotify();
		for (int i = 0; i < MAX_CLIENTS; i++) {
			if (client_i[i] >= 0 && pr > 0 &&
			    (fds[client_i[i]].revents & (POLLIN | POLLHUP |
							 POLLERR))) {
				if (g.clients[i].fd >= 0)
					client_read(&g.clients[i]);
			}
		}

		now = now_ms();
		if (g.reload || (g.reload_at && now >= g.reload_at)) {
			g.reload = 0;
			g.reload_at = 0;
			load_manifests();
			bump_generation();
		}
		expire_registrations();
		if (g.dirty && g.notify_at && now >= g.notify_at)
			notify_subscribers();
		else if (g.dirty && !g.notify_at)
			g.notify_at = now + NOTIFY_MS;
	}

	for (int i = 0; i < MAX_CLIENTS; i++)
		if (g.clients[i].fd >= 0)
			client_close(&g.clients[i]);
	if (g.inotify_fd >= 0)
		close(g.inotify_fd);
	if (g.listen_fd >= 0) {
		close(g.listen_fd);
		unlink(g.socket_path);
	}
	for (int i = 0; i < MAX_APPS; i++)
		registration_clear(&g.regs[i]);
	for (int i = 0; i < g.nmanifests; i++)
		manifest_clear(&g.manifests[i]);
	for (int i = 0; i < g.nicons; i++)
		free(g.icons[i].data);
	return 0;
}
