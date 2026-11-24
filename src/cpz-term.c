/*
 * cpz-term — the Cardputer Zero terminal application.
 *
 * This is deliberately an application, not the system console. It owns an SDL2
 * window while it runs, runs a shell on a pty, and uses libtsm for VT emulation.
 * The launcher starts it; when it exits, cpz-session restarts the launcher.
 *
 * Unicode/Cyrillic text is rendered with SDL_ttf. The font is a normal
 * monospace TTF, so the terminal is not limited to the old 95 ASCII glyphs.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-term.c -o cpz-term \
 *            $(pkg-config --cflags --libs sdl2 SDL2_ttf) -ltsm -lutil
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>
#include "cpz-sdlmode.h"
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <libtsm.h>
#include <poll.h>
#include <pty.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define XK_BackSpace   0xff08
#define XK_Tab         0xff09
#define XK_Return      0xff0d
#define XK_Escape      0xff1b
#define XK_ISO_Left_Tab 0xfe20
#define XK_Home        0xff50
#define XK_Left        0xff51
#define XK_Up          0xff52
#define XK_Right       0xff53
#define XK_Down        0xff54
#define XK_Page_Up     0xff55
#define XK_Page_Down   0xff56
#define XK_End         0xff57
#define XK_Insert      0xff63
#define XK_KP_Enter    0xff8d
#define XK_F1          0xffbe
#define XK_Delete      0xffff

#define GLYPH_CACHE 4096
#define OUTBUF_INIT 4096

static const uint8_t palette[TSM_COLOR_NUM][3] = {
	[TSM_COLOR_BLACK]         = {   0,   0,   0 },
	[TSM_COLOR_RED]           = { 170,   0,   0 },
	[TSM_COLOR_GREEN]         = {   0, 170,   0 },
	[TSM_COLOR_YELLOW]        = { 170,  85,   0 },
	[TSM_COLOR_BLUE]          = {   0,   0, 170 },
	[TSM_COLOR_MAGENTA]       = { 170,   0, 170 },
	[TSM_COLOR_CYAN]          = {   0, 170, 170 },
	[TSM_COLOR_LIGHT_GREY]    = { 170, 170, 170 },
	[TSM_COLOR_DARK_GREY]     = {  85,  85,  85 },
	[TSM_COLOR_LIGHT_RED]     = { 255,  85,  85 },
	[TSM_COLOR_LIGHT_GREEN]   = {  85, 255,  85 },
	[TSM_COLOR_LIGHT_YELLOW]  = { 255, 255,  85 },
	[TSM_COLOR_LIGHT_BLUE]    = {  85,  85, 255 },
	[TSM_COLOR_LIGHT_MAGENTA] = { 255,  85, 255 },
	[TSM_COLOR_LIGHT_CYAN]    = {  85, 255, 255 },
	[TSM_COLOR_WHITE]         = { 255, 255, 255 },
	[TSM_COLOR_FOREGROUND]    = { 192, 192, 192 },
	[TSM_COLOR_BACKGROUND]    = {   0,   0,   0 },
};

struct outbuf {
	unsigned char *data;
	size_t len, off, cap;
};

struct glyph {
	uint32_t cp;
	SDL_Texture *tex;
	int w, h;
	int minx, maxy;
	int used;
};

struct glyph_cache {
	struct glyph slots[GLYPH_CACHE];
};

struct term {
	SDL_Window *win;
	SDL_Renderer *ren;
	TTF_Font *font;
	int font_px;
	int ascent;

	struct tsm_screen *screen;
	struct tsm_vte *vte;

	int master;
	pid_t pid;
	struct outbuf out;

	int cols, rows;
	int cell_w, cell_h;
	int ox, oy;
	int w, h;

	int dirty;
	int quit;
	int cursor_on;
	uint64_t last_cursor_ms;

	struct glyph_cache cache;
};

static const char *term_font_candidates[] = {
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu/DejaVuSans.ttf",
	NULL,
};

static uint64_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static TTF_Font *open_font(int px)
{
	const char *env = getenv("CPZ_TERM_FONT");
	if (env && *env) {
		TTF_Font *f = TTF_OpenFont(env, px);
		if (f)
			return f;
	}
	for (int i = 0; term_font_candidates[i]; i++) {
		TTF_Font *f = TTF_OpenFont(term_font_candidates[i], px);
		if (f) {
			TTF_SetFontHinting(f, TTF_HINTING_MONO);
			return f;
		}
	}
	return NULL;
}

static int out_reserve(struct outbuf *o, size_t add)
{
	size_t need = o->len + add;
	if (need <= o->cap)
		return 0;
	size_t cap = o->cap ? o->cap : OUTBUF_INIT;
	while (cap < need)
		cap *= 2;
	unsigned char *p = realloc(o->data, cap);
	if (!p)
		return -1;
	o->data = p;
	o->cap = cap;
	return 0;
}

static void out_write(struct outbuf *o, const char *buf, size_t len)
{
	if (out_reserve(o, len) < 0)
		return;
	memcpy(o->data + o->len, buf, len);
	o->len += len;
}

static void out_flush(struct term *t)
{
	while (t->out.off < t->out.len) {
		ssize_t n = write(t->master, t->out.data + t->out.off,
				  t->out.len - t->out.off);
		if (n > 0) {
			t->out.off += (size_t)n;
			continue;
		}
		if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
			return;
		if (n < 0 && errno == EINTR)
			continue;
		t->out.len = t->out.off = 0;
		return;
	}
	t->out.len = t->out.off = 0;
}

static void vte_write_cb(struct tsm_vte *vte, const char *u8, size_t len,
			 void *data)
{
	struct term *t = data;
	(void)vte;
	out_write(&t->out, u8, len);
}

static void sink_write_cb(struct tsm_vte *vte, const char *u8, size_t len,
			  void *data)
{
	(void)vte; (void)u8; (void)len; (void)data;
}

static void set_winsize(struct term *t)
{
	if (t->master < 0)
		return;
	struct winsize ws = { 0 };
	ws.ws_col = (unsigned short)t->cols;
	ws.ws_row = (unsigned short)t->rows;
	ws.ws_xpixel = (unsigned short)(t->cols * t->cell_w);
	ws.ws_ypixel = (unsigned short)(t->rows * t->cell_h);
	ioctl(t->master, TIOCSWINSZ, &ws);
}

static SDL_Texture *make_glyph(struct term *t, uint32_t cp, struct glyph *g)
{
	SDL_Surface *surf;
	int minx = 0, maxx = 0, miny = 0, maxy = 0, adv = 0;

	if (TTF_GlyphMetrics32(t->font, cp, &minx, &maxx, &miny, &maxy, &adv) != 0)
		return NULL;
	SDL_Color white = { 255, 255, 255, 255 };
	surf = TTF_RenderGlyph32_Blended(t->font, cp, white);
	if (!surf)
		return NULL;
	SDL_Texture *tex = SDL_CreateTextureFromSurface(t->ren, surf);
	SDL_FreeSurface(surf);
	if (!tex)
		return NULL;
	SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
	g->tex = tex;
	g->w = 0;
	g->h = 0;
	SDL_QueryTexture(tex, NULL, NULL, &g->w, &g->h);
	g->minx = minx;
	g->maxy = maxy;
	return tex;
}

static struct glyph *glyph_get(struct term *t, uint32_t cp)
{
	struct glyph_cache *c = &t->cache;
	unsigned idx = (unsigned)((cp * 2654435761u) % GLYPH_CACHE);

	if (cp == 0 || cp == ' ')
		return NULL;

	for (int i = 0; i < GLYPH_CACHE; i++) {
		struct glyph *g = &c->slots[idx];
		if (!g->used) {
			g->used = 1;
			g->cp = cp;
			if (!make_glyph(t, cp, g))
				g->tex = NULL;
			return g;
		}
		if (g->cp == cp)
			return g;
		idx = (idx + 1) % GLYPH_CACHE;
	}
	return NULL;
}

static void glyph_cache_clear(struct glyph_cache *c)
{
	for (int i = 0; i < GLYPH_CACHE; i++) {
		if (c->slots[i].tex)
			SDL_DestroyTexture(c->slots[i].tex);
	}
	memset(c, 0, sizeof(*c));
}

static int cell_cb(struct tsm_screen *con, uint64_t id, const uint32_t *ch,
		   size_t len, unsigned int width, unsigned int posx,
		   unsigned int posy, const struct tsm_screen_attr *attr,
		   tsm_age_t age, void *data)
{
	struct term *t = data;
	(void)con; (void)id; (void)width; (void)age;

	if (posx >= (unsigned)t->cols || posy >= (unsigned)t->rows)
		return 0;

	uint32_t cp = len ? ch[0] : ' ';
	SDL_Color fg = { attr->fr, attr->fg, attr->fb, 255 };
	SDL_Color bg = { attr->br, attr->bg, attr->bb, 255 };
	if (attr->inverse) {
		SDL_Color tmp = fg;
		fg = bg;
		bg = tmp;
	}
	if (attr->dim) {
		fg.r = (Uint8)(fg.r * 2 / 3);
		fg.g = (Uint8)(fg.g * 2 / 3);
		fg.b = (Uint8)(fg.b * 2 / 3);
	}

	int x = t->ox + (int)posx * t->cell_w;
	int y = t->oy + (int)posy * t->cell_h;
	SDL_Rect cell = { x, y, t->cell_w, t->cell_h };

	SDL_SetRenderDrawColor(t->ren, bg.r, bg.g, bg.b, 255);
	SDL_RenderFillRect(t->ren, &cell);

	if (cp != ' ') {
		struct glyph *g = glyph_get(t, cp);
		if (g && g->tex) {
			SDL_Rect dst = {
				x + g->minx,
				y + t->ascent - g->maxy,
				g->w, g->h
			};
			SDL_SetTextureColorMod(g->tex, fg.r, fg.g, fg.b);
			SDL_RenderCopy(t->ren, g->tex, NULL, &dst);
			if (attr->bold) {
				dst.x += 1;
				SDL_SetTextureAlphaMod(g->tex, 160);
				SDL_RenderCopy(t->ren, g->tex, NULL, &dst);
				SDL_SetTextureAlphaMod(g->tex, 255);
			}
		}
	}
	if (attr->underline) {
		SDL_SetRenderDrawColor(t->ren, fg.r, fg.g, fg.b, 255);
		SDL_Rect u = { x, y + t->cell_h - 2, t->cell_w, 1 };
		SDL_RenderFillRect(t->ren, &u);
	}
	return 0;
}

static void layout_term(struct term *t)
{
	int w, h;
	int margin = 4;

	SDL_GetRendererOutputSize(t->ren, &w, &h);
	if (w <= 0 || h <= 0)
		return;
	t->w = w;
	t->h = h;

	int want_px = h >= 700 ? 24 : (h >= 400 ? 16 : 11);
	if (!t->font || t->font_px != want_px) {
		if (t->font)
			TTF_CloseFont(t->font);
		t->font = open_font(want_px);
		t->font_px = want_px;
		glyph_cache_clear(&t->cache);
		if (!t->font) {
			fprintf(stderr, "cpz-term: cannot open font\n");
			exit(1);
		}
	}

	int gw = 0, gh = 0;
	if (TTF_SizeUTF8(t->font, "M", &gw, &gh) != 0 || gw <= 0)
		gw = want_px / 2;
	t->cell_w = gw;
	t->cell_h = TTF_FontLineSkip(t->font);
	t->ascent = TTF_FontAscent(t->font);

	int cols = (w - 2 * margin) / t->cell_w;
	int rows = (h - 2 * margin) / t->cell_h;
	if (cols < 2) cols = 2;
	if (rows < 2) rows = 2;
	t->ox = (w - cols * t->cell_w) / 2;
	t->oy = (h - rows * t->cell_h) / 2;

	if (cols != t->cols || rows != t->rows) {
		t->cols = cols;
		t->rows = rows;
		tsm_screen_resize(t->screen, (unsigned)cols, (unsigned)rows);
		set_winsize(t);
		t->dirty = 1;
	}
}

static void render_frame(struct term *t)
{
	layout_term(t);
	SDL_SetRenderDrawColor(t->ren, 10, 10, 16, 255);
	SDL_RenderClear(t->ren);
	tsm_screen_draw(t->screen, cell_cb, t);

	if (t->cursor_on) {
		unsigned cx = tsm_screen_get_cursor_x(t->screen);
		unsigned cy = tsm_screen_get_cursor_y(t->screen);
		if (cx < (unsigned)t->cols && cy < (unsigned)t->rows) {
			SDL_SetRenderDrawColor(t->ren, 232, 176, 75, 255);
			SDL_Rect r = {
				t->ox + (int)cx * t->cell_w,
				t->oy + (int)cy * t->cell_h + t->cell_h - 2,
				t->cell_w, 2
			};
			SDL_RenderFillRect(t->ren, &r);
		}
	}
	SDL_RenderPresent(t->ren);
	t->dirty = 0;
}

static void send_key(struct term *t, uint32_t keysym, uint32_t ascii,
		     unsigned mods, uint32_t unicode)
{
	tsm_vte_handle_keyboard(t->vte, keysym, ascii, mods, unicode);
	t->dirty = 1;
}

static uint32_t special_key(SDL_Keycode sym)
{
	switch (sym) {
	case SDLK_BACKSPACE: return XK_BackSpace;
	case SDLK_TAB:       return XK_Tab;
	case SDLK_RETURN:    return XK_Return;
	case SDLK_KP_ENTER:  return XK_KP_Enter;
	case SDLK_ESCAPE:    return XK_Escape;
	case SDLK_LEFT:      return XK_Left;
	case SDLK_RIGHT:     return XK_Right;
	case SDLK_UP:        return XK_Up;
	case SDLK_DOWN:      return XK_Down;
	case SDLK_HOME:      return XK_Home;
	case SDLK_END:       return XK_End;
	case SDLK_INSERT:    return XK_Insert;
	case SDLK_DELETE:    return XK_Delete;
	case SDLK_PAGEUP:    return XK_Page_Up;
	case SDLK_PAGEDOWN:  return XK_Page_Down;
	case SDLK_F1:  return XK_F1;
	case SDLK_F2:  return XK_F1 + 1;
	case SDLK_F3:  return XK_F1 + 2;
	case SDLK_F4:  return XK_F1 + 3;
	case SDLK_F5:  return XK_F1 + 4;
	case SDLK_F6:  return XK_F1 + 5;
	case SDLK_F7:  return XK_F1 + 6;
	case SDLK_F8:  return XK_F1 + 7;
	case SDLK_F9:  return XK_F1 + 8;
	case SDLK_F10: return XK_F1 + 9;
	case SDLK_F11: return XK_F1 + 10;
	case SDLK_F12: return XK_F1 + 11;
	default: return 0;
	}
}

static void handle_key(struct term *t, const SDL_KeyboardEvent *k)
{
	SDL_Keymod mod = SDL_GetModState();
	unsigned mods = 0;
	if (mod & KMOD_SHIFT) mods |= TSM_SHIFT_MASK;
	if (mod & KMOD_CTRL)  mods |= TSM_CONTROL_MASK;
	if (mod & KMOD_ALT)   mods |= TSM_ALT_MASK;

	if ((mod & KMOD_CTRL) && (mod & KMOD_SHIFT) && k->keysym.sym == SDLK_q) {
		t->quit = 1;
		return;
	}

	if (mod & KMOD_SHIFT) {
		if (k->keysym.sym == SDLK_PAGEUP) {
			tsm_screen_scroll_up(t->screen, (unsigned)t->rows / 2);
			t->dirty = 1;
			return;
		}
		if (k->keysym.sym == SDLK_PAGEDOWN) {
			tsm_screen_scroll_down(t->screen, (unsigned)t->rows / 2);
			t->dirty = 1;
			return;
		}
	}
	/* Typing returns the view to the live screen. */
	tsm_screen_sb_reset(t->screen);

	uint32_t sym = special_key(k->keysym.sym);
	if (sym) {
		if (sym == XK_Tab && (mod & KMOD_SHIFT))
			sym = XK_ISO_Left_Tab;
		send_key(t, sym, 0, mods, TSM_VTE_INVALID);
		return;
	}

	if ((mod & KMOD_CTRL) && k->keysym.sym >= SDLK_a &&
	    k->keysym.sym <= SDLK_z) {
		uint32_t c = (uint32_t)k->keysym.sym;
		send_key(t, c, c, mods, c);
		return;
	}
	if (mod & KMOD_ALT) {
		uint32_t c = (uint32_t)k->keysym.sym;
		if (c >= 0x20 && c < 0x7f)
			send_key(t, c, c, mods, c);
		return;
	}
	/* Plain printable keys arrive through SDL_TEXTINPUT, which respects
	 * the active layout and produces UTF-8 (including Cyrillic). */
}

