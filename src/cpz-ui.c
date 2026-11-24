/*
 * cpz-ui — the Cardputer Zero launcher shell.
 *
 * Visual target: the click-wheel iPod nano (1st/2nd generation) Podium UI.
 * The shell is laid out on a fixed 320x170 logical canvas and scaled uniformly
 * to any output.
 *
 * Architecture (docs/MENU-RFC.md):
 *
 *   - cpz-menud owns the menu tree and status widgets. This process is a thin
 *     renderer: it subscribes to /run/cpz/menu.sock, keeps the last snapshot,
 *     and falls back to a compiled-in emergency menu when the daemon is down.
 *   - Navigation is data: a screen is a parent id plus its own cursor. The
 *     renderer never knows what "Music" or "Settings" is.
 *   - All presentation states live here: boot, menu, empty, degraded, loading,
 *     busy, progress, info, error, confirm, choice, input, toast.
 *   - Typed status widgets (battery/clock/glyph/png/text) are laid out by the
 *     shell; providers only supply data.
 *   - Menu icons belong to apps: they arrive as PNGs from the app bundle and
 *     are drawn as a tinted alpha mask. The built-in glyph table is reserved
 *     for status widgets and severity marks.
 *   - Launching a foreground app is a request to /run/cpz/session.sock. The
 *     supervisor stops this process and starts the app with the display free.
 *
 * Build:
 *   gcc -O2 -Wall -Wextra $(pkg-config --cflags sdl2 cairo pangocairo) \
 *       cpz-ui.c cpz-json.c -o cpz-ui \
 *       $(pkg-config --libs sdl2 cairo pangocairo) -lm
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <SDL2/SDL.h>
#include "cpz-sdlmode.h"
#include "cpz-json.h"
#include <cairo/cairo.h>
#include <pango/pangocairo.h>
#include <errno.h>
#include <math.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define SESSION_SOCKET "/run/cpz/session.sock"
#define MENU_SOCKET "/run/cpz/menu.sock"
#define VERSION "0.12.0"
#define SPLASH_MS 300
#define SCREEN_MAX 8
#define PAGE_MAX 8
#define MAX_ITEMS 512
#define MAX_ARGV 32
#define MAX_CHOICES 8
#define ICON_MAX 64
#define ICON_REQ_MAX 64
#define PI 3.14159265358979323846
#define UI_W 320
#define UI_H 170

/*
 * One shared text column. The title and every menu label start at the same
 * x; the 16 px app icon lives in the gutter to its left, whether the row has
 * an icon or not. That keeps an icon-less row from breaking the left edge.
 */
#define ICON_SLOT 20
#define ICON_GUTTER 24

#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0
#endif

static const char *menu_socket_path = MENU_SOCKET;
static const char *session_socket_path = SESSION_SOCKET;

enum uact_kind {
	UA_NONE = 0,
	UA_EXEC,
	UA_RUN,
	UA_INFO,
	UA_CHOICE,
};

struct uchoice {
	char *label;
	char *detail;
	char *icon;
	int kind;		/* UA_EXEC or UA_RUN */
	int argc;
	char *argv[MAX_ARGV];
};

struct uaction {
	int kind;
	int argc;
	char *argv[MAX_ARGV];
	char *info_title;
	char *info_text;
	char *info_icon;
	char *info_severity;
	char *busy;
	int nchoices;
	struct uchoice choices[MAX_CHOICES];
};

struct ui_item {
	char *id;
	char *label;
	char *detail;
	char *parent;
	char *icon;
	char *badge;
	char *confirm;
	int order;
	int enabled;
	int visible;
	struct uaction act;
};

struct ui_widget {
	char *id;
	char *kind;
	char *text;
	char *name;
	char *hash;
	int level;
	int charging;
	int order;
	int priority;
	int system;
};

struct snapshot {
	struct ui_item *items;
	int nitems;
	struct ui_widget *widgets;
	int nwidgets;
	int generation;
};

enum page_kind {
	PG_INFO = 1,
	PG_ERROR,
	PG_CONFIRM,
	PG_CHOICE,
	PG_INPUT,
};

struct page {
	int kind;
	char title[96];
	char text[1024];
	char icon[96];
	char severity[16];
	int selected;
	int nchoices;
	struct uchoice choices[MAX_CHOICES];
	struct uaction pending;
	int has_pending;
	char input[128];
	int input_len;
};

enum overlay_kind {
	OV_NONE = 0,
	OV_LOADING,
	OV_BUSY,
	OV_PROGRESS,
};

struct screen {
	char parent[96];
	char title[96];
	char sel_id[96];
	int selected;
	int top;
};

struct transition {
	int active;
	int dir;
	uint64_t start;
	int ms;
	int old_depth;
	struct screen old_stack[SCREEN_MAX];
};

struct icon {
	char hash[17];
	cairo_surface_t *surf;
};

struct icon_req {
	char hash[17];
	uint64_t at;
};

struct ui {
	SDL_Window *win;
	SDL_Renderer *ren;
	SDL_Texture *tex;
	cairo_surface_t *surf;
	cairo_t *cr;
	PangoLayout *layout;
	PangoFontDescription *font_reg;
	PangoFontDescription *font_bold;
	PangoFontDescription *font_body;
	PangoFontDescription *font_small;
	PangoFontDescription *font_status;
	int line_reg;
	int line_bold;
	int line_small;
	int line_status;
	int out_w, out_h;
	int sw, sh;
	int w, h;
	SDL_Rect dst;

	struct snapshot snap;
	int have_snapshot;
	int connected;
	int menu_fd;
	char *menu_buf;
	size_t menu_len;
	size_t menu_cap;
	uint64_t menu_retry_at;
	uint64_t snapshot_due;
	uint64_t last_poll;
	int degraded_toast;

	struct ui_item emerg[2];
	int nemerg;

	struct icon icons[ICON_MAX];
	int nicons;
	struct icon_req icon_req[ICON_REQ_MAX];
	int nicon_req;

	struct screen stack[SCREEN_MAX];
	int depth;
	struct transition trans;

	struct page pages[PAGE_MAX];
	int npages;

	int overlay;
	char ov_title[64];
	char ov_text[128];
	char pending_label[96];
	uint64_t ov_start;
	uint64_t ov_until;
	int progress;
	int ov_cancel;

	struct uaction pending;
	int has_pending;

	char toast[256];
	int toast_severity;
	uint64_t toast_until;

	int splash;
	uint64_t splash_until;
	uint64_t t_start;
	int first_frame;
	int dirty;
	uint64_t last_draw;
	int hb_fd;
	uint64_t last_hb;
	int quit;
	const char *screenshot;
	uint64_t screenshot_at;
	int screenshot_ms;
	char debug_open[96];
	char debug_activate[96];
	int debug_done;
};

/* iPod nano palette: white list, silver bar, azure selection. */
static const SDL_Color col_white = { 255, 255, 255, 255 };
static const SDL_Color col_text = { 0, 0, 0, 255 };
static const SDL_Color col_muted = { 110, 110, 110, 255 };
static const SDL_Color col_bar_top = { 255, 255, 255, 255 };
static const SDL_Color col_bar_bot = { 188, 198, 201, 255 };
static const SDL_Color col_bar_line = { 91, 91, 90, 255 };
static const SDL_Color col_sel_top = { 87, 151, 225, 255 };
static const SDL_Color col_sel_bot = { 37, 103, 203, 255 };
static const SDL_Color col_sel_rim = { 47, 95, 158, 255 };
static const SDL_Color col_sel_edge = { 191, 224, 244, 255 };

static void draw_splash(struct ui *u);
static const char *renderer_name(SDL_Renderer *ren);
static void clamp_scroll(struct ui *u);
static struct screen *cur_screen(struct ui *u);

/* ------------------------------------------------------------- utilities */

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
		fputs("cpz-ui: out of memory\n", stderr);
		exit(1);
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

static void action_free(struct uaction *a)
{
	for (int i = 0; i < a->argc; i++)
		free(a->argv[i]);
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
	}
	memset(a, 0, sizeof(*a));
}

static void item_free(struct ui_item *it)
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

static void widget_free(struct ui_widget *w)
{
	free(w->id);
	free(w->kind);
	free(w->text);
	free(w->name);
	free(w->hash);
	memset(w, 0, sizeof(*w));
}

static void snapshot_free(struct snapshot *s)
{
	for (int i = 0; i < s->nitems; i++)
		item_free(&s->items[i]);
	free(s->items);
	for (int i = 0; i < s->nwidgets; i++)
		widget_free(&s->widgets[i]);
	free(s->widgets);
	memset(s, 0, sizeof(*s));
}

static void choice_copy(struct uchoice *dst, const struct uchoice *src)
{
	memset(dst, 0, sizeof(*dst));
	dst->label = xstrdup(src->label);
	dst->detail = xstrdup(src->detail);
	dst->icon = xstrdup(src->icon);
	dst->kind = src->kind;
	dst->argc = src->argc;
	for (int i = 0; i < src->argc; i++)
		dst->argv[i] = xstrdup(src->argv[i]);
}

static void choice_free(struct uchoice *c)
{
	free(c->label);
	free(c->detail);
	free(c->icon);
	for (int i = 0; i < c->argc; i++)
		free(c->argv[i]);
	memset(c, 0, sizeof(*c));
}

static void action_copy(struct uaction *dst, const struct uaction *src)
{
	memset(dst, 0, sizeof(*dst));
	dst->kind = src->kind;
	dst->argc = src->argc;
	for (int i = 0; i < src->argc; i++)
		dst->argv[i] = xstrdup(src->argv[i]);
	dst->info_title = xstrdup(src->info_title);
	dst->info_text = xstrdup(src->info_text);
	dst->info_icon = xstrdup(src->info_icon);
	dst->info_severity = xstrdup(src->info_severity);
	dst->busy = xstrdup(src->busy);
	dst->nchoices = src->nchoices;
	for (int i = 0; i < src->nchoices; i++)
		choice_copy(&dst->choices[i], &src->choices[i]);
}

static void page_clear(struct page *p)
{
	for (int i = 0; i < p->nchoices; i++)
		choice_free(&p->choices[i]);
	action_free(&p->pending);
	memset(p, 0, sizeof(*p));
}

static void push_page(struct ui *u, const struct page *p)
{
	if (u->npages >= PAGE_MAX) {
		page_clear(&u->pages[0]);
		memmove(&u->pages[0], &u->pages[1],
			sizeof(u->pages[0]) * (size_t)(PAGE_MAX - 1));
		u->npages--;
	}
	u->pages[u->npages++] = *p;
	u->dirty = 1;
}

static void pop_page(struct ui *u)
{
	if (u->npages <= 0)
		return;
	page_clear(&u->pages[--u->npages]);
	u->dirty = 1;
}

/* ------------------------------------------------------------ JSON parse */

static char *json_string_dup(const jv *o, const char *key)
{
	const char *s = jv_str(jv_get(o, key));

	return s ? xstrdup(s) : NULL;
}

static char *json_icon_dup(const jv *o, const char *key)
{
	jv *v = jv_get(o, key);

	if (!v)
		return NULL;
	if (v->type == JV_STRING)
		return xstrdup(v->string);
	if (v->type == JV_OBJECT) {
		const char *hash = jv_str(jv_get(v, "png"));
		char buf[32];

		if (hash) {
			snprintf(buf, sizeof(buf), "png:%s", hash);
			return xstrdup(buf);
		}
	}
	return NULL;
}

static void parse_argv(const jv *v, struct uaction *a)
{
	int n = jv_len(v);

	if (!v || v->type != JV_ARRAY)
		return;
	if (n > MAX_ARGV)
		n = MAX_ARGV;
	for (int i = 0; i < n; i++) {
		const char *s = jv_str(jv_at(v, i));

		if (!s)
			continue;
		a->argv[a->argc++] = xstrdup(s);
	}
}

static void parse_action(const jv *a, struct uaction *out)
{
	jv *v;

	memset(out, 0, sizeof(*out));
	if (!a || a->type != JV_OBJECT)
		return;
	const char *busy = jv_str(jv_get(a, "busy"));

	if (busy)
		out->busy = xstrdup(busy);

	v = jv_get(a, "exec");
	if (v) {
		out->kind = UA_EXEC;
		parse_argv(v, out);
		return;
	}
	v = jv_get(a, "run");
	if (v) {
		out->kind = UA_RUN;
		parse_argv(v, out);
		return;
	}
	v = jv_get(a, "info");
	if (v && v->type == JV_OBJECT) {
		out->kind = UA_INFO;
		out->info_title = json_string_dup(v, "title");
		out->info_text = json_string_dup(v, "text");
		out->info_icon = json_icon_dup(v, "icon");
		out->info_severity = json_string_dup(v, "severity");
		return;
	}
	v = jv_get(a, "choice");
	if (v && v->type == JV_ARRAY) {
		int n = jv_len(v);

		if (n > MAX_CHOICES)
			n = MAX_CHOICES;
		out->kind = UA_CHOICE;
		for (int i = 0; i < n; i++) {
			jv *o = jv_at(v, i);
			jv *ca, *cv;
			struct uchoice *c = &out->choices[out->nchoices];

			if (!o || o->type != JV_OBJECT)
				continue;
			c->label = json_string_dup(o, "label");
			c->detail = json_string_dup(o, "detail");
			c->icon = json_icon_dup(o, "icon");
			ca = jv_get(o, "action");
			if (!ca)
				continue;
			cv = jv_get(ca, "exec");
			c->kind = UA_EXEC;
			if (!cv) {
				cv = jv_get(ca, "run");
				c->kind = UA_RUN;
			}
			if (!cv || cv->type != JV_ARRAY) {
				choice_free(c);
				continue;
			}
			int an = jv_len(cv);

			if (an > MAX_ARGV)
				an = MAX_ARGV;
			for (int k = 0; k < an; k++) {
				const char *s = jv_str(jv_at(cv, k));

				if (s)
					c->argv[c->argc++] = xstrdup(s);
			}
			out->nchoices++;
		}
	}
}

static void parse_widget(const jv *o, struct ui_widget *w)
{
	memset(w, 0, sizeof(*w));
	w->id = json_string_dup(o, "id");
	w->kind = json_string_dup(o, "kind");
	w->text = json_string_dup(o, "text");
	w->name = json_string_dup(o, "name");
	w->hash = json_string_dup(o, "hash");
	if (!w->hash)
		w->hash = json_string_dup(o, "icon");
	w->level = (int)jv_num(jv_get(o, "level"), 100);
	w->charging = jv_boolean(jv_get(o, "charging"), 0);
	w->order = (int)jv_num(jv_get(o, "order"), 0);
	w->priority = (int)jv_num(jv_get(o, "priority"), 0);
	w->system = jv_boolean(jv_get(o, "system"), 0);
	if (w->level < 0)
		w->level = 0;
	if (w->level > 100)
		w->level = 100;
}

static void parse_snapshot(struct ui *u, const jv *o)
{
	struct snapshot s;
	jv *menu = jv_get(o, "menu");
	jv *status = jv_get(o, "status");
	int n = jv_len(menu);
	int ns = jv_len(status);

	memset(&s, 0, sizeof(s));
	s.generation = (int)jv_num(jv_get(o, "generation"), 0);
	if (menu && menu->type == JV_ARRAY) {
		if (n > MAX_ITEMS)
			n = MAX_ITEMS;
		s.items = xcalloc((size_t)n, sizeof(*s.items));
		for (int i = 0; i < n; i++) {
			jv *it = jv_at(menu, i);
			struct ui_item *dst = &s.items[s.nitems];

			if (!it || it->type != JV_OBJECT)
				continue;
			dst->id = json_string_dup(it, "id");
			if (!dst->id) {
				item_free(dst);
				continue;
			}
			dst->label = json_string_dup(it, "label");
			dst->detail = json_string_dup(it, "detail");
			dst->parent = json_string_dup(it, "parent");
			dst->icon = json_icon_dup(it, "icon");
			dst->badge = json_string_dup(it, "badge");
			dst->confirm = json_string_dup(it, "confirm");
			dst->order = (int)jv_num(jv_get(it, "order"), 0);
			dst->enabled = jv_boolean(jv_get(it, "enabled"), 1);
			dst->visible = jv_boolean(jv_get(it, "visible"), 1);
			parse_action(jv_get(it, "action"), &dst->act);
			s.nitems++;
		}
	}
	if (status && status->type == JV_ARRAY) {
		if (ns > MAX_ITEMS)
			ns = MAX_ITEMS;
		s.widgets = xcalloc((size_t)ns, sizeof(*s.widgets));
		for (int i = 0; i < ns; i++) {
			jv *w = jv_at(status, i);

			if (!w || w->type != JV_OBJECT)
				continue;
			parse_widget(w, &s.widgets[s.nwidgets]);
			if (s.widgets[s.nwidgets].kind)
				s.nwidgets++;
			else
				widget_free(&s.widgets[s.nwidgets]);
		}
	}
	snapshot_free(&u->snap);
	u->snap = s;
	u->have_snapshot = 1;
	u->dirty = 1;

	/* Clamp the navigation stack to the new model. */
	while (u->depth > 1) {
		int found = 0;

		for (int i = 0; i < u->snap.nitems; i++)
			if (!strcmp(u->snap.items[i].id,
				    u->stack[u->depth - 1].parent)) {
				found = 1;
				break;
			}
		if (found)
			break;
		u->depth--;
	}
	for (int i = 0; i < u->depth; i++) {
		struct screen *s = &u->stack[i];
		int count = 0, sel = -1;

		for (int k = 0; k < u->snap.nitems; k++) {
			struct ui_item *it = &u->snap.items[k];
			const char *parent = it->parent ? it->parent : "root";

			if (!it->visible || strcmp(parent, s->parent))
				continue;
			if (s->sel_id[0] && !strcmp(it->id, s->sel_id))
				sel = count;
			count++;
		}
		if (sel >= 0)
			s->selected = sel;
		else if (s->selected >= count)
			s->selected = count > 0 ? count - 1 : 0;
	}
	clamp_scroll(u);
}

/* ----------------------------------------------------------- icon cache */

static cairo_status_t png_read_cb(void *closure, unsigned char *data,
				  unsigned int length)
{
	struct {
		const unsigned char *p;
		size_t len;
		size_t off;
	} *st = closure;
	size_t n = length;
	size_t avail = st->off < st->len ? st->len - st->off : 0;
	size_t copy = n < avail ? n : avail;

	if (copy > 0) {
		memcpy(data, st->p + st->off, copy);
		st->off += copy;
	}
	if (copy < n)
		memset(data + copy, 0, n - copy);
	return CAIRO_STATUS_SUCCESS;
}

static void icon_add_png(struct ui *u, const char *hash, const unsigned char *data,
			 size_t len)
{
	for (int i = 0; i < u->nicons; i++)
		if (!strcmp(u->icons[i].hash, hash))
			return;
	if (u->nicons >= ICON_MAX)
		return;
	struct {
		const unsigned char *p;
		size_t len;
		size_t off;
	} st = { data, len, 0 };
	cairo_surface_t *surf = cairo_image_surface_create_from_png_stream(
		png_read_cb, &st);

	if (cairo_surface_status(surf) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(surf);
		return;
	}
	snprintf(u->icons[u->nicons].hash, sizeof(u->icons[u->nicons].hash),
		 "%s", hash);
	u->icons[u->nicons].surf = surf;
	u->nicons++;
	u->dirty = 1;
}

static cairo_surface_t *icon_get(struct ui *u, const char *hash)
{
	for (int i = 0; i < u->nicons; i++)
		if (!strcmp(u->icons[i].hash, hash))
			return u->icons[i].surf;
	return NULL;
}

static int base64_val(int c)
{
	if (c >= 'A' && c <= 'Z')
		return c - 'A';
	if (c >= 'a' && c <= 'z')
		return c - 'a' + 26;
	if (c >= '0' && c <= '9')
		return c - '0' + 52;
	if (c == '+')
		return 62;
	if (c == '/')
		return 63;
	return -1;
}

static unsigned char *base64_decode(const char *s, size_t *out_len)
{
	size_t n = strlen(s);
	unsigned char *out = xcalloc(n / 4 * 3 + 4, 1);
	size_t o = 0;
	int quad[4];
	int q = 0;

	for (size_t i = 0; i < n; i++) {
		int v;

		if (s[i] == '=')
			break;
		v = base64_val((unsigned char)s[i]);
		if (v < 0)
			continue;
		quad[q++] = v;
		if (q == 4) {
			unsigned x = ((unsigned)quad[0] << 18) |
				     ((unsigned)quad[1] << 12) |
				     ((unsigned)quad[2] << 6) |
				     (unsigned)quad[3];
			out[o++] = (unsigned char)(x >> 16);
			out[o++] = (unsigned char)(x >> 8);
			out[o++] = (unsigned char)x;
			q = 0;
		}
	}
	if (q == 2) {
		out[o++] = (unsigned char)((quad[0] << 2) | (quad[1] >> 4));
	} else if (q == 3) {
		unsigned x = ((unsigned)quad[0] << 10) |
			     ((unsigned)quad[1] << 4) |
			     ((unsigned)quad[2] >> 2);

		out[o++] = (unsigned char)(x >> 8);
		out[o++] = (unsigned char)x;
	}
	*out_len = o;
	return out;
}

/* --------------------------------------------------------- menu socket */

static int send_all_fd(int fd, const char *data, size_t len)
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

static int menu_send(struct ui *u, const char *line)
{
	if (u->menu_fd < 0)
		return -1;
	if (send_all_fd(u->menu_fd, line, strlen(line)) < 0)
		return -1;
	return send_all_fd(u->menu_fd, "\n", 1);
}

static void toast_set(struct ui *u, const char *text, int severity, int ms)
{
	snprintf(u->toast, sizeof(u->toast), "%s", text ? text : "");
	u->toast_severity = severity;
	u->toast_until = now_ms() + (uint64_t)ms;
	u->dirty = 1;
}

static int menu_connect(struct ui *u)
{
	struct sockaddr_un sa;
	int fd;

	if (u->menu_fd >= 0)
		return 0;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", menu_socket_path);
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(fd);
		return -1;
	}
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	u->menu_fd = fd;
	u->connected = 1;
	u->degraded_toast = 0;
	if (menu_send(u, "{\"v\":1,\"op\":\"hello\",\"role\":\"ui\"}") < 0 ||
	    menu_send(u, "{\"v\":1,\"op\":\"subscribe\"}") < 0) {
		close(fd);
		u->menu_fd = -1;
		u->connected = 0;
		return -1;
	}
	return 0;
}

static void menu_disconnect(struct ui *u)
{
	if (u->menu_fd >= 0)
		close(u->menu_fd);
	u->menu_fd = -1;
	u->connected = 0;
	u->menu_len = 0;
	if (u->menu_buf)
		u->menu_buf[0] = '\0';
	u->menu_retry_at = now_ms() + 2000;
}

static int menu_admin_rescan(struct ui *u)
{
	struct sockaddr_un sa;
	char reply[256];
	int fd;

	(void)u;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", menu_socket_path);
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(fd);
		return -1;
	}
	if (send_all_fd(fd,
			"{\"v\":1,\"op\":\"hello\",\"role\":\"admin\"}\n",
			strlen("{\"v\":1,\"op\":\"hello\",\"role\":\"admin\"}\n")) < 0) {
		close(fd);
		return -1;
	}
	ssize_t n = read(fd, reply, sizeof(reply) - 1);
	if (n <= 0 || !strstr(reply, "\"ok\"")) {
		close(fd);
		return -1;
	}
	if (send_all_fd(fd, "{\"v\":1,\"op\":\"rescan\"}\n",
			strlen("{\"v\":1,\"op\":\"rescan\"}\n")) < 0) {
		close(fd);
		return -1;
	}
	n = read(fd, reply, sizeof(reply) - 1);
	close(fd);
	return n > 0 ? 0 : -1;
}

static void icon_request(struct ui *u, const char *hash)
{
	if (!hash || strlen(hash) != 16)
		return;
	if (icon_get(u, hash))
		return;
	uint64_t now = now_ms();
	for (int i = 0; i < u->nicon_req; i++)
		if (!strcmp(u->icon_req[i].hash, hash) &&
		    now - u->icon_req[i].at < 3000)
			return;
	if (u->nicon_req >= ICON_REQ_MAX)
		u->nicon_req = 0;
	snprintf(u->icon_req[u->nicon_req].hash, 17, "%s", hash);
	u->icon_req[u->nicon_req].at = now;
	u->nicon_req++;
	char line[128];

	snprintf(line, sizeof(line), "{\"v\":1,\"op\":\"icon\",\"hash\":\"%s\"}",
		 hash);
	menu_send(u, line);
}

static void request_missing_icons(struct ui *u)
{
	for (int i = 0; i < u->snap.nitems; i++) {
		const char *ic = u->snap.items[i].icon;

		if (ic && !strncmp(ic, "png:", 4))
			icon_request(u, ic + 4);
	}
	for (int i = 0; i < u->snap.nwidgets; i++) {
		struct ui_widget *w = &u->snap.widgets[i];

		if (w->kind && !strcmp(w->kind, "png") && w->hash)
			icon_request(u, w->hash);
	}
}

static void handle_menu_line(struct ui *u, char *line)
{
	char *err = NULL;
	jv *o;

	if (!line[0])
		return;
	o = jv_parse(line, strlen(line), &err);
	if (!o) {
		free(err);
		return;
	}
	const char *event = jv_str(jv_get(o, "event"));

	if (event) {
		if (!strcmp(event, "changed")) {
			u->snapshot_due = now_ms() + 40;
		} else if (!strcmp(event, "icon")) {
			const char *hash = jv_str(jv_get(o, "hash"));
			const char *b64 = jv_str(jv_get(o, "png"));

			if (hash && b64) {
				size_t len;
				unsigned char *data = base64_decode(b64, &len);

				icon_add_png(u, hash, data, len);
				free(data);
			}
		} else if (!strcmp(event, "notice")) {
			const char *text = jv_str(jv_get(o, "text"));

			if (text) {
				int sev = 0;
				const char *s = jv_str(jv_get(o, "severity"));

				if (s && !strcmp(s, "warning"))
					sev = 2;
				else if (s && !strcmp(s, "success"))
					sev = 1;
				toast_set(u, text, sev, 2500);
			}
		}
	} else if (jv_get(o, "menu")) {
		parse_snapshot(u, o);
		request_missing_icons(u);
		u->snapshot_due = 0;
		if (!u->degraded_toast && u->have_snapshot &&
		    u->snap.nitems > 0) {
			u->degraded_toast = 1;
		}
	} else if (jv_get(o, "error")) {
		const char *e = jv_str(jv_get(o, "error"));

		if (e)
			toast_set(u, e, 2, 2500);
	}
	jv_free(o);
}