static uint32_t utf8_next(const unsigned char **pp)
{
	const unsigned char *p = *pp;
	uint32_t cp;
	int n;

	if (p[0] < 0x80) {
		cp = p[0];
		n = 1;
	} else if ((p[0] & 0xe0) == 0xc0 && (p[1] & 0xc0) == 0x80) {
		cp = ((uint32_t)(p[0] & 0x1f) << 6) | (p[1] & 0x3f);
		n = 2;
	} else if ((p[0] & 0xf0) == 0xe0 && (p[1] & 0xc0) == 0x80 &&
		   (p[2] & 0xc0) == 0x80) {
		cp = ((uint32_t)(p[0] & 0x0f) << 12) |
		     ((uint32_t)(p[1] & 0x3f) << 6) | (p[2] & 0x3f);
		n = 3;
	} else if ((p[0] & 0xf8) == 0xf0 && (p[1] & 0xc0) == 0x80 &&
		   (p[2] & 0xc0) == 0x80 && (p[3] & 0xc0) == 0x80) {
		cp = ((uint32_t)(p[0] & 0x07) << 18) |
		     ((uint32_t)(p[1] & 0x3f) << 12) |
		     ((uint32_t)(p[2] & 0x3f) << 6) | (p[3] & 0x3f);
		n = 4;
	} else {
		cp = 0xfffd;
		n = 1;
	}
	*pp += n;
	return cp;
}