static void menu_pump(struct ui *u)
{
	char tmp[8192];

	if (u->menu_fd < 0) {
		if (now_ms() >= u->menu_retry_at) {
			if (menu_connect(u) == 0) {
				u->snapshot_due = now_ms();
				if (u->have_snapshot)
					toast_set(u, "Меню відновлено", 1, 2500);
			} else {
				u->menu_retry_at = now_ms() + 2000;
				if (!u->have_snapshot && !u->degraded_toast) {
					u->degraded_toast = 1;
					toast_set(u, "cpz-menud недоступний", 2,
						  3000);
				}
			}
		}
		return;
	}
	for (;;) {
		ssize_t n = recv(u->menu_fd, tmp, sizeof(tmp), 0);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				break;
			menu_disconnect(u);
			return;
		}
		if (n == 0) {
			menu_disconnect(u);
			return;
		}
		if (u->menu_len + (size_t)n > 65536) {
			menu_disconnect(u);
			return;
		}
		if (u->menu_len + (size_t)n + 1 > u->menu_cap) {
			size_t cap = u->menu_cap ? u->menu_cap * 2 : 4096;

			while (cap < u->menu_len + (size_t)n + 1)
				cap *= 2;
			char *p = realloc(u->menu_buf, cap);

			if (!p) {
				menu_disconnect(u);
				return;
			}
			u->menu_buf = p;
			u->menu_cap = cap;
		}
		memcpy(u->menu_buf + u->menu_len, tmp, (size_t)n);
		u->menu_len += (size_t)n;
		u->menu_buf[u->menu_len] = '\0';
		for (;;) {
			char *nl = memchr(u->menu_buf, '\n', u->menu_len);
			size_t ll;

			if (!nl)
				break;
			ll = (size_t)(nl - u->menu_buf);
			*nl = '\0';
			if (ll && u->menu_buf[ll - 1] == '\r')
				u->menu_buf[ll - 1] = '\0';
			handle_menu_line(u, u->menu_buf);
			memmove(u->menu_buf, nl + 1, u->menu_len - ll - 1);
			u->menu_len -= ll + 1;
			u->menu_buf[u->menu_len] = '\0';
		}
	}
}

static void menu_tick(struct ui *u)
{
	uint64_t now = now_ms();

	if (u->menu_fd >= 0 && u->snapshot_due && now >= u->snapshot_due) {
		u->snapshot_due = 0;
		menu_send(u, "{\"v\":1,\"op\":\"snapshot\"}");
	}
	if (u->menu_fd >= 0 && now - u->last_poll >= 1000) {
		u->last_poll = now;
		menu_send(u, "{\"v\":1,\"op\":\"snapshot\"}");
	}
}

/* --------------------------------------------------------------- screens */

static void emergency_init(struct ui *u)
{
	struct ui_item *it;

	memset(u->emerg, 0, sizeof(u->emerg));
	it = &u->emerg[0];
	it->id = xstrdup("emergency.terminal");
	it->label = xstrdup("Термінал");
	it->detail = xstrdup("аварійний пункт");
	it->parent = xstrdup("root");
	it->order = 100;
	it->enabled = 1;
	it->visible = 1;
	it->act.kind = UA_EXEC;
	it->act.argc = 1;
	it->act.argv[0] = xstrdup("/usr/local/bin/cpz-term");

	it = &u->emerg[1];
	it->id = xstrdup("emergency.reload");
	it->label = xstrdup("Оновити меню");
	it->detail = xstrdup("повторна спроба");
	it->parent = xstrdup("root");
	it->order = 200;
	it->enabled = 1;
	it->visible = 1;
	u->nemerg = 2;
}

static void emergency_free(struct ui *u)
{
	for (int i = 0; i < u->nemerg; i++)
		item_free(&u->emerg[i]);
	u->nemerg = 0;
}

static int base_degraded(struct ui *u)
{
	return !u->have_snapshot;
}

static int base_empty(struct ui *u)
{
	if (!u->have_snapshot)
		return 0;
	for (int i = 0; i < u->snap.nitems; i++) {
		struct ui_item *it = &u->snap.items[i];
		const char *p = it->parent ? it->parent : "root";

		if (it->visible && !strcmp(p, "root"))
			return 0;
	}
	return 1;
}

static int screen_item_count(struct ui *u, const char *parent)
{
	if (!u->have_snapshot) {
		if (strcmp(parent, "root"))
			return 0;
		int n = 0;

		for (int i = 0; i < u->nemerg; i++)
			if (u->emerg[i].visible)
				n++;
		return n;
	}
	int n = 0;

	for (int i = 0; i < u->snap.nitems; i++) {
		struct ui_item *it = &u->snap.items[i];
		const char *p = it->parent ? it->parent : "root";

		if (it->visible && !strcmp(p, parent))
			n++;
	}
	return n;
}

static struct ui_item *screen_item(struct ui *u, const char *parent, int idx)
{
	if (!u->have_snapshot) {
		int n = 0;

		if (strcmp(parent, "root"))
			return NULL;
		for (int i = 0; i < u->nemerg; i++) {
			if (!u->emerg[i].visible)
				continue;
			if (n++ == idx)
				return &u->emerg[i];
		}
		return NULL;
	}
	int n = 0;

	for (int i = 0; i < u->snap.nitems; i++) {
		struct ui_item *it = &u->snap.items[i];
		const char *p = it->parent ? it->parent : "root";

		if (!it->visible || strcmp(p, parent))
			continue;
		if (n++ == idx)
			return it;
	}
	return NULL;
}

static int item_has_children(struct ui *u, const char *id)
{
	return screen_item_count(u, id) > 0;
}

static struct ui_item *find_item_by_id(struct ui *u, const char *id)
{
	if (!u->have_snapshot)
		return NULL;
	for (int i = 0; i < u->snap.nitems; i++)
		if (!strcmp(u->snap.items[i].id, id))
			return &u->snap.items[i];
	return NULL;
}

static const char *screen_title(struct ui *u)
{
	struct screen *s = cur_screen(u);
	struct ui_item *it;

	if (u->depth <= 1)
		return "Меню";
	it = find_item_by_id(u, s->parent);
	if (it && it->label)
		return it->label;
	return s->title;
}

static struct screen *cur_screen(struct ui *u)
{
	return &u->stack[u->depth - 1];
}

static void clamp_scroll(struct ui *u);

static void push_screen(struct ui *u, const char *parent, const char *title)
{
	struct transition *t = &u->trans;

	if (u->depth >= SCREEN_MAX)
		return;
	t->active = 1;
	t->dir = 1;
	t->start = now_ms();
	t->ms = 180;
	t->old_depth = u->depth;
	memcpy(t->old_stack, u->stack, sizeof(u->stack));
	struct screen *s = &u->stack[u->depth++];

	snprintf(s->parent, sizeof(s->parent), "%s", parent);
	snprintf(s->title, sizeof(s->title), "%s", title ? title : "");
	s->sel_id[0] = '\0';
	s->selected = 0;
	s->top = 0;
	u->dirty = 1;
}

static void pop_screen(struct ui *u)
{
	if (u->depth <= 1)
		return;
	struct transition *t = &u->trans;

	t->active = 1;
	t->dir = -1;
	t->start = now_ms();
	t->ms = 180;
	t->old_depth = u->depth;
	memcpy(t->old_stack, u->stack, sizeof(u->stack));
	u->depth--;
	clamp_scroll(u);
	u->dirty = 1;
}

/* --------------------------------------------------------------- session */

static int session_command(const char *line)
{
	struct sockaddr_un sa;
	char reply[128];
	int fd;

	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", session_socket_path);
	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0)
		return -1;
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(fd);
		return -1;
	}
	if (send_all_fd(fd, line, strlen(line)) < 0 ||
	    send_all_fd(fd, "\n", 1) < 0) {
		close(fd);
		return -1;
	}
	ssize_t n = read(fd, reply, sizeof(reply) - 1);
	close(fd);
	if (n <= 0)
		return -1;
	reply[n] = '\0';
	return strncmp(reply, "ok", 2) == 0 ? 0 : -1;
}

static char *argv_json(int argc, char *argv[])
{
	jv *o = jv_object();
	jv *arr = jv_array();
	size_t len;
	char *s;

	for (int i = 0; i < argc; i++)
		jv_arr_add(arr, jv_string(argv[i]));
	jv_obj_set(o, "argv", arr);
	s = jv_dump(o, &len);
	jv_free(o);
	return s;
}

/* ------------------------------------------------------------- state ops */

static void start_loading(struct ui *u, const char *label,
			  const struct uaction *act);
static void start_error(struct ui *u, const char *title, const char *text,
			const struct uaction *retry, const char *retry_label);
static void execute_action(struct ui *u, const struct uaction *act,
			   const char *label);

static void begin_confirm(struct ui *u, const struct ui_item *it)
{
	struct page p;

	memset(&p, 0, sizeof(p));
	p.kind = PG_CONFIRM;
	snprintf(p.title, sizeof(p.title), "%s",
		 it->label ? it->label : "Підтвердження");
	snprintf(p.text, sizeof(p.text), "%s",
		 it->confirm ? it->confirm : "Продовжити?");
	p.selected = 0;		/* safe choice: No */
	action_copy(&p.pending, &it->act);
	p.has_pending = 1;
	push_page(u, &p);
}

static void execute_action(struct ui *u, const struct uaction *act,
			   const char *label)
{
	switch (act->kind) {
	case UA_EXEC:
		if (act->argc > 0)
			start_loading(u, label, act);
		else
			toast_set(u, "Немає команди запуску", 2, 2500);
		break;
	case UA_RUN: {
		char *json = act->argc > 0 ? argv_json(act->argc,
						      (char **)act->argv) : NULL;
		char line[8192];

		if (!json) {
			toast_set(u, "Немає команди", 2, 2500);
			break;
		}
		snprintf(line, sizeof(line), "run-json %s", json);
		jv_free_string(json);
		if (act->busy && *act->busy) {
			u->overlay = OV_BUSY;
			snprintf(u->ov_title, sizeof(u->ov_title), "%s",
				 label ? label : "Виконання");
			snprintf(u->ov_text, sizeof(u->ov_text), "%s",
				 act->busy);
			u->ov_start = now_ms();
			u->ov_until = now_ms() + 700;
			u->dirty = 1;
		}
		if (session_command(line) < 0)
			start_error(u, "Помилка", "cpz-session не запущено",
				    act, label);
		else if (!act->busy || !*act->busy)
			toast_set(u, "Виконано", 1, 2000);
		break;
	}
	case UA_INFO: {
		struct page p;

		memset(&p, 0, sizeof(p));
		p.kind = PG_INFO;
		snprintf(p.title, sizeof(p.title), "%s",
			 act->info_title ? act->info_title :
			 (label ? label : "Інформація"));
		snprintf(p.text, sizeof(p.text), "%s",
			 act->info_text ? act->info_text : "");
		snprintf(p.icon, sizeof(p.icon), "%s",
			 act->info_icon ? act->info_icon : "builtin:info");
		snprintf(p.severity, sizeof(p.severity), "%s",
			 act->info_severity ? act->info_severity : "info");
		push_page(u, &p);
		break;
	}
	case UA_CHOICE: {
		struct page p;

		memset(&p, 0, sizeof(p));
		p.kind = PG_CHOICE;
		snprintf(p.title, sizeof(p.title), "%s",
			 label ? label : "Вибір");
		p.nchoices = act->nchoices;
		p.selected = 0;
		for (int i = 0; i < act->nchoices; i++)
			choice_copy(&p.choices[i], &act->choices[i]);
		push_page(u, &p);
		break;
	}
	default:
		toast_set(u, "Цей пункт ще не встановлено", 0, 2500);
		break;
	}
}

static void activate_item(struct ui *u, struct ui_item *it)
{
	if (!it)
		return;
	if (!it->enabled) {
		toast_set(u, "Недоступно", 0, 2000);
		return;
	}
	if (it->confirm && *it->confirm) {
		begin_confirm(u, it);
		return;
	}
	if (it->act.kind == UA_NONE && item_has_children(u, it->id)) {
		push_screen(u, it->id, it->label ? it->label : "");
		return;
	}
	if (it->act.kind == UA_NONE) {
		toast_set(u, "Цей пункт ще не встановлено", 0, 2500);
		return;
	}
	execute_action(u, &it->act, it->label);
}

static void start_loading(struct ui *u, const char *label,
			  const struct uaction *act)
{
	char *json;
	char line[8192];

	if (u->has_pending)
		action_free(&u->pending);
	action_copy(&u->pending, act);
	u->has_pending = 1;
	snprintf(u->pending_label, sizeof(u->pending_label), "%s",
		 label ? label : "Застосунок");

	json = argv_json(act->argc, (char **)act->argv);
	if (!json) {
		start_error(u, "Помилка", "Не вдалося сформувати команду", act,
			    label);
		return;
	}
	snprintf(line, sizeof(line), "launch-json %s", json);
	jv_free_string(json);

	u->overlay = OV_LOADING;
	snprintf(u->ov_title, sizeof(u->ov_title), "%s", "Запуск");
	snprintf(u->ov_text, sizeof(u->ov_text), "%s",
		 label ? label : "");
	u->ov_start = now_ms();
	u->ov_until = now_ms() + 10000;
	u->dirty = 1;

	if (session_command(line) < 0)
		start_error(u, "Помилка", "cpz-session не запущено", act, label);
}

static void start_error(struct ui *u, const char *title, const char *text,
			const struct uaction *retry, const char *retry_label)
{
	struct page p;

	u->overlay = OV_NONE;
	memset(&p, 0, sizeof(p));
	p.kind = PG_ERROR;
	snprintf(p.title, sizeof(p.title), "%s", title);
	snprintf(p.text, sizeof(p.text), "%s", text);
	if (retry) {
		action_copy(&p.pending, retry);
		p.has_pending = 1;
		snprintf(p.icon, sizeof(p.icon), "%s",
			 retry_label ? retry_label : "");
	}
	push_page(u, &p);
}

/* ------------------------------------------------------------- drawing */

static void set_rgba(cairo_t *cr, SDL_Color c)
{
	cairo_set_source_rgba(cr, c.r / 255.0, c.g / 255.0, c.b / 255.0,
			      c.a / 255.0);
}

static void round_rect_path(cairo_t *cr, double x, double y, double w,
			    double h, double r)
{
	if (r < 0)
		r = 0;
	if (r > w / 2)
		r = w / 2;
	if (r > h / 2)
		r = h / 2;
	cairo_new_sub_path(cr);
	cairo_arc(cr, x + w - r, y + r, r, -PI / 2, 0);
	cairo_arc(cr, x + w - r, y + h - r, r, 0, PI / 2);
	cairo_arc(cr, x + r, y + h - r, r, PI / 2, PI);
	cairo_arc(cr, x + r, y + r, r, PI, 3 * PI / 2);
	cairo_close_path(cr);
}

static void fill_vgradient(cairo_t *cr, double x, double y, double w,
			   double h, SDL_Color top, SDL_Color bot)
{
	cairo_pattern_t *p = cairo_pattern_create_linear(0, y, 0, y + h);

	cairo_pattern_add_color_stop_rgba(p, 0, top.r / 255.0, top.g / 255.0,
					  top.b / 255.0, top.a / 255.0);
	cairo_pattern_add_color_stop_rgba(p, 1, bot.r / 255.0, bot.g / 255.0,
					  bot.b / 255.0, bot.a / 255.0);
	cairo_set_source(cr, p);
	cairo_rectangle(cr, x, y, w, h);
	cairo_fill(cr);
	cairo_pattern_destroy(p);
}

static void text_set(struct ui *u, PangoFontDescription *font,
		     const char *text, int wrapw, PangoAlignment align)
{
	pango_layout_set_font_description(u->layout, font);
	pango_layout_set_text(u->layout, text ? text : "", -1);
	pango_layout_set_ellipsize(u->layout, PANGO_ELLIPSIZE_NONE);
	if (wrapw > 0) {
		pango_layout_set_width(u->layout, wrapw * PANGO_SCALE);
		pango_layout_set_wrap(u->layout, PANGO_WRAP_WORD_CHAR);
	} else {
		pango_layout_set_width(u->layout, -1);
	}
	pango_layout_set_alignment(u->layout, align);
}

static void text_begin(struct ui *u, int bold, const char *text, int wrapw,
		       PangoAlignment align)
{
	text_set(u, bold ? u->font_bold : u->font_reg, text, wrapw, align);
}

static void text_show(struct ui *u, int x, int y, SDL_Color c)
{
	set_rgba(u->cr, c);
	cairo_move_to(u->cr, x, y);
	pango_cairo_show_layout(u->cr, u->layout);
}

static int text_width_font(struct ui *u, PangoFontDescription *font,
			   const char *text)
{
	int w = 0, h = 0;

	text_set(u, font, text, 0, PANGO_ALIGN_LEFT);
	pango_layout_get_pixel_size(u->layout, &w, &h);
	return w;
}

static int text_width(struct ui *u, int bold, const char *text)
{
	return text_width_font(u, bold ? u->font_bold : u->font_reg, text);
}

/* Draw a single line, ellipsized to maxw. */
static void text_show_ellipsized(struct ui *u, PangoFontDescription *font,
				 const char *text, int x, int y, int maxw,
				 SDL_Color c, PangoAlignment align)
{
	if (maxw < 1)
		return;
	text_set(u, font, text, maxw, align);
	pango_layout_set_ellipsize(u->layout, PANGO_ELLIPSIZE_END);
	set_rgba(u->cr, c);
	cairo_move_to(u->cr, x, y);
	pango_cairo_show_layout(u->cr, u->layout);
}

static int measure_line(struct ui *u, PangoFontDescription *font)
{
	PangoContext *pc = pango_layout_get_context(u->layout);
	PangoFontMetrics *m;
	int h;

	m = pango_context_get_metrics(pc, font, NULL);
	h = (pango_font_metrics_get_ascent(m) +
	     pango_font_metrics_get_descent(m)) / PANGO_SCALE;
	pango_font_metrics_unref(m);
	return h;
}

static void layout(struct ui *u)
{
	double sx, sy, scale;

	SDL_GetRendererOutputSize(u->ren, &u->out_w, &u->out_h);
	if (u->out_w < 1 || u->out_h < 1) {
		u->out_w = UI_W;
		u->out_h = UI_H;
	}
	sx = (double)u->out_w / UI_W;
	sy = (double)u->out_h / UI_H;
	scale = sx < sy ? sx : sy;
	if (u->out_h > 2 * UI_H) {
		double hcap = 0.72 * u->out_h / UI_H;

		if (scale > hcap)
			scale = hcap;
		if (scale > 4.0)
			scale = 4.0;
	}
	u->sw = (int)(UI_W * scale + 0.5);
	u->sh = (int)(UI_H * scale + 0.5);
	if (u->sw < 1)
		u->sw = 1;
	if (u->sh < 1)
		u->sh = 1;
	u->w = UI_W;
	u->h = UI_H;
	u->dst.x = (u->out_w - u->sw) / 2;
	u->dst.y = (u->out_h - u->sh) / 2;
	u->dst.w = u->sw;
	u->dst.h = u->sh;

	if (u->layout)
		g_object_unref(u->layout);
	if (u->font_reg)
		pango_font_description_free(u->font_reg);
	if (u->font_bold)
		pango_font_description_free(u->font_bold);
	if (u->font_body)
		pango_font_description_free(u->font_body);
	if (u->font_small)
		pango_font_description_free(u->font_small);
	if (u->font_status)
		pango_font_description_free(u->font_status);
	if (u->cr)
		cairo_destroy(u->cr);
	if (u->surf)
		cairo_surface_destroy(u->surf);
	if (u->tex)
		SDL_DestroyTexture(u->tex);

	u->surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, u->sw, u->sh);
	u->cr = cairo_create(u->surf);
	u->tex = SDL_CreateTexture(u->ren, SDL_PIXELFORMAT_ARGB8888,
				   SDL_TEXTUREACCESS_STREAMING, u->sw, u->sh);
	if (!u->surf || !u->cr || !u->tex) {
		fprintf(stderr, "cpz-ui: cannot create the render surface\n");
		exit(1);
	}
	cairo_scale(u->cr, (double)u->sw / UI_W, (double)u->sh / UI_H);
	SDL_SetTextureBlendMode(u->tex, SDL_BLENDMODE_NONE);
	cairo_set_antialias(u->cr, CAIRO_ANTIALIAS_BEST);
	cairo_set_line_join(u->cr, CAIRO_LINE_JOIN_ROUND);
	cairo_set_line_cap(u->cr, CAIRO_LINE_CAP_ROUND);

	u->layout = pango_cairo_create_layout(u->cr);
	pango_cairo_context_set_resolution(pango_layout_get_context(u->layout),
					   72.0);
	u->font_reg = pango_font_description_new();
	pango_font_description_set_family(u->font_reg, "Noto Sans");
	pango_font_description_set_absolute_size(u->font_reg, 15 * PANGO_SCALE);
	u->font_bold = pango_font_description_new();
	pango_font_description_set_family(u->font_bold, "Noto Sans");
	pango_font_description_set_weight(u->font_bold, PANGO_WEIGHT_BOLD);
	pango_font_description_set_absolute_size(u->font_bold, 15 * PANGO_SCALE);
	u->font_body = pango_font_description_new();
	pango_font_description_set_family(u->font_body, "Noto Sans");
	pango_font_description_set_absolute_size(u->font_body, 14 * PANGO_SCALE);
	u->font_small = pango_font_description_new();
	pango_font_description_set_family(u->font_small, "Noto Sans");
	pango_font_description_set_weight(u->font_small, PANGO_WEIGHT_BOLD);
	pango_font_description_set_absolute_size(u->font_small, 10 * PANGO_SCALE);
	u->font_status = pango_font_description_new();
	pango_font_description_set_family(u->font_status, "Noto Sans");
	pango_font_description_set_absolute_size(u->font_status, 11 * PANGO_SCALE);
	u->line_reg = measure_line(u, u->font_reg);
	u->line_bold = measure_line(u, u->font_bold);
	u->line_small = measure_line(u, u->font_small);
	u->line_status = measure_line(u, u->font_status);
}

static int bar_height(struct ui *u)
{
	(void)u;
	return 24;
}

static int row_height(struct ui *u)
{
	(void)u;
	return 28;
}

static int visible_rows(struct ui *u)
{
	int avail = u->h - bar_height(u);
	int rh = row_height(u);

	return avail > rh ? avail / rh : 1;
}

static int ui_inset(struct ui *u)
{
	(void)u;
	return 10;
}

static void clamp_scroll(struct ui *u)
{
	struct screen *s = cur_screen(u);
	int n = screen_item_count(u, s->parent);
	int vis = visible_rows(u);

	if (s->selected < 0)
		s->selected = 0;
	if (s->selected >= n)
		s->selected = n > 0 ? n - 1 : 0;
	if (s->selected < s->top)
		s->top = s->selected;
	if (s->selected >= s->top + vis)
		s->top = s->selected - vis + 1;
	if (s->top < 0)
		s->top = 0;
	if (s->top > n - vis)
		s->top = n - vis > 0 ? n - vis : 0;
}

/* ------------------------------------------------------------- glyphs */

/*
 * System glyphs only. Menu icons are owned by the apps themselves (a PNG in
 * the app bundle); what remains here is shell-owned chrome: status widgets
 * (wifi/ethernet/bluetooth/clock/media) and semantic marks for info, success
 * and warning pages. Keeping the two sets apart is why adding an app does not
 * mean editing cpz-ui.
 */
static void draw_chevron(struct ui *u, double x, double y, double size,
			 int dir, SDL_Color c)
{
	double w = (size + 1) / 2.0;
	double tip = dir < 0 ? x - w : x + w;

	cairo_new_path(u->cr);
	set_rgba(u->cr, c);
	cairo_set_line_width(u->cr, size >= 24 ? 2.8 : 2.0);
	cairo_move_to(u->cr, x, y);
	cairo_line_to(u->cr, tip, y + size / 2);
	cairo_line_to(u->cr, x, y + size);
	cairo_stroke(u->cr);
}

static void draw_glyph(struct ui *u, const char *name, double x, double y,
		       double size, SDL_Color c)
{
	double cx = x + size / 2, cy = y + size / 2;

	cairo_new_path(u->cr);
	set_rgba(u->cr, c);
	cairo_set_line_width(u->cr, size >= 20 ? 2.2 : 1.6);

	if (!name)
		name = "dot";
	if (!strcmp(name, "wifi")) {
		cairo_arc(u->cr, cx, cy + size * 0.22, size * 0.42,
			  -PI * 0.78, -PI * 0.22);
		cairo_stroke(u->cr);
		cairo_arc(u->cr, cx, cy + size * 0.22, size * 0.24,
			  -PI * 0.78, -PI * 0.22);
		cairo_stroke(u->cr);
		cairo_arc(u->cr, cx, cy + size * 0.22, size * 0.07, 0, 2 * PI);
		cairo_fill(u->cr);
	} else if (!strcmp(name, "ethernet")) {
		double w = size * 0.62, h = size * 0.44;
		double x1 = cx - w / 2, y1 = cy - h / 2;

		cairo_rectangle(u->cr, x1, y1, w, h);
		cairo_stroke(u->cr);
		for (int i = 0; i < 3; i++) {
			double bx = x1 + w * (0.22 + i * 0.28);
			cairo_move_to(u->cr, bx, y1 + h);
			cairo_line_to(u->cr, bx, y1 + h + size * 0.18);
			cairo_stroke(u->cr);
		}
	} else if (!strcmp(name, "bluetooth")) {
		cairo_move_to(u->cr, cx, cy - size * 0.40);
		cairo_line_to(u->cr, cx + size * 0.24, cy - size * 0.18);
		cairo_line_to(u->cr, cx - size * 0.20, cy + size * 0.10);
		cairo_line_to(u->cr, cx + size * 0.24, cy + size * 0.30);
		cairo_line_to(u->cr, cx, cy + size * 0.46);
		cairo_stroke(u->cr);
	} else if (!strcmp(name, "play")) {
		cairo_move_to(u->cr, cx - size * 0.22, cy - size * 0.30);
		cairo_line_to(u->cr, cx + size * 0.30, cy);
		cairo_line_to(u->cr, cx - size * 0.22, cy + size * 0.30);
		cairo_close_path(u->cr);
		cairo_fill(u->cr);
	} else if (!strcmp(name, "pause")) {
		cairo_rectangle(u->cr, cx - size * 0.24, cy - size * 0.28,
				size * 0.15, size * 0.56);
		cairo_fill(u->cr);
		cairo_rectangle(u->cr, cx + size * 0.09, cy - size * 0.28,
				size * 0.15, size * 0.56);
		cairo_fill(u->cr);
	} else if (!strcmp(name, "volume")) {
		cairo_move_to(u->cr, cx - size * 0.34, cy - size * 0.16);
		cairo_line_to(u->cr, cx - size * 0.12, cy - size * 0.16);
		cairo_line_to(u->cr, cx + size * 0.10, cy - size * 0.36);
		cairo_line_to(u->cr, cx + size * 0.10, cy + size * 0.36);
		cairo_line_to(u->cr, cx - size * 0.12, cy + size * 0.16);
		cairo_line_to(u->cr, cx - size * 0.34, cy + size * 0.16);
		cairo_close_path(u->cr);
		cairo_fill(u->cr);
		cairo_arc(u->cr, cx + size * 0.14, cy, size * 0.24,
			  -PI * 0.30, PI * 0.30);
		cairo_stroke(u->cr);
	} else if (!strcmp(name, "clock")) {
		cairo_arc(u->cr, cx, cy, size * 0.40, 0, 2 * PI);
		cairo_stroke(u->cr);
		cairo_move_to(u->cr, cx, cy);
		cairo_line_to(u->cr, cx, cy - size * 0.22);
		cairo_move_to(u->cr, cx, cy);
		cairo_line_to(u->cr, cx + size * 0.16, cy + size * 0.10);
		cairo_stroke(u->cr);
	} else if (!strcmp(name, "info")) {
		cairo_arc(u->cr, cx, cy, size * 0.40, 0, 2 * PI);
		cairo_stroke(u->cr);
		cairo_arc(u->cr, cx, cy - size * 0.18, size * 0.045, 0, 2 * PI);
		cairo_fill(u->cr);
		cairo_move_to(u->cr, cx, cy - size * 0.02);
		cairo_line_to(u->cr, cx, cy + size * 0.22);
		cairo_set_line_width(u->cr, size * 0.09);
		cairo_stroke(u->cr);
	} else if (!strcmp(name, "success")) {
		cairo_arc(u->cr, cx, cy, size * 0.40, 0, 2 * PI);
		cairo_stroke(u->cr);
		cairo_move_to(u->cr, cx - size * 0.20, cy);
		cairo_line_to(u->cr, cx - size * 0.04, cy + size * 0.16);
		cairo_line_to(u->cr, cx + size * 0.22, cy - size * 0.18);
		cairo_set_line_width(u->cr, size * 0.10);
		cairo_stroke(u->cr);
	} else if (!strcmp(name, "warning")) {
		cairo_move_to(u->cr, cx, cy - size * 0.38);
		cairo_line_to(u->cr, cx + size * 0.42, cy + size * 0.32);
		cairo_line_to(u->cr, cx - size * 0.42, cy + size * 0.32);
		cairo_close_path(u->cr);
		cairo_stroke(u->cr);
		cairo_move_to(u->cr, cx, cy - size * 0.12);
		cairo_line_to(u->cr, cx, cy + size * 0.08);
		cairo_stroke(u->cr);
		cairo_arc(u->cr, cx, cy + size * 0.22, size * 0.04, 0, 2 * PI);
		cairo_fill(u->cr);
	} else {
		cairo_arc(u->cr, cx, cy, size * 0.16, 0, 2 * PI);
		cairo_fill(u->cr);
	}
}