static void handle_text(struct term *t, const char *text)
{
	const unsigned char *p = (const unsigned char *)text;
	SDL_Keymod mod = SDL_GetModState();
	if (mod & (KMOD_CTRL | KMOD_ALT))
		return;
	tsm_screen_sb_reset(t->screen);
	while (*p) {
		uint32_t cp = utf8_next(&p);
		if (cp)
			send_key(t, cp, 0, 0, cp);
	}
}

static void child_shell(void)
{
	struct passwd *pw = getpwnam("cpz");

	if (geteuid() == 0 && pw) {
		setgid(pw->pw_gid);
		initgroups(pw->pw_name, pw->pw_gid);
		setuid(pw->pw_uid);
		chdir(pw->pw_dir);
	}
	setenv("TERM", "xterm-256color", 1);
	setenv("COLORTERM", "truecolor", 1);
	setenv("LANG", "C.UTF-8", 1);
	setenv("LC_ALL", "C.UTF-8", 1);
	setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
	if (pw) {
		setenv("HOME", pw->pw_dir, 1);
		setenv("USER", pw->pw_name, 1);
		setenv("LOGNAME", pw->pw_name, 1);
	}
	setenv("SHELL", "/bin/bash", 1);
	execl("/bin/bash", "bash", "-l", (char *)NULL);
	execl("/bin/sh", "sh", "-l", (char *)NULL);
	_exit(127);
}