static void draw_icon(struct ui *u, const char *icon, double x, double y,
		      double size, SDL_Color c)
{
	if (!icon) {
		draw_glyph(u, "dot", x, y, size, c);
		return;
	}
	if (!strncmp(icon, "builtin:", 8)) {
		draw_glyph(u, icon + 8, x, y, size, c);
		return;
	}
	if (!strncmp(icon, "png:", 4)) {
		cairo_surface_t *surf = icon_get(u, icon + 4);

		if (!surf) {
			icon_request(u, icon + 4);
			round_rect_path(u->cr, x, y, size, size, 3);
			set_rgba(u->cr, (SDL_Color){ 225, 225, 225, 255 });
			cairo_fill(u->cr);
			return;
		}
		cairo_save(u->cr);
		cairo_translate(u->cr, x, y);
		double iw = cairo_image_surface_get_width(surf);

		if (iw > 0)
			cairo_scale(u->cr, size / iw, size / iw);
		/* App artwork is an alpha mask: tint it with the row colour so
		 * the same PNG stays legible on white and on the azure bar. */
		cairo_pattern_t *pat = cairo_pattern_create_for_surface(surf);

		cairo_pattern_set_filter(pat, CAIRO_FILTER_GOOD);
		set_rgba(u->cr, c);
		cairo_mask(u->cr, pat);
		cairo_pattern_destroy(pat);
		cairo_restore(u->cr);
		return;
	}
	/* A bare icon name is treated as a builtin. */
	draw_glyph(u, icon, x, y, size, c);
}

/* ---------------------------------------------------------- status widgets */

static double widget_width(struct ui *u, const struct ui_widget *w, double h)
{
	if (!w->kind)
		return 0;
	if (!strcmp(w->kind, "battery"))
		return h * 2.15;
	if (!strcmp(w->kind, "glyph") || !strcmp(w->kind, "png"))
		return h;
	if (!strcmp(w->kind, "text") || !strcmp(w->kind, "clock"))
		return text_width_font(u, u->font_status,
				       w->text ? w->text : "");
	return h;
}

static void draw_widget(struct ui *u, const struct ui_widget *w, double x,
			double y, double h)
{
	if (!w->kind)
		return;
	if (!strcmp(w->kind, "battery")) {
		SDL_Color edge = { 70, 70, 70, 255 };
		SDL_Color empty_top = { 248, 248, 248, 255 };
		SDL_Color empty_bot = { 220, 220, 220, 255 };
		SDL_Color nub_edge = { 82, 82, 82, 255 };
		SDL_Color nub_fill = { 152, 152, 152, 255 };
		SDL_Color gtop = { 224, 246, 212, 255 };
		SDL_Color gmid = { 110, 213, 78, 255 };
		SDL_Color gbot = { 22, 164, 44, 255 };
		SDL_Color rtop = { 246, 176, 168, 255 };
		SDL_Color rbot = { 188, 36, 36, 255 };
		double bw = h * 2.15;
		double r = 3.0;
		double inx = x + 1.5, iny = y + 1.5, inw = bw - 3, inh = h - 3;
		int level = w->level;
		int low = level <= 10;
		double fw = inw * level / 100.0;
		cairo_pattern_t *p;

		round_rect_path(u->cr, x + bw - 1, y + h * 0.29, 3.2,
				h * 0.42, 1.1);
		set_rgba(u->cr, nub_edge);
		cairo_fill(u->cr);
		round_rect_path(u->cr, x + bw - 0.6, y + h * 0.29 + 0.9,
				2.0, h * 0.42 - 1.8, 0.7);
		set_rgba(u->cr, nub_fill);
		cairo_fill(u->cr);
		round_rect_path(u->cr, x, y, bw, h, r);
		set_rgba(u->cr, edge);
		cairo_fill(u->cr);
		round_rect_path(u->cr, inx, iny, inw, inh, r - 1.2);
		p = cairo_pattern_create_linear(0, iny, 0, iny + inh);
		cairo_pattern_add_color_stop_rgba(p, 0, empty_top.r / 255.0,
						  empty_top.g / 255.0,
						  empty_top.b / 255.0, 1);
		cairo_pattern_add_color_stop_rgba(p, 1, empty_bot.r / 255.0,
						  empty_bot.g / 255.0,
						  empty_bot.b / 255.0, 1);
		cairo_set_source(u->cr, p);
		cairo_fill(u->cr);
		cairo_pattern_destroy(p);
		if (level > 0) {
			cairo_save(u->cr);
			round_rect_path(u->cr, inx, iny, inw, inh, r - 1.2);
			cairo_clip(u->cr);
			p = cairo_pattern_create_linear(0, iny, 0, iny + inh);
			if (low) {
				cairo_pattern_add_color_stop_rgba(p, 0,
					rtop.r / 255.0, rtop.g / 255.0,
					rtop.b / 255.0, 1);
				cairo_pattern_add_color_stop_rgba(p, 1,
					rbot.r / 255.0, rbot.g / 255.0,
					rbot.b / 255.0, 1);
			} else {
				cairo_pattern_add_color_stop_rgba(p, 0,
					gtop.r / 255.0, gtop.g / 255.0,
					gtop.b / 255.0, 1);
				cairo_pattern_add_color_stop_rgba(p, 0.35,
					gmid.r / 255.0, gmid.g / 255.0,
					gmid.b / 255.0, 1);
				cairo_pattern_add_color_stop_rgba(p, 1,
					gbot.r / 255.0, gbot.g / 255.0,
					gbot.b / 255.0, 1);
			}
			cairo_set_source(u->cr, p);
			cairo_rectangle(u->cr, inx, iny, fw, inh);
			cairo_fill(u->cr);
			cairo_pattern_destroy(p);
			cairo_set_source_rgba(u->cr, 1, 1, 1, 0.55);
			cairo_rectangle(u->cr, inx, iny, fw, 1.2);
			cairo_fill(u->cr);
			cairo_restore(u->cr);
		}
		if (w->charging) {
			set_rgba(u->cr, (SDL_Color){ 30, 80, 200, 255 });
			cairo_move_to(u->cr, x + bw * 0.56, y + h * 0.16);
			cairo_line_to(u->cr, x + bw * 0.38, y + h * 0.52);
			cairo_line_to(u->cr, x + bw * 0.55, y + h * 0.52);
			cairo_line_to(u->cr, x + bw * 0.42, y + h * 0.84);
			cairo_line_to(u->cr, x + bw * 0.70, y + h * 0.42);
			cairo_line_to(u->cr, x + bw * 0.53, y + h * 0.42);
			cairo_close_path(u->cr);
			cairo_fill(u->cr);
		}
	} else if (!strcmp(w->kind, "glyph")) {
		draw_glyph(u, w->name, x, y, h, (SDL_Color){ 55, 55, 55, 255 });
	} else if (!strcmp(w->kind, "png")) {
		char ic[32];

		snprintf(ic, sizeof(ic), "png:%s", w->hash ? w->hash : "");
		draw_icon(u, ic, x, y, h, (SDL_Color){ 55, 55, 55, 255 });
	} else if (!strcmp(w->kind, "text") || !strcmp(w->kind, "clock")) {
		const char *text = w->text ? w->text : "";
		int th = u->line_status;

		text_show_ellipsized(u, u->font_status, text,
				     (int)x,
				     (int)(y + (h - th) / 2.0),
				     (int)h * 6, (SDL_Color){ 55, 55, 55, 255 },
				     PANGO_ALIGN_LEFT);
	}
}

/*
 * Lay out at most three widgets in the right cluster. A system battery is
 * always rightmost. Non-battery widgets are chosen by priority, then drawn in
 * order/id order. Returns the left edge of the cluster.
 */
static double draw_status_cluster(struct ui *u, double y, double h)
{
	int idx[MAX_ITEMS];
	int nidx = 0;
	int battery = -1;
	int chosen[MAX_ITEMS];
	int nchosen = 0;
	double total = 0;
	double x;
	int inset = ui_inset(u);
	int maxw = u->w - inset - 96;

	for (int i = 0; i < u->snap.nwidgets; i++) {
		struct ui_widget *w = &u->snap.widgets[i];

		if (!w->kind)
			continue;
		if (!strcmp(w->kind, "battery")) {
			if (battery < 0 || (w->system &&
					    !u->snap.widgets[battery].system))
				battery = i;
		} else {
			idx[nidx++] = i;
		}
	}
	/* Select non-battery widgets by priority (desc), then order/id. */
	for (int a = 1; a < nidx; a++) {
		int v = idx[a];
		int b = a - 1;

		while (b >= 0) {
			struct ui_widget *wa = &u->snap.widgets[v];
			struct ui_widget *wb = &u->snap.widgets[idx[b]];
			int before = wa->priority > wb->priority ||
				     (wa->priority == wb->priority &&
				      (wa->order < wb->order ||
				       (wa->order == wb->order &&
					strcmp(wa->id ? wa->id : "",
					       wb->id ? wb->id : "") < 0)));

			if (!before)
				break;
			idx[b + 1] = idx[b];
			b--;
		}
		idx[b + 1] = v;
	}
	int max_other = battery >= 0 ? 2 : 3;

	for (int i = 0; i < nidx && nchosen < max_other; i++)
		chosen[nchosen++] = idx[i];
	if (battery >= 0)
		chosen[nchosen++] = battery;

	/* Drop the lowest priority item while the cluster is too wide. */
	for (;;) {
		total = 0;
		for (int i = 0; i < nchosen; i++)
			total += widget_width(u, &u->snap.widgets[chosen[i]], h);
		total += (nchosen > 1) * 2.0 * (nchosen - 1);
		if (total <= maxw || nchosen <= 1)
			break;
		/* chosen[] is priority-ordered, with battery appended last. */
		if (battery >= 0 && nchosen > 1) {
			int drop = -1;
			int worst = 1 << 30;

			for (int i = 0; i < nchosen; i++) {
				struct ui_widget *w =
					&u->snap.widgets[chosen[i]];
				int pri = !strcmp(w->kind, "battery") ?
					  1000 : w->priority;

				if (pri < worst) {
					worst = pri;
					drop = i;
				}
			}
			if (drop >= 0) {
				for (int i = drop; i + 1 < nchosen; i++)
					chosen[i] = chosen[i + 1];
				nchosen--;
			} else {
				break;
			}
		} else {
			nchosen--;
		}
	}

	/* Draw in order/id order, battery last (rightmost). */
	for (int a = 0; a < nchosen; a++) {
		for (int b = a + 1; b < nchosen; b++) {
			struct ui_widget *wa = &u->snap.widgets[chosen[a]];
			struct ui_widget *wb = &u->snap.widgets[chosen[b]];
			int ba = !strcmp(wa->kind, "battery");
			int bb = !strcmp(wb->kind, "battery");
			int before;

			if (ba != bb)
				before = ba && !bb;
			else
				before = wb->order < wa->order ||
					 (wb->order == wa->order &&
					  strcmp(wb->id ? wb->id : "",
						 wa->id ? wa->id : "") < 0);
			if (before) {
				int tmp = chosen[a];

				chosen[a] = chosen[b];
				chosen[b] = tmp;
			}
		}
	}

	x = u->w - inset - total;
	for (int i = 0; i < nchosen; i++) {
		struct ui_widget *w = &u->snap.widgets[chosen[i]];
		double ww = widget_width(u, w, h);

		draw_widget(u, w, x, y, h);
		x += ww + 2;
	}
	return u->w - inset - total;
}

static void draw_bar(struct ui *u, const char *title, int back)
{
	int bh = bar_height(u);
	int th = u->line_bold;
	int ty = (bh - th) / 2;
	int inset = ui_inset(u);
	int text_x = inset + ICON_GUTTER;
	double cluster_left;

	fill_vgradient(u->cr, 0, 0, u->w, bh, col_bar_top, col_bar_bot);
	set_rgba(u->cr, col_bar_line);
	cairo_rectangle(u->cr, 0, bh - 1, u->w, 1);
	cairo_fill(u->cr);

	if (back) {
		int cs = u->line_reg - 6;
		double cw;

		if (cs < 6)
			cs = 6;
		/* The back chevron owns the icon slot; the title keeps the
		 * text column it shares with every menu label. */
		cw = (cs + 1) / 2.0;
		draw_chevron(u, inset + ICON_SLOT / 2.0 + cw / 2.0,
			     (bh - cs) / 2.0, cs, -1, col_text);
	}
	cluster_left = draw_status_cluster(u, (bh - (bh / 2 + 4)) / 2,
					  bh / 2 + 4);
	if (u->snap.nwidgets == 0)
		cluster_left = u->w - inset;
	int avail = (int)cluster_left - 6 - text_x;
	text_show_ellipsized(u, u->font_bold, title ? title : "",
			     text_x, ty, avail < 1 ? 1 : avail, col_text,
			     PANGO_ALIGN_LEFT);
}

static void draw_scrollbar(struct ui *u, double x1, int vis)
{
	struct screen *s = cur_screen(u);
	int total = screen_item_count(u, s->parent);
	int top = bar_height(u);
	int h = u->h - top;
	double w = 6;
	double x, track_h, thumb_h, thumb_y;

	if (total <= vis || h <= 8)
		return;
	track_h = h - 4;
	x = x1 - w - 3;
	round_rect_path(u->cr, x, top + 2, w, track_h, w / 2);
	set_rgba(u->cr, (SDL_Color){ 236, 236, 236, 255 });
	cairo_fill(u->cr);
	thumb_h = track_h * vis / total;
	if (thumb_h < w * 4)
		thumb_h = w * 4;
	if (thumb_h > track_h)
		thumb_h = track_h;
	int range = total - vis;
	thumb_y = top + 2 + (track_h - thumb_h) * s->top /
		(range > 0 ? range : 1);
	round_rect_path(u->cr, x, thumb_y, w, thumb_h, w / 2);
	set_rgba(u->cr, (SDL_Color){ 150, 150, 150, 255 });
	cairo_fill(u->cr);
}

static void draw_rows(struct ui *u, int x0, int x1)
{
	struct screen *s = cur_screen(u);
	int count = screen_item_count(u, s->parent);
	int rh = row_height(u);
	int vis = visible_rows(u);
	int lh = u->line_bold;
	int inset = ui_inset(u);
	int top = bar_height(u);
	int sb = count > vis;
	double right = x1 - inset - (sb ? 6 : 0);

	for (int i = s->top; i < count && i < s->top + vis; i++) {
		struct ui_item *it = screen_item(u, s->parent, i);
		double y = top + (i - s->top) * rh;
		int sel = i == s->selected;
		double ty = y + (rh - lh) / 2.0;
		int has_icon = it->icon != NULL && it->icon[0];
		int label_x = x0 + inset + ICON_GUTTER;
		SDL_Color fg = sel ? col_white : col_text;

		if (!it->enabled && !sel)
			fg = col_muted;
		if (sel) {
			fill_vgradient(u->cr, x0, y, x1 - x0, rh,
				       col_sel_top, col_sel_bot);
			set_rgba(u->cr, col_sel_rim);
			cairo_rectangle(u->cr, x0, y, x1 - x0, 1);
			cairo_fill(u->cr);
			set_rgba(u->cr, col_sel_edge);
			cairo_rectangle(u->cr, x0, y + rh - 1, x1 - x0, 1);
			cairo_fill(u->cr);
		}
		if (has_icon)
			draw_icon(u, it->icon, x0 + inset,
				  y + (rh - ICON_SLOT) / 2.0, ICON_SLOT, fg);
		text_show_ellipsized(u, u->font_bold,
				     it->label ? it->label : it->id,
				     label_x, (int)ty,
				     (int)(right - label_x -
					   (it->badge ? 26 : 22)),
				     fg, PANGO_ALIGN_LEFT);
		if (it->badge && *it->badge) {
			int bw = text_width_font(u, u->font_small, it->badge) + 8;

			if (bw < 16)
				bw = 16;
			double bx = right - bw - 8;
			double by = y + (rh - 16) / 2.0;

			round_rect_path(u->cr, bx, by, bw, 16, 8);
			if (sel)
				set_rgba(u->cr, (SDL_Color){ 255, 255, 255, 255 });
			else
				set_rgba(u->cr, (SDL_Color){ 60, 120, 200, 255 });
			cairo_fill(u->cr);
			int tw = text_width_font(u, u->font_small, it->badge);
			text_show_ellipsized(u, u->font_small, it->badge,
					     (int)(bx + (bw - tw) / 2.0),
					     (int)(by + 2), bw - 2,
					     sel ? col_sel_rim : col_white,
					     PANGO_ALIGN_CENTER);
		}
		if (item_has_children(u, it->id) ||
		    it->act.kind == UA_CHOICE) {
			int cs = u->line_reg - 6;

			if (cs < 6)
				cs = 6;
			draw_chevron(u, right - (cs + 1) / 2.0,
				     ty + (lh - cs) / 2.0, cs, 1, fg);
		}
	}
	draw_scrollbar(u, x1, vis);
}

static void draw_content(struct ui *u)
{
	cairo_save(u->cr);
	set_rgba(u->cr, col_white);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_fill(u->cr);
	cairo_restore(u->cr);
	draw_rows(u, 0, u->w);
}

/* -------------------------------------------------------------- icons */

/* Filled triangular arrow head pointing along `angle`. */
static void arrow_head(cairo_t *cr, double x, double y, double angle,
		       double len, double wid)
{
	double ca = cos(angle), sa = sin(angle);
	double px = -sa, py = ca;

	cairo_move_to(cr, x + ca * len, y + sa * len);
	cairo_line_to(cr, x + px * wid, y + py * wid);
	cairo_line_to(cr, x - px * wid, y - py * wid);
	cairo_close_path(cr);
	cairo_fill(cr);
}

static void draw_sync_icon(struct ui *u, double cx, double cy, double r,
			   uint64_t now)
{
	double ang = (now % 1400) * 2 * PI / 1400.0;
	double lw = r / 8.0;
	double a0 = -PI * 0.30, a1 = PI * 0.42;
	double b0 = PI * 0.70, b1 = PI * 1.42;

	cairo_save(u->cr);
	cairo_translate(u->cr, cx, cy);
	cairo_rotate(u->cr, ang);
	cairo_new_path(u->cr);
	set_rgba(u->cr, col_text);
	cairo_set_line_width(u->cr, lw < 2.5 ? 2.5 : lw);
	cairo_set_line_cap(u->cr, CAIRO_LINE_CAP_ROUND);
	cairo_arc(u->cr, 0, 0, r, a0, a1);
	cairo_stroke(u->cr);
	cairo_arc(u->cr, 0, 0, r, b0, b1);
	cairo_stroke(u->cr);
	arrow_head(u->cr, r * cos(a1), r * sin(a1), a1 + PI / 2,
		   r * 0.30, r * 0.16);
	arrow_head(u->cr, r * cos(b1), r * sin(b1), b1 + PI / 2,
		   r * 0.30, r * 0.16);
	cairo_restore(u->cr);
}

static void draw_warning_icon(struct ui *u, double cx, double cy, double size)
{
	SDL_Color edge = { 140, 100, 0, 255 };
	SDL_Color mark = { 82, 56, 0, 255 };
	double half = size / 2, wing = size * 0.58;
	cairo_pattern_t *p;

	cairo_save(u->cr);
	cairo_translate(u->cr, 2, 3);
	cairo_new_path(u->cr);
	cairo_move_to(u->cr, cx, cy - half);
	cairo_line_to(u->cr, cx + wing, cy + half);
	cairo_line_to(u->cr, cx - wing, cy + half);
	cairo_close_path(u->cr);
	cairo_set_source_rgba(u->cr, 0, 0, 0, 0.16);
	cairo_fill(u->cr);
	cairo_restore(u->cr);

	cairo_new_path(u->cr);
	cairo_move_to(u->cr, cx, cy - half);
	cairo_line_to(u->cr, cx + wing, cy + half);
	cairo_line_to(u->cr, cx - wing, cy + half);
	cairo_close_path(u->cr);
	p = cairo_pattern_create_linear(0, cy - half, 0, cy + half);
	cairo_pattern_add_color_stop_rgb(p, 0, 1.00, 0.89, 0.47);
	cairo_pattern_add_color_stop_rgb(p, 1, 0.89, 0.66, 0.12);
	cairo_set_source(u->cr, p);
	cairo_fill_preserve(u->cr);
	cairo_pattern_destroy(p);
	set_rgba(u->cr, edge);
	cairo_set_line_width(u->cr, 2.2);
	cairo_set_line_join(u->cr, CAIRO_LINE_JOIN_ROUND);
	cairo_stroke(u->cr);
	set_rgba(u->cr, mark);
	cairo_set_line_width(u->cr, size * 0.12);
	cairo_set_line_cap(u->cr, CAIRO_LINE_CAP_ROUND);
	cairo_move_to(u->cr, cx, cy - half * 0.22);
	cairo_line_to(u->cr, cx, cy + half * 0.20);
	cairo_stroke(u->cr);
	cairo_arc(u->cr, cx, cy + half * 0.46, size * 0.06, 0, 2 * PI);
	cairo_fill(u->cr);
}

/* --------------------------------------------------------------- pages */

static void draw_info(struct ui *u, struct page *p)
{
	SDL_Color fg = col_text;
	double y = bar_height(u) + 4;
	const char *sev = p->severity[0] ? p->severity : "info";
	double icon_size = 40;

	draw_bar(u, p->title, 0);
	set_rgba(u->cr, col_white);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_fill(u->cr);

	if (p->icon[0])
		draw_icon(u, p->icon, (u->w - icon_size) / 2.0, y, icon_size,
			  fg);
	else
		draw_glyph(u, sev, (u->w - icon_size) / 2.0, y, icon_size, fg);
	y += icon_size + 4;

	text_set(u, u->font_body, p->text, u->w - 40, PANGO_ALIGN_CENTER);
	pango_layout_set_height(u->layout,
				(u->h - 10 - (int)y) * PANGO_SCALE);
	pango_layout_set_ellipsize(u->layout, PANGO_ELLIPSIZE_END);
	text_show(u, 20, (int)y, fg);
}

static void draw_error(struct ui *u, struct page *p)
{
	double y = bar_height(u) + (u->h - bar_height(u)) / 2.0;

	draw_bar(u, p->title, 0);
	set_rgba(u->cr, col_white);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_fill(u->cr);
	draw_warning_icon(u, u->w / 2.0, y - 38, 50);
	text_set(u, u->font_bold, p->text, 280, PANGO_ALIGN_CENTER);
	pango_layout_set_height(u->layout,
				(u->h - 10 - (int)(y + 2)) * PANGO_SCALE);
	pango_layout_set_ellipsize(u->layout, PANGO_ELLIPSIZE_END);
	text_show(u, 20, (int)(y + 2), col_text);
}

static void draw_confirm(struct ui *u, struct page *p)
{
	int rh = row_height(u);
	int top;
	const char *opts[2] = { "Ні", "Так" };
	int nh;

	draw_bar(u, p->title, 0);
	set_rgba(u->cr, col_white);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_fill(u->cr);
	text_set(u, u->font_bold, p->text, u->w - 32, PANGO_ALIGN_CENTER);
	pango_layout_get_pixel_size(u->layout, NULL, &nh);
	text_show(u, 16, bar_height(u) + 8, col_text);
	top = bar_height(u) + 8 + nh + 12;
	for (int i = 0; i < 2; i++) {
		double y = top + i * rh;
		double ty = y + (rh - u->line_bold) / 2.0;
		int sel = p->selected == i;

		if (sel) {
			fill_vgradient(u->cr, 0, y, u->w, rh, col_sel_top,
				       col_sel_bot);
			set_rgba(u->cr, col_sel_rim);
			cairo_rectangle(u->cr, 0, y, u->w, 1);
			cairo_fill(u->cr);
		}
		text_show_ellipsized(u, u->font_bold, opts[i],
				     ui_inset(u), (int)ty, u->w - 16,
				     sel ? col_white : col_text,
				     PANGO_ALIGN_LEFT);
	}
}