static int start_shell(struct term *t)
{
	struct winsize ws = { 0 };
	ws.ws_col = (unsigned short)t->cols;
	ws.ws_row = (unsigned short)t->rows;
	ws.ws_xpixel = (unsigned short)(t->cols * t->cell_w);
	ws.ws_ypixel = (unsigned short)(t->rows * t->cell_h);

	pid_t pid = forkpty(&t->master, NULL, NULL, &ws);
	if (pid < 0)
		return -1;
	if (pid == 0)
		child_shell();
	t->pid = pid;
	int fl = fcntl(t->master, F_GETFL, 0);
	if (fl >= 0)
		fcntl(t->master, F_SETFL, fl | O_NONBLOCK);
	return 0;
}

static void read_pty(struct term *t)
{
	char buf[4096];
	for (;;) {
		ssize_t n = read(t->master, buf, sizeof(buf));
		if (n > 0) {
			tsm_vte_input(t->vte, buf, (size_t)n);
			t->dirty = 1;
			continue;
		}
		if (n == 0) {
			t->quit = 1;
			return;
		}
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
			return;
		t->quit = 1;
		return;
	}
}

static int run_terminal(void)
{
	struct term t;
	int rc = 1;

	memset(&t, 0, sizeof(t));
	t.master = -1;

	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_TIMER) != 0) {
		fprintf(stderr, "cpz-term: SDL_Init: %s\n", SDL_GetError());
		return 1;
	}
	SDL_ShowCursor(SDL_DISABLE);
	t.win = SDL_CreateWindow("cpz-term", SDL_WINDOWPOS_CENTERED,
				 SDL_WINDOWPOS_CENTERED, 640, 340,
				 SDL_WINDOW_SHOWN);
	if (!t.win) {
		fprintf(stderr, "cpz-term: window: %s\n", SDL_GetError());
		goto out_sdl;
	}
	cpz_apply_display_mode(t.win);
	t.ren = cpz_create_renderer(t.win);
	if (!t.ren) {
		fprintf(stderr, "cpz-term: renderer: %s\n", SDL_GetError());
		goto out_win;
	}
	if (TTF_Init() != 0) {
		fprintf(stderr, "cpz-term: TTF_Init: %s\n", TTF_GetError());
		goto out_ren;
	}
	if (tsm_screen_new(&t.screen, NULL, NULL) < 0) {
		fprintf(stderr, "cpz-term: tsm_screen_new failed\n");
		goto out_ttf;
	}
	tsm_screen_set_max_sb(t.screen, 2048);
	if (tsm_vte_new(&t.vte, t.screen, vte_write_cb, &t, NULL, NULL) < 0) {
		fprintf(stderr, "cpz-term: tsm_vte_new failed\n");
		goto out_screen;
	}
	tsm_vte_set_backspace_sends_delete(t.vte, true);
	tsm_vte_set_custom_palette(t.vte, (uint8_t (*)[3])palette);
	tsm_vte_set_palette(t.vte, "custom");

	layout_term(&t);
	if (start_shell(&t) < 0) {
		fprintf(stderr, "cpz-term: forkpty: %s\n", strerror(errno));
		goto out_vte;
	}
	SDL_StartTextInput();
	t.cursor_on = 1;
	t.last_cursor_ms = now_ms();
	t.dirty = 1;

	while (!t.quit) {
		struct pollfd p = { .fd = t.master, .events = POLLIN };
		int n = poll(&p, 1, 10);
		if (n > 0 && (p.revents & (POLLIN | POLLHUP)))
			read_pty(&t);
		if (t.out.off < t.out.len)
			out_flush(&t);

		SDL_PumpEvents();
		SDL_Event ev;
		while (SDL_PollEvent(&ev)) {
			if (ev.type == SDL_QUIT) {
				t.quit = 1;
			} else if (ev.type == SDL_KEYDOWN) {
				handle_key(&t, &ev.key);
			} else if (ev.type == SDL_TEXTINPUT) {
				handle_text(&t, ev.text.text);
			}
		}

		int status;
		if (t.pid > 0 && waitpid(t.pid, &status, WNOHANG) == t.pid)
			t.quit = 1;

		uint64_t ms = now_ms();
		if (ms - t.last_cursor_ms >= 500) {
			t.last_cursor_ms = ms;
			t.cursor_on = !t.cursor_on;
			t.dirty = 1;
		}
		if (t.dirty)
			render_frame(&t);
	}
	rc = 0;

	if (t.pid > 0) {
		kill(t.pid, SIGHUP);
		waitpid(t.pid, NULL, 0);
	}