static void draw_choice(struct ui *u, struct page *p)
{
	int rh = row_height(u);
	int vis = (u->h - bar_height(u)) / rh;

	if (vis < 1)
		vis = 1;

	draw_bar(u, p->title, 1);
	set_rgba(u->cr, col_white);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_fill(u->cr);
	int top = p->selected >= vis ? p->selected - vis + 1 : 0;

	for (int i = top; i < p->nchoices && i < top + vis; i++) {
		double y = bar_height(u) + (i - top) * rh;
		double ty = y + (rh - u->line_bold) / 2.0;
		int sel = i == p->selected;
		int has_icon = p->choices[i].icon != NULL &&
			       p->choices[i].icon[0];
		int lx = ui_inset(u) + ICON_GUTTER;

		if (sel) {
			fill_vgradient(u->cr, 0, y, u->w, rh, col_sel_top,
				       col_sel_bot);
			set_rgba(u->cr, col_sel_rim);
			cairo_rectangle(u->cr, 0, y, u->w, 1);
			cairo_fill(u->cr);
		}
		if (has_icon)
			draw_icon(u, p->choices[i].icon, ui_inset(u),
				  y + (rh - ICON_SLOT) / 2.0, ICON_SLOT,
				  sel ? col_white : col_text);
		text_show_ellipsized(u, u->font_bold,
				     p->choices[i].label ?
				     p->choices[i].label : "",
				     lx, (int)ty, u->w - lx - 8,
				     sel ? col_white : col_text,
				     PANGO_ALIGN_LEFT);
	}
}

static void draw_input(struct ui *u, struct page *p)
{
	double y = bar_height(u) + 24;

	draw_bar(u, p->title, 0);
	set_rgba(u->cr, col_white);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_fill(u->cr);
	round_rect_path(u->cr, 16, y, u->w - 32, 30, 4);
	set_rgba(u->cr, (SDL_Color){ 245, 245, 245, 255 });
	cairo_fill_preserve(u->cr);
	set_rgba(u->cr, (SDL_Color){ 150, 150, 150, 255 });
	cairo_set_line_width(u->cr, 1);
	cairo_stroke(u->cr);
	text_show_ellipsized(u, u->font_bold, p->input, 24, (int)y + 7,
			     u->w - 48, col_text, PANGO_ALIGN_LEFT);
}

static void draw_busy(struct ui *u)
{
	const char *wait = "Зачекайте…";
	double y = bar_height(u) + (u->h - bar_height(u)) / 2.0;
	int tw, ww;

	draw_bar(u, u->ov_title, 0);
	set_rgba(u->cr, col_white);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_fill(u->cr);
	draw_sync_icon(u, u->w / 2.0, y - 38, 30, now_ms());
	tw = text_width(u, 1, u->ov_text);
	text_show_ellipsized(u, u->font_bold, u->ov_text,
			     (u->w - tw) / 2, (int)y + 4, u->w - 16,
			     col_text, PANGO_ALIGN_LEFT);
	size_t len = strlen(u->ov_text);
	if (u->overlay == OV_LOADING ||
	    (len < 3 || strcmp(u->ov_text + len - 3, "…") != 0)) {
		ww = text_width(u, 0, wait);
		text_show_ellipsized(u, u->font_reg, wait,
				     (u->w - ww) / 2, (int)y + 24,
				     u->w - 16, col_muted, PANGO_ALIGN_LEFT);
	}
}

static void draw_progress(struct ui *u)
{
	double y = bar_height(u) + (u->h - bar_height(u)) / 2.0;
	char pct[16];
	int tw;

	draw_bar(u, u->ov_title, 0);
	set_rgba(u->cr, col_white);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_fill(u->cr);
	snprintf(pct, sizeof(pct), "%d%%", u->progress);
	tw = text_width(u, 1, pct);
	text_show_ellipsized(u, u->font_bold, pct, (u->w - tw) / 2,
			     (int)y - 8, u->w - 16, col_text,
			     PANGO_ALIGN_LEFT);
	round_rect_path(u->cr, 30, y + 16, u->w - 60, 10, 5);
	set_rgba(u->cr, (SDL_Color){ 225, 225, 225, 255 });
	cairo_fill(u->cr);
	double fw = (u->w - 60) * u->progress / 100.0;

	if (fw > 0) {
		round_rect_path(u->cr, 30, y + 16, fw, 10, 5);
		set_rgba(u->cr, (SDL_Color){ 60, 120, 200, 255 });
		cairo_fill(u->cr);
	}
}

static void draw_toast(struct ui *u)
{
	uint64_t now = now_ms();
	double bw, bh, x, y;
	int tw, th;
	SDL_Color edge = { 130, 130, 130, 255 };

	if (!u->toast[0] || now >= u->toast_until)
		return;
	if (u->toast_severity == 1)
		edge = (SDL_Color){ 60, 140, 70, 255 };
	else if (u->toast_severity == 2)
		edge = (SDL_Color){ 180, 120, 20, 255 };

	text_begin(u, 1, u->toast, 0, PANGO_ALIGN_LEFT);
	pango_layout_get_pixel_size(u->layout, &tw, &th);
	bw = tw + 24;
	if (bw < 120)
		bw = 120;
	if (bw > 300)
		bw = 300;
	text_begin(u, 1, u->toast, (int)(bw - 24), PANGO_ALIGN_CENTER);
	pango_layout_get_pixel_size(u->layout, &tw, &th);
	bh = th + 14;
	x = (u->w - bw) / 2.0;
	y = u->h - bh - 8;
	cairo_save(u->cr);
	round_rect_path(u->cr, x + 2, y + 2, bw, bh, 6);
	cairo_set_source_rgba(u->cr, 0, 0, 0, 0.18);
	cairo_fill(u->cr);
	cairo_restore(u->cr);
	round_rect_path(u->cr, x, y, bw, bh, 6);
	set_rgba(u->cr, col_white);
	cairo_fill_preserve(u->cr);
	set_rgba(u->cr, edge);
	cairo_set_line_width(u->cr, 1);
	cairo_stroke(u->cr);
	text_show(u, (int)x + 12, (int)y + 7, col_text);
}

static void draw_boot(struct ui *u)
{
	draw_bar(u, "Меню", 0);
	set_rgba(u->cr, col_white);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_fill(u->cr);
	text_show_ellipsized(u, u->font_reg, "Завантаження меню…",
			     16, u->h / 2, u->w - 32, col_muted,
			     PANGO_ALIGN_CENTER);
}

static void draw_empty(struct ui *u)
{
	draw_bar(u, "Меню", 0);
	set_rgba(u->cr, col_white);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_fill(u->cr);
	draw_glyph(u, "info", (u->w - 44) / 2.0, bar_height(u) + 16, 44,
		   (SDL_Color){ 90, 90, 90, 255 });
	text_show_ellipsized(u, u->font_bold, "Меню порожнє",
			     16, bar_height(u) + 70, u->w - 32, col_text,
			     PANGO_ALIGN_CENTER);
}

static void draw_base(struct ui *u)
{
	if (base_degraded(u) && !u->have_snapshot) {
		if (u->connected) {
			draw_boot(u);
			return;
		}
		draw_bar(u, "Меню (спрощене)", 0);
		set_rgba(u->cr, col_white);
		cairo_rectangle(u->cr, 0, bar_height(u), u->w,
				u->h - bar_height(u));
		cairo_fill(u->cr);
		draw_rows(u, 0, u->w);
		return;
	}
	if (base_empty(u)) {
		draw_empty(u);
		return;
	}
	draw_bar(u, screen_title(u), u->depth > 1);
	draw_content(u);
}

static void draw_page(struct ui *u, struct page *p)
{
	switch (p->kind) {
	case PG_INFO:
		draw_info(u, p);
		break;
	case PG_ERROR:
		draw_error(u, p);
		break;
	case PG_CONFIRM:
		draw_confirm(u, p);
		break;
	case PG_CHOICE:
		draw_choice(u, p);
		break;
	case PG_INPUT:
		draw_input(u, p);
		break;
	default:
		draw_base(u);
		break;
	}
}

static void present(struct ui *u)
{
	cairo_surface_flush(u->surf);
	SDL_UpdateTexture(u->tex, NULL, cairo_image_surface_get_data(u->surf),
			  cairo_image_surface_get_stride(u->surf));
	SDL_SetRenderDrawColor(u->ren, 14, 14, 18, 255);
	SDL_RenderClear(u->ren);
	SDL_RenderCopy(u->ren, u->tex, NULL, &u->dst);
	if (u->dst.w < u->out_w || u->dst.h < u->out_h) {
		SDL_SetRenderDrawColor(u->ren, 58, 58, 68, 255);
		SDL_RenderDrawRect(u->ren, &u->dst);
	}
	SDL_RenderPresent(u->ren);
}

static void draw_transition(struct ui *u)
{
	struct screen live[SCREEN_MAX];
	int live_depth = u->depth;
	int off_old, off_new;
	double t = (double)(now_ms() - u->trans.start) / (double)u->trans.ms;
	double p, e;

	if (t > 1.0)
		t = 1.0;
	p = 1.0 - t;
	e = 1.0 - p * p * p;
	if (u->trans.dir > 0) {
		off_old = -(int)(e * u->w);
		off_new = off_old + u->w;
	} else {
		off_old = (int)(e * u->w);
		off_new = off_old - u->w;
	}
	set_rgba(u->cr, col_white);
	cairo_rectangle(u->cr, 0, 0, u->w, u->h);
	cairo_fill(u->cr);
	draw_bar(u, screen_title(u), u->depth > 1);

	memcpy(live, u->stack, sizeof(live));
	memcpy(u->stack, u->trans.old_stack, sizeof(u->stack));
	u->depth = u->trans.old_depth;
	cairo_save(u->cr);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_clip(u->cr);
	cairo_translate(u->cr, off_old, 0);
	draw_content(u);
	cairo_restore(u->cr);
	memcpy(u->stack, live, sizeof(live));
	u->depth = live_depth;
	cairo_save(u->cr);
	cairo_rectangle(u->cr, 0, bar_height(u), u->w,
			u->h - bar_height(u));
	cairo_clip(u->cr);
	cairo_translate(u->cr, off_new, 0);
	draw_content(u);
	cairo_restore(u->cr);
}

static void redraw_now(struct ui *u)
{
	if (u->overlay == OV_LOADING || u->overlay == OV_BUSY) {
		draw_busy(u);
	} else if (u->overlay == OV_PROGRESS) {
		draw_progress(u);
	} else if (u->npages > 0) {
		draw_page(u, &u->pages[u->npages - 1]);
	} else {
		draw_base(u);
	}
	draw_toast(u);
	present(u);
	if (!u->first_frame) {
		u->first_frame = 1;
		fprintf(stderr, "cpz-ui: first frame %llu ms (%s, %s)\n",
			(unsigned long long)(now_ms() - u->t_start),
			SDL_GetCurrentVideoDriver(), renderer_name(u->ren));
	}
	u->last_draw = now_ms();
}

/* --------------------------------------------------------------- keys */

static void move_selection(struct ui *u, int delta)
{
	struct screen *s = cur_screen(u);
	int n = screen_item_count(u, s->parent);

	if (n <= 0)
		return;
	s->selected = (s->selected + delta + n) % n;
	struct ui_item *it = screen_item(u, s->parent, s->selected);

	if (it)
		snprintf(s->sel_id, sizeof(s->sel_id), "%s", it->id);
	clamp_scroll(u);
	u->dirty = 1;
}

static void handle_page_key(struct ui *u, SDL_Keycode k)
{
	struct page *p = &u->pages[u->npages - 1];

	if (p->kind == PG_INFO) {
		pop_page(u);
		return;
	}
	if (p->kind == PG_ERROR) {
		if ((k == SDLK_RETURN || k == SDLK_KP_ENTER) && p->has_pending) {
			struct uaction act;

			action_copy(&act, &p->pending);
			char label[96];

			snprintf(label, sizeof(label), "%s", p->icon);
			u->overlay = OV_NONE;
			pop_page(u);
			execute_action(u, &act, label);
			action_free(&act);
		} else {
			pop_page(u);
		}
		return;
	}
	if (p->kind == PG_CONFIRM) {
		if (k == SDLK_ESCAPE || k == SDLK_z || k == SDLK_LEFT ||
		    k == SDLK_BACKSPACE) {
			pop_page(u);
			return;
		}
		if (k == SDLK_f || k == SDLK_x || k == SDLK_UP || k == SDLK_DOWN) {
			p->selected = !p->selected;
			u->dirty = 1;
			return;
		}
		if (k == SDLK_c) {
			p->selected = 1;
			u->dirty = 1;
			/* fall through to activate */
		}
		if (k == SDLK_RETURN || k == SDLK_KP_ENTER || k == SDLK_c) {
			if (p->selected == 1 && p->has_pending) {
				struct uaction act;
				char label[96];

				action_copy(&act, &p->pending);
				snprintf(label, sizeof(label), "%s", p->icon);
				pop_page(u);
				execute_action(u, &act, label);
				action_free(&act);
			} else {
				pop_page(u);
			}
		}
		return;
	}
	if (p->kind == PG_CHOICE) {
		if (k == SDLK_ESCAPE || k == SDLK_z || k == SDLK_LEFT ||
		    k == SDLK_BACKSPACE) {
			pop_page(u);
			return;
		}
		if (k == SDLK_f || k == SDLK_UP) {
			if (p->nchoices > 0)
				p->selected = (p->selected + p->nchoices - 1) %
					      p->nchoices;
			u->dirty = 1;
			return;
		}
		if (k == SDLK_x || k == SDLK_DOWN) {
			if (p->nchoices > 0)
				p->selected = (p->selected + 1) % p->nchoices;
			u->dirty = 1;
			return;
		}
		if (k == SDLK_RETURN || k == SDLK_KP_ENTER || k == SDLK_c ||
		    k == SDLK_RIGHT) {
			if (p->selected >= 0 && p->selected < p->nchoices) {
				struct uchoice *c = &p->choices[p->selected];
				struct uaction act;

				memset(&act, 0, sizeof(act));
				act.kind = c->kind;
				act.argc = c->argc;
				for (int i = 0; i < c->argc; i++)
					act.argv[i] = xstrdup(c->argv[i]);
				char label[96];

				snprintf(label, sizeof(label), "%s",
					 c->label ? c->label : "");
				pop_page(u);
				execute_action(u, &act, label);
				action_free(&act);
			}
		}
		return;
	}
	if (p->kind == PG_INPUT) {
		if (k == SDLK_ESCAPE) {
			pop_page(u);
			return;
		}
		if (k == SDLK_BACKSPACE) {
			if (p->input_len > 0)
				p->input[--p->input_len] = '\0';
			u->dirty = 1;
			return;
		}
		if (k == SDLK_RETURN || k == SDLK_KP_ENTER) {
			toast_set(u, p->input[0] ? p->input : "Порожньо", 1,
				  2000);
			pop_page(u);
		}
	}
}

static void handle_key(struct ui *u, SDL_Keycode k)
{
	/* Overlays ignore keys (loading/busy/progress). */
	if (u->overlay != OV_NONE)
		return;
	if (u->npages > 0) {
		handle_page_key(u, k);
		return;
	}
	if (base_empty(u)) {
		if (k == SDLK_RETURN || k == SDLK_KP_ENTER ||
		    k == SDLK_r) {
			if (menu_admin_rescan(u) < 0)
				toast_set(u, "cpz-menud недоступний", 2, 2500);
			else
				toast_set(u, "Оновлення меню…", 1, 1500);
			menu_send(u, "{\"v\":1,\"op\":\"snapshot\"}");
			return;
		}
		if (k == SDLK_c) {
			execute_action(u, &u->emerg[0].act,
				       u->emerg[0].label);
			return;
		}
	}
	struct screen *s = cur_screen(u);
	int n = screen_item_count(u, s->parent);
	struct ui_item *sel = n > 0 ? screen_item(u, s->parent, s->selected)
				    : NULL;

	switch (k) {
	case SDLK_ESCAPE:
	case SDLK_LEFT:
	case SDLK_BACKSPACE:
	case SDLK_z:
		pop_screen(u);
		return;
	case SDLK_UP:
	case SDLK_f:
		move_selection(u, -1);
		return;
	case SDLK_DOWN:
	case SDLK_x:
		move_selection(u, 1);
		return;
	case SDLK_HOME:
		if (n > 0) {
			s->selected = 0;
			sel = screen_item(u, s->parent, 0);
			if (sel)
				snprintf(s->sel_id, sizeof(s->sel_id), "%s",
					 sel->id);
			clamp_scroll(u);
			u->dirty = 1;
		}
		return;
	case SDLK_END:
		if (n > 0) {
			s->selected = n - 1;
			sel = screen_item(u, s->parent, n - 1);
			if (sel)
				snprintf(s->sel_id, sizeof(s->sel_id), "%s",
					 sel->id);
			clamp_scroll(u);
			u->dirty = 1;
		}
		return;
	case SDLK_RETURN:
	case SDLK_KP_ENTER:
	case SDLK_RIGHT:
	case SDLK_c:
		if (!sel)
			return;
		if (!strcmp(sel->id, "emergency.reload")) {
			menu_disconnect(u);
			u->menu_retry_at = now_ms();
			toast_set(u, "Повторне підключення…", 1, 1500);
			return;
		}
		activate_item(u, sel);
		return;
	default:
		return;
	}
}

/* --------------------------------------------------------------- main */

static const char *renderer_name(SDL_Renderer *ren)
{
	SDL_RendererInfo info;

	return SDL_GetRendererInfo(ren, &info) == 0 ? info.name : "?";
}

static void draw_splash(struct ui *u)
{
	int w = 320, h = 170;
	int side, height, half, cx, top;

	if (SDL_GetRendererOutputSize(u->ren, &w, &h) != 0 || w <= 0 || h <= 0) {
		w = 320;
		h = 170;
	}
	SDL_SetRenderDrawColor(u->ren, 255, 255, 255, 255);
	SDL_RenderClear(u->ren);
	side = w < h ? w : h;
	height = side / 2;
	if (height < 8)
		height = 8;
	half = (height * 577) / 1000;
	cx = w / 2;
	top = (h - height) / 2;
	SDL_SetRenderDrawColor(u->ren, 20, 18, 22, 255);
	for (int y = 0; y < height; y++) {
		int span = (half * (y + 1)) / height;

		SDL_RenderDrawLine(u->ren, cx - span, top + y, cx + span,
				   top + y);
	}
	SDL_RenderPresent(u->ren);
}

static void heartbeat(struct ui *u)
{
	if (u->hb_fd < 0)
		u->hb_fd = open("/run/cpz/ui.heartbeat",
				O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (u->hb_fd >= 0) {
		char c = '1';

		(void)lseek(u->hb_fd, 0, SEEK_SET);
		if (write(u->hb_fd, &c, 1) < 0) {
			close(u->hb_fd);
			u->hb_fd = -1;
		}
	}
}

static void ui_init_stack(struct ui *u)
{
	u->depth = 1;
	memset(&u->stack[0], 0, sizeof(u->stack[0]));
	snprintf(u->stack[0].parent, sizeof(u->stack[0].parent), "root");
	snprintf(u->stack[0].title, sizeof(u->stack[0].title), "Меню");
}

static void ui_cleanup(struct ui *u)
{
	if (u->menu_fd >= 0)
		close(u->menu_fd);
	free(u->menu_buf);
	for (int i = 0; i < u->nicons; i++)
		cairo_surface_destroy(u->icons[i].surf);
	snapshot_free(&u->snap);
	emergency_free(u);
	for (int i = 0; i < u->npages; i++)
		page_clear(&u->pages[i]);
	action_free(&u->pending);
	if (u->hb_fd >= 0)
		close(u->hb_fd);
	if (u->layout)
		g_object_unref(u->layout);
	if (u->font_reg)
		pango_font_description_free(u->font_reg);
	if (u->font_bold)
		pango_font_description_free(u->font_bold);
	if (u->font_body)
		pango_font_description_free(u->font_body);
	if (u->font_small)
		pango_font_description_free(u->font_small);
	if (u->font_status)
		pango_font_description_free(u->font_status);
	if (u->cr)
		cairo_destroy(u->cr);
	if (u->surf)
		cairo_surface_destroy(u->surf);
	if (u->tex)
		SDL_DestroyTexture(u->tex);
	SDL_DestroyRenderer(u->ren);
	SDL_DestroyWindow(u->win);
	SDL_Quit();
}

int main(int argc, char **argv)
{
	struct ui u;
	SDL_Event ev;
	int splash = 0;
	int splash_ms = SPLASH_MS;

	memset(&u, 0, sizeof(u));
	u.menu_fd = -1;
	u.hb_fd = -1;
	u.screenshot_ms = 1200;
	u.t_start = now_ms();
	ui_init_stack(&u);

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--version")) {
			printf("cpz-ui %s\n", VERSION);
			return 0;
		}
		if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			printf("usage: cpz-ui [--splash] [--splash-ms N] "
			       "[--version]\n");
			return 0;
		}
		if (!strcmp(argv[i], "--splash"))
			splash = 1;
		if (!strcmp(argv[i], "--screenshot") && i + 1 < argc)
			u.screenshot = argv[++i];
		if (!strcmp(argv[i], "--screenshot-ms") && i + 1 < argc)
			u.screenshot_ms = atoi(argv[++i]);
		if (!strcmp(argv[i], "--open") && i + 1 < argc)
			snprintf(u.debug_open, sizeof(u.debug_open), "%s",
				 argv[++i]);
		if (!strcmp(argv[i], "--activate") && i + 1 < argc)
			snprintf(u.debug_activate, sizeof(u.debug_activate),
				 "%s", argv[++i]);
		if (!strcmp(argv[i], "--splash-ms") && i + 1 < argc) {
			splash_ms = atoi(argv[++i]);
			if (splash_ms < 0)
				splash_ms = 0;
		}
	}
	const char *env_ms = getenv("CPZ_SPLASH_MS");

	if (getenv("CPZ_MENU_SOCKET"))
		menu_socket_path = getenv("CPZ_MENU_SOCKET");
	if (getenv("CPZ_SESSION_SOCKET"))
		session_socket_path = getenv("CPZ_SESSION_SOCKET");
	if (getenv("CPZ_UI_SCREENSHOT"))
		u.screenshot = getenv("CPZ_UI_SCREENSHOT");
	if (env_ms && *env_ms) {
		splash_ms = atoi(env_ms);
		if (splash_ms < 0)
			splash_ms = 0;
	}
	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_TIMER) != 0) {
		fprintf(stderr, "cpz-ui: SDL_Init: %s\n", SDL_GetError());
		return 1;
	}
	SDL_StartTextInput();
	SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "1");
	SDL_ShowCursor(SDL_DISABLE);
	u.win = SDL_CreateWindow("cpz", SDL_WINDOWPOS_CENTERED,
				 SDL_WINDOWPOS_CENTERED, 320, 170,
				 SDL_WINDOW_SHOWN);
	if (!u.win) {
		fprintf(stderr, "cpz-ui: window: %s\n", SDL_GetError());
		SDL_Quit();
		return 1;
	}
	cpz_apply_display_mode(u.win);
	u.ren = cpz_create_renderer(u.win);
	if (!u.ren) {
		fprintf(stderr, "cpz-ui: renderer: %s\n", SDL_GetError());
		SDL_DestroyWindow(u.win);
		SDL_Quit();
		return 1;
	}
	if (splash && splash_ms > 0) {
		u.splash = 1;
		u.splash_until = now_ms() + (uint64_t)splash_ms;
		fprintf(stderr, "cpz-ui: splash %d ms\n", splash_ms);
		draw_splash(&u);
	}
	layout(&u);
	emergency_init(&u);
	clamp_scroll(&u);
	u.last_hb = now_ms();
	u.last_draw = u.last_hb;
	u.last_poll = 0;
	u.menu_retry_at = now_ms();
	u.dirty = 1;
	heartbeat(&u);
	if (u.screenshot)
		u.screenshot_at = now_ms() + (uint64_t)u.screenshot_ms;

	while (!u.quit) {
		while (SDL_PollEvent(&ev)) {
			if (ev.type == SDL_QUIT) {
				u.quit = 1;
			} else if (ev.type == SDL_KEYDOWN) {
				if (u.splash) {
					u.splash = 0;
					u.dirty = 1;
					continue;
				}
				if (u.trans.active) {
					u.trans.active = 0;
					u.dirty = 1;
				}
				handle_key(&u, ev.key.keysym.sym);
			} else if (ev.type == SDL_TEXTINPUT) {
				if (u.overlay == OV_NONE && u.npages > 0) {
					struct page *p =
						&u.pages[u.npages - 1];

					if (p->kind == PG_INPUT) {
						size_t add = strlen(
							ev.text.text);
						size_t room = sizeof(p->input) -
							(size_t)p->input_len - 1;
						size_t n = add < room ? add :
								       room;

						memcpy(p->input + p->input_len,
						       ev.text.text, n);
						p->input_len += (int)n;
						p->input[p->input_len] = '\0';
						u.dirty = 1;
					}
				}
			}
		}

		menu_pump(&u);
		menu_tick(&u);
		if (!u.debug_done && u.have_snapshot &&
		    (u.debug_open[0] || u.debug_activate[0])) {
			const char *id = u.debug_activate[0] ?
					 u.debug_activate : u.debug_open;
			struct ui_item *it = find_item_by_id(&u, id);

			if (it) {
				if (u.debug_activate[0] ||
				    !item_has_children(&u, it->id))
					activate_item(&u, it);
				else
					push_screen(&u, it->id,
						    it->label ? it->label : "");
				u.debug_done = 1;
			}
		}

		uint64_t now = now_ms();
		if (u.splash && now >= u.splash_until) {
			u.splash = 0;
			u.dirty = 1;
		}
		if (u.toast[0] && now >= u.toast_until) {
			u.toast[0] = '\0';
			u.dirty = 1;
		}
		if (u.overlay == OV_LOADING && now_ms() >= u.ov_until) {
			u.overlay = OV_NONE;
			start_error(&u, "Помилка", "Час очікування запуску минув",
				    u.has_pending ? &u.pending : NULL,
				    u.pending_label);
		} else if (u.overlay == OV_BUSY && now_ms() >= u.ov_until) {
			u.overlay = OV_NONE;
			toast_set(&u, "Виконано", 1, 2000);
		}
		if (u.trans.active && now - u.trans.start >=
		    (uint64_t)u.trans.ms) {
			u.trans.active = 0;
			u.dirty = 1;
		}
		if (u.splash) {
			if (now - u.last_draw >= 100) {
				draw_splash(&u);
				u.last_draw = now;
			}
		} else if (u.trans.active) {
			draw_transition(&u);
			draw_toast(&u);
			present(&u);
			u.last_draw = now;
		} else {
			int animate = u.overlay == OV_LOADING ||
				      u.overlay == OV_BUSY ||
				      u.overlay == OV_PROGRESS;

			if (u.dirty || now - u.last_draw >= 1000 ||
			    (animate && now - u.last_draw >= 40)) {
				redraw_now(&u);
				u.dirty = 0;
			}
		}
		if (now - u.last_hb >= 1000) {
			u.last_hb = now;
			heartbeat(&u);
		}
		if (u.screenshot && !u.splash && now >= u.screenshot_at) {
			cairo_surface_flush(u.surf);
			cairo_surface_write_to_png(u.surf, u.screenshot);
			u.quit = 1;
		}
		SDL_Delay(u.splash ? 20 : (u.trans.active ? 10 : 50));
	}

	ui_cleanup(&u);
	return 0;
}