out_vte:
	tsm_vte_unref(t.vte);
out_screen:
	tsm_screen_unref(t.screen);
out_ttf:
	glyph_cache_clear(&t.cache);
	if (t.font)
		TTF_CloseFont(t.font);
	TTF_Quit();
out_ren:
	SDL_DestroyRenderer(t.ren);
out_win:
	SDL_DestroyWindow(t.win);
out_sdl:
	SDL_Quit();
	return rc;
}

static int selftest(void)
{
	struct tsm_screen *screen = NULL;
	struct tsm_vte *vte = NULL;
	const char *text = "\033[1;32mcpz-term\033[0m self-test\r\n"
			   "Кирилиця: Привіт, світе!\r\n";
	int ok = 0;

	if (tsm_screen_new(&screen, NULL, NULL) < 0)
		goto out;
	if (tsm_vte_new(&vte, screen, sink_write_cb, NULL, NULL, NULL) < 0)
		goto out;
	tsm_screen_resize(screen, 80, 24);
	tsm_vte_input(vte, text, strlen(text));
	if (tsm_screen_get_cursor_y(screen) < 2)
		goto out;
	printf("cpz-term selftest: ok (80x24, UTF-8)\n");
	ok = 1;
out:
	if (vte)
		tsm_vte_unref(vte);
	if (screen)
		tsm_screen_unref(screen);
	return ok ? 0 : 1;
}

static void usage(FILE *out)
{
	fputs("usage: cpz-term [--selftest|--version]\n", out);
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--selftest"))
			return selftest();
		if (!strcmp(argv[i], "--version")) {
			printf("cpz-term 0.2.0\n");
			return 0;
		}
		if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(stdout);
			return 0;
		}
		usage(stderr);
		return 2;
	}
	return run_terminal();
}
