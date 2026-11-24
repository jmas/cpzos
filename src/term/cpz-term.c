/*
 * cpz-term — the economy DRM terminal.
 *
 * The session owns the DRM card and passes:
 *   CPZ_DRM_FD, CPZ_FB0_ID, CPZ_FB1_ID, CPZ_FB0_OFFSET, CPZ_FB1_OFFSET,
 *   CPZ_FB_WIDTH, CPZ_FB_HEIGHT, CPZ_FB_STRIDE, CPZ_FB_SIZE, CPZ_CRTC_ID.
 *
 * This process runs as cpz, maps the buffers, renders a libtsm grid with
 * FreeType, reads evdev through xkbcommon and attaches a pty to tmux. It never
 * opens DRM itself and never runs as root.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-term.c -o cpz-term \
 *            -ltsm -lfreetype -lxkbcommon -ldrm -lutil
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <glob.h>
#include <libtsm.h>
#include <linux/input.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#define GLYPH_CACHE 8192
#define MAX_DIRTY 512
#define MAX_INPUT_FDS 16
#define OUTBUF_INIT 4096
#define MAX_CELL_CH 4

struct outbuf {
	unsigned char *data;
	size_t len, off, cap;
};

struct glyph {
	uint32_t cp;
	int bold;
	int valid;
	int w, h, left, top, advance, pitch;
	unsigned char *bmp;
};

struct cell {
	uint32_t ch[MAX_CELL_CH];
	int nch;
	unsigned width;
	struct tsm_screen_attr attr;
	int valid;
};

struct rect {
	int x, y, w, h;
};

struct icon {
	wchar_t cp;
	int w, h;
	uint32_t *pixels; /* 0xAARRGGBB */
};

struct term {
	/* DRM */
	int drm_fd, crtc_id, fb[2];
	uint32_t width, height, stride_px;
	size_t fb_size;
	uint64_t offset[2];
	uint32_t *map[2];
	uint32_t *shadow;
	int front, flip_pending, flip_next;
	drmEventContext evctx;

	/* VT */
	struct tsm_screen *screen;
	struct tsm_vte *vte;
	struct cell *cells;
	int cols, rows;
	int dirty;

	/* font */
	FT_Library ft;
	FT_Face face, bold_face, fallback[3];
	int font_px, cell_w, cell_h, ascent, descent;
	struct glyph cache[GLYPH_CACHE];

	/* pty */
	int master;
	pid_t pid;
	struct outbuf out;

	/* input */
	struct xkb_context *xkb_ctx;
	struct xkb_keymap *keymap;
	struct xkb_state *state;
	int input[MAX_INPUT_FDS];
	int ninput;

	/* cursor */
	int cursor_x, cursor_y;
	int cursor_on;
	int cursor_drawn;
	uint64_t last_cursor_ms;

	/* real image icons, addressed by PUA codepoints */
	struct icon icons[64];
	int nicons;

	/* damage: both buffers accumulate changes until they are back */
	struct rect pending[2][MAX_DIRTY];
	int npending[2];

	int quit;
	int debug;
	int heartbeat_fd;
	uint64_t last_heartbeat_ms;
};

static uint8_t palette[TSM_COLOR_NUM][3] = {
	[TSM_COLOR_BLACK]         = {   0,   0,   0 },
	[TSM_COLOR_RED]           = { 224, 108, 117 },
	[TSM_COLOR_GREEN]         = { 152, 195, 121 },
	[TSM_COLOR_YELLOW]        = { 229, 192, 123 },
	[TSM_COLOR_BLUE]          = {  97, 175, 239 },
	[TSM_COLOR_MAGENTA]       = { 198, 120, 221 },
	[TSM_COLOR_CYAN]          = {  86, 182, 194 },
	[TSM_COLOR_LIGHT_GREY]    = { 216, 222, 233 },
	[TSM_COLOR_DARK_GREY]     = { 122, 133, 153 },
	[TSM_COLOR_LIGHT_RED]     = { 255, 138, 148 },
	[TSM_COLOR_LIGHT_GREEN]   = { 184, 224, 154 },
	[TSM_COLOR_LIGHT_YELLOW]  = { 255, 219, 154 },
	[TSM_COLOR_LIGHT_BLUE]    = { 128, 201, 255 },
	[TSM_COLOR_LIGHT_MAGENTA] = { 226, 160, 245 },
	[TSM_COLOR_LIGHT_CYAN]    = { 122, 217, 227 },
	[TSM_COLOR_WHITE]         = { 255, 255, 255 },
};
static const uint32_t BG = 0x000e1116;
static const uint32_t ACCENT = 0x004ea1ff;

static uint64_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static int env_int(const char *name, int def)
{
	const char *v = getenv(name);
	return v && *v ? atoi(v) : def;
}

static uint64_t env_u64(const char *name, uint64_t def)
{
	const char *v = getenv(name);
	return v && *v ? strtoull(v, NULL, 10) : def;
}

/* ---------------------------------------------------------------- glyphs */

static uint32_t blend(uint32_t dst, uint32_t src, unsigned alpha);

static void glyph_free_all(struct term *t)
{
	for (int i = 0; i < GLYPH_CACHE; i++) {
		free(t->cache[i].bmp);
		memset(&t->cache[i], 0, sizeof(t->cache[i]));
	}
}

static int is_pua(wchar_t cp)
{
	return cp >= 0xE000 && cp <= 0xF8FF;
}

static struct icon *icon_lookup(struct term *t, wchar_t cp)
{
	for (int i = 0; i < t->nicons; i++)
		if (t->icons[i].cp == cp)
			return &t->icons[i];
	return NULL;
}

static void free_icons(struct term *t)
{
	for (int i = 0; i < t->nicons; i++)
		free(t->icons[i].pixels);
	t->nicons = 0;
}

static void load_icons(struct term *t)
{
	FILE *map = fopen("/usr/share/cpz/icons.map", "r");
	char line[256];

	if (!map)
		return;
	while (fgets(line, sizeof(line), map) && t->nicons < 64) {
		unsigned code;
		char name[64];
		char path[PATH_MAX];
		FILE *f;
		uint32_t w, h;

		if (sscanf(line, "%x %63s", &code, name) != 2)
			continue;
		snprintf(path, sizeof(path), "/usr/share/cpz/icons/%s.rgba",
			 name);
		f = fopen(path, "rb");
		if (!f)
			continue;
		if (fread(&w, sizeof(w), 1, f) != 1 ||
		    fread(&h, sizeof(h), 1, f) != 1 ||
		    w == 0 || h == 0 || w > 256 || h > 256) {
			fclose(f);
			continue;
		}
		size_t count = (size_t)w * h;
		uint32_t *px = calloc(count, sizeof(uint32_t));
		unsigned char *rgba = malloc(count * 4);
		if (!px || !rgba) {
			free(px);
			free(rgba);
			fclose(f);
			continue;
		}
		if (fread(rgba, 4, count, f) != count) {
			free(px);
			free(rgba);
			fclose(f);
			continue;
		}
		for (size_t i = 0; i < count; i++) {
			px[i] = ((uint32_t)rgba[i * 4 + 3] << 24) |
				((uint32_t)rgba[i * 4] << 16) |
				((uint32_t)rgba[i * 4 + 1] << 8) |
				rgba[i * 4 + 2];
		}
		free(rgba);
		fclose(f);
		t->icons[t->nicons].cp = (wchar_t)code;
		t->icons[t->nicons].w = (int)w;
		t->icons[t->nicons].h = (int)h;
		t->icons[t->nicons].pixels = px;
		t->nicons++;
	}
	fclose(map);
}

static void blit_icon(struct term *t, int x, int y, int dw, int dh,
		      const struct icon *icon)
{
	if (!icon || !icon->pixels || dw <= 0 || dh <= 0)
		return;
	for (int row = 0; row < dh; row++) {
		int sy = row * icon->h / dh;
		for (int col = 0; col < dw; col++) {
			int sx = col * icon->w / dw;
			uint32_t p = icon->pixels[(size_t)sy * icon->w + sx];
			unsigned a = p >> 24;
			if (!a)
				continue;
			int px = x + col;
			int py = y + row;
			if (px < 0 || py < 0 || (uint32_t)px >= t->width ||
			    (uint32_t)py >= t->height)
				continue;
			uint32_t dst = t->shadow[(size_t)py * t->stride_px + px];
			t->shadow[(size_t)py * t->stride_px + px] =
				blend(dst, p & 0xffffff, a);
		}
	}
}

static FT_Face load_face(struct term *t, const char *path, int px)
{
	FT_Face f = NULL;

	if (FT_New_Face(t->ft, path, 0, &f) != 0)
		return NULL;
	if (FT_Set_Pixel_Sizes(f, 0, (FT_UInt)px) != 0) {
		FT_Done_Face(f);
		return NULL;
	}
	return f;
}

static int init_font(struct term *t)
{
	const char *font = getenv("CPZ_TERM_FONT");
	const char *candidates[] = {
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/TTF/DejaVuSans.ttf",
		NULL,
	};
	const char *fallbacks[] = {
		"/usr/share/fonts/TTF/NotoSansSymbols2-Regular.ttf",
		"/usr/share/fonts/TTF/NotoEmoji-VF.ttf",
		"/usr/share/fonts/TTF/DejaVuSans.ttf",
		NULL,
	};

	t->font_px = env_int("CPZ_TERM_FONT_SIZE",
			     env_int("CPZ_FONT_PX", t->height > 400 ? 24 : 10));
	if (FT_Init_FreeType(&t->ft) != 0)
		return -1;
	if (font && *font)
		t->face = load_face(t, font, t->font_px);
	for (int i = 0; !t->face && candidates[i]; i++)
		t->face = load_face(t, candidates[i], t->font_px);
	if (!t->face)
		return -1;
	t->bold_face = load_face(t,
		"/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf", t->font_px);
	for (int i = 0; i < 3; i++)
		t->fallback[i] = fallbacks[i] ? load_face(t, fallbacks[i],
							 t->font_px) : NULL;

	FT_Load_Char(t->face, 'M', FT_LOAD_DEFAULT);
	t->cell_w = (int)(t->face->glyph->advance.x >> 6);
	if (t->cell_w <= 0)
		t->cell_w = t->font_px / 2;
	t->ascent = (int)(t->face->size->metrics.ascender >> 6);
	t->descent = (int)(-(t->face->size->metrics.descender >> 6));
	t->cell_h = t->ascent + t->descent;
	if (t->cell_h <= 0)
		t->cell_h = t->font_px + 2;
	/* A little optical leading; keep the cell box integral. */
	t->cell_h += 1;
	return 0;
}

static struct glyph *glyph_get(struct term *t, uint32_t cp, int bold)
{
	unsigned idx = (unsigned)((cp * 2654435761u + (bold ? 97 : 0)) %
				  GLYPH_CACHE);
	struct glyph *g = NULL;

	if (cp == 0 || cp == ' ')
		return NULL;
	for (int i = 0; i < GLYPH_CACHE; i++) {
		struct glyph *s = &t->cache[(idx + i) % GLYPH_CACHE];
		if (s->valid && s->cp == cp && s->bold == bold)
			return s->bmp ? s : NULL;
	}
	for (int i = 0; i < GLYPH_CACHE; i++) {
		struct glyph *s = &t->cache[(idx + i) % GLYPH_CACHE];
		if (!s->valid) {
			g = s;
			break;
		}
	}
	if (!g) {
		glyph_free_all(t);
		g = &t->cache[idx];
	}

	memset(g, 0, sizeof(*g));
	g->cp = cp;
	g->bold = bold;
	g->valid = 1;

	FT_Face face = bold && t->bold_face ? t->bold_face : t->face;
	if (FT_Get_Char_Index(face, cp) == 0) {
		face = NULL;
		for (int i = 0; i < 3; i++) {
			if (t->fallback[i] &&
			    FT_Get_Char_Index(t->fallback[i], cp) != 0) {
				face = t->fallback[i];
				break;
			}
		}
		if (!face)
			return NULL;
	}
	if (FT_Load_Char(face, cp, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0)
		return NULL;
	FT_GlyphSlot slot = face->glyph;
	g->w = (int)slot->bitmap.width;
	g->h = (int)slot->bitmap.rows;
	g->pitch = (int)slot->bitmap.pitch;
	g->left = slot->bitmap_left;
	g->top = slot->bitmap_top;
	g->advance = (int)(slot->advance.x >> 6);
	if (g->w > 0 && g->h > 0) {
		g->bmp = malloc((size_t)g->pitch * (size_t)g->h);
		if (!g->bmp)
			return NULL;
		memcpy(g->bmp, slot->bitmap.buffer,
		       (size_t)g->pitch * (size_t)g->h);
	}
	return g;
}

static uint32_t blend(uint32_t dst, uint32_t src, unsigned alpha)
{
	unsigned dr = (dst >> 16) & 0xff;
	unsigned dg = (dst >> 8) & 0xff;
	unsigned db = dst & 0xff;
	unsigned sr = (src >> 16) & 0xff;
	unsigned sg = (src >> 8) & 0xff;
	unsigned sb = src & 0xff;
	unsigned r = (sr * alpha + dr * (255 - alpha)) / 255;
	unsigned g = (sg * alpha + dg * (255 - alpha)) / 255;
	unsigned b = (sb * alpha + db * (255 - alpha)) / 255;
	return (r << 16) | (g << 8) | b;
}

static void blit_glyph(uint32_t *dst, int stride, int max_w, int max_h,
		       int x, int y, const struct glyph *g, uint32_t fg)
{
	if (!g || !g->bmp)
		return;
	for (int row = 0; row < g->h; row++) {
		int py = y + row;
		if (py < 0 || py >= max_h)
			continue;
		for (int col = 0; col < g->w; col++) {
			int px = x + col;
			unsigned a = g->bmp[(size_t)row * (size_t)g->pitch + col];
			if (!a || px < 0 || px >= max_w)
				continue;
			dst[(size_t)py * (size_t)stride + (size_t)px] =
				blend(dst[(size_t)py * (size_t)stride + (size_t)px],
				      fg, a);
		}
	}
}

/* ---------------------------------------------------------------- damage */

static void add_rect(struct term *t, int buf, int x, int y, int w, int h)
{
	if (w <= 0 || h <= 0)
		return;
	if (t->npending[buf] >= MAX_DIRTY) {
		t->pending[buf][0] = (struct rect){ 0, 0, (int)t->width,
						    (int)t->height };
		t->npending[buf] = 1;
		return;
	}
	t->pending[buf][t->npending[buf]++] = (struct rect){ x, y, w, h };
}

static void mark_cell(struct term *t, int x, int y)
{
	int px = x * t->cell_w;
	int py = y * t->cell_h;
	for (int b = 0; b < 2; b++)
		add_rect(t, b, px, py, t->cell_w, t->cell_h);
}

static void apply_pending(struct term *t, int buf)
{
	for (int i = 0; i < t->npending[buf]; i++) {
		struct rect r = t->pending[buf][i];
		if (r.x < 0) {
			r.w += r.x;
			r.x = 0;
		}
		if (r.y < 0) {
			r.h += r.y;
			r.y = 0;
		}
		if (r.x + r.w > (int)t->width)
			r.w = (int)t->width - r.x;
		if (r.y + r.h > (int)t->height)
			r.h = (int)t->height - r.y;
		if (r.w <= 0 || r.h <= 0)
			continue;
		for (int row = 0; row < r.h; row++) {
			memcpy(t->map[buf] + (size_t)(r.y + row) * t->stride_px + r.x,
			       t->shadow + (size_t)(r.y + row) * t->stride_px + r.x,
			       (size_t)r.w * sizeof(uint32_t));
		}
	}
	t->npending[buf] = 0;
}

/* ---------------------------------------------------------------- render */

static void fill_rect(uint32_t *dst, int stride, int max_w, int max_h,
		      int x, int y, int w, int h, uint32_t color)
{
	if (x < 0) { w += x; x = 0; }
	if (y < 0) { h += y; y = 0; }
	if (x + w > max_w) w = max_w - x;
	if (y + h > max_h) h = max_h - y;
	for (int row = 0; row < h; row++) {
		uint32_t *p = dst + (size_t)(y + row) * stride + x;
		for (int col = 0; col < w; col++)
			p[col] = color;
	}
}

static void paint_cell(struct term *t, int x, int y, int cursor)
{
	if (x < 0 || y < 0 || x >= t->cols || y >= t->rows)
		return;
	struct cell *c = &t->cells[(size_t)y * t->cols + x];
	int px = x * t->cell_w;
	int py = y * t->cell_h;
	uint32_t bg = BG;
	uint32_t fg = 0x00d8dee9;
	uint32_t br = (c->attr.br << 16) | (c->attr.bg << 8) | c->attr.bb;
	uint32_t fr = (c->attr.fr << 16) | (c->attr.fg << 8) | c->attr.fb;

	if (c->valid) {
		bg = br;
		fg = fr;
		if (c->attr.inverse) {
			uint32_t tmp = bg;
			bg = fg;
			fg = tmp;
		}
		if (c->attr.dim) {
			fg = (((fg >> 16) & 0xff) * 2 / 3 << 16) |
			     (((fg >> 8) & 0xff) * 2 / 3 << 8) |
			     ((fg & 0xff) * 2 / 3);
		}
	}
	fill_rect(t->shadow, (int)t->stride_px, (int)t->width, (int)t->height,
		  px, py, t->cell_w, t->cell_h, bg);
	if (c->valid && c->nch > 0 && is_pua((wchar_t)c->ch[0])) {
		struct icon *ic = icon_lookup(t, (wchar_t)c->ch[0]);
		if (ic)
			blit_icon(t, px, py, t->cell_w, t->cell_h, ic);
	} else if (c->valid && c->nch > 0) {
		for (int i = 0; i < c->nch; i++) {
			struct glyph *g = glyph_get(t, c->ch[i], c->attr.bold);
			if (!g || !g->bmp)
				continue;
			int gx = px + g->left;
			int gy = py + t->ascent - g->top;
			if (c->width == 2 && g->w < t->cell_w * 2)
				gx = px + (t->cell_w * 2 - g->w) / 2;
			blit_glyph(t->shadow, (int)t->stride_px,
				   (int)t->width, (int)t->height, gx, gy, g, fg);
		}
	}
	if (c->valid && c->attr.underline)
		fill_rect(t->shadow, (int)t->stride_px, (int)t->width,
			  (int)t->height, px, py + t->cell_h - 2,
			  t->cell_w, 1, fg);
	if (cursor)
		fill_rect(t->shadow, (int)t->stride_px, (int)t->width,
			  (int)t->height, px, py + t->cell_h - 2,
			  t->cell_w, 2, ACCENT);
	mark_cell(t, x, y);
}

static int cell_cb(struct tsm_screen *con, uint64_t id, const uint32_t *ch,
		   size_t len, unsigned int width, unsigned int posx,
		   unsigned int posy, const struct tsm_screen_attr *attr,
		   tsm_age_t age, void *data)
{
	struct term *t = data;
	(void)con; (void)id; (void)age;
	if (posx >= (unsigned)t->cols || posy >= (unsigned)t->rows)
		return 0;
	struct cell *c = &t->cells[(size_t)posy * t->cols + posx];
	int changed = !c->valid || c->nch != (int)len || c->width != width ||
		memcmp(c->ch, ch, (len > MAX_CELL_CH ? MAX_CELL_CH : len) *
		       sizeof(uint32_t)) != 0 ||
		c->attr.fr != attr->fr || c->attr.fg != attr->fg ||
		c->attr.fb != attr->fb || c->attr.br != attr->br ||
		c->attr.bg != attr->bg || c->attr.bb != attr->bb ||
		c->attr.bold != attr->bold || c->attr.dim != attr->dim ||
		c->attr.inverse != attr->inverse ||
		c->attr.underline != attr->underline;
	if (len > MAX_CELL_CH)
		len = MAX_CELL_CH;
	memcpy(c->ch, ch, len * sizeof(uint32_t));
	c->nch = (int)len;
	c->width = width;
	c->attr = *attr;
	c->valid = 1;
	if (changed) {
		paint_cell(t, (int)posx, (int)posy, 0);
		t->dirty = 1;
	}
	return 0;
}

static void page_flip_handler(int fd, unsigned seq, unsigned sec,
			      unsigned usec, void *data)
{
	struct term *t = data;
	(void)fd; (void)seq; (void)sec; (void)usec;
	t->front = t->flip_next;
	t->flip_pending = 0;
	t->dirty = 1;
}

static int present(struct term *t)
{
	if (t->flip_pending)
		return -1;
	int b = 1 - t->front;
	apply_pending(t, b);
	if (drmModePageFlip(t->drm_fd, t->crtc_id, t->fb[b],
			    DRM_MODE_PAGE_FLIP_EVENT, t) < 0) {
		if (errno != EBUSY)
			fprintf(stderr, "cpz-term: page flip: %s\n", strerror(errno));
		/* Put the rects back; the next attempt must not lose them. */
		return -1;
	}
	t->flip_pending = 1;
	t->flip_next = b;
	return 0;
}

static void render_all(struct term *t)
{
	/* Remove the old cursor first; unchanged cells are skipped by cell_cb. */
	if (t->cursor_drawn)
		paint_cell(t, t->cursor_x, t->cursor_y, 0);
	tsm_screen_draw(t->screen, cell_cb, t);
	int cx = (int)tsm_screen_get_cursor_x(t->screen);
	int cy = (int)tsm_screen_get_cursor_y(t->screen);
	t->cursor_x = cx;
	t->cursor_y = cy;
	if (t->cursor_on) {
		paint_cell(t, cx, cy, 1);
		t->cursor_drawn = 1;
	} else {
		t->cursor_drawn = 0;
	}
	t->dirty = 0;
	if (present(t) < 0)
		t->dirty = 1;
}

static void blink_cursor(struct term *t)
{
	if (!t->cursor_drawn && !t->cursor_on)
		return;
	paint_cell(t, t->cursor_x, t->cursor_y, t->cursor_on);
	t->cursor_drawn = t->cursor_on;
	t->dirty = 1;
}

/* ---------------------------------------------------------------- pty */

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
	struct winsize ws = { 0 };
	if (t->master < 0)
		return;
	ws.ws_col = (unsigned short)t->cols;
	ws.ws_row = (unsigned short)t->rows;
	ws.ws_xpixel = (unsigned short)(t->cols * t->cell_w);
	ws.ws_ypixel = (unsigned short)(t->rows * t->cell_h);
	ioctl(t->master, TIOCSWINSZ, &ws);
}

static void child_session(struct term *t)
{
	(void)t;
	const char *home = getenv("HOME");
	setenv("TERM", "xterm-256color", 1);
	setenv("COLORTERM", "truecolor", 1);
	setenv("LANG", "C.UTF-8", 1);
	setenv("LC_ALL", "C.UTF-8", 1);
	setenv("PATH",
	       "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
	if (home)
		chdir(home);
	execl("/bin/sh", "sh", "-c",
	      "exec tmux -L cpz attach-session -t main || "
	      "exec tmux -L cpz new-session -s main || exec /bin/bash -l",
	      (char *)NULL);
	_exit(127);
}

static int start_pty(struct term *t)
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
		child_session(t);
	t->pid = pid;
	int fl = fcntl(t->master, F_GETFL, 0);
	if (fl >= 0)
		fcntl(t->master, F_SETFL, fl | O_NONBLOCK);
	set_winsize(t);
	return 0;
}

static void read_pty(struct term *t)
{
	char buf[65536];
	size_t total = 0;
	for (;;) {
		ssize_t n = read(t->master, buf, sizeof(buf));
		if (n > 0) {
			tsm_vte_input(t->vte, buf, (size_t)n);
			t->dirty = 1;
			total += (size_t)n;
			if (total >= sizeof(buf))
				return;
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

/* ---------------------------------------------------------------- input */

static int modifier_key(xkb_keysym_t sym)
{
	switch (sym) {
	case XKB_KEY_Shift_L: case XKB_KEY_Shift_R:
	case XKB_KEY_Control_L: case XKB_KEY_Control_R:
	case XKB_KEY_Alt_L: case XKB_KEY_Alt_R:
	case XKB_KEY_Meta_L: case XKB_KEY_Meta_R:
	case XKB_KEY_Super_L: case XKB_KEY_Super_R:
	case XKB_KEY_Caps_Lock: case XKB_KEY_Num_Lock:
		return 1;
	default:
		return 0;
	}
}

static int setup_input(struct term *t)
{
	t->xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	if (!t->xkb_ctx)
		return -1;
	const char *path = getenv("CPZ_KEYMAP");
	if (path && *path) {
		FILE *f = fopen(path, "r");
		if (f) {
			t->keymap = xkb_keymap_new_from_file(t->xkb_ctx, f,
					XKB_KEYMAP_FORMAT_TEXT_V1, 0);
			fclose(f);
		}
	}
	if (!t->keymap) {
		struct xkb_rule_names names = {
			.rules = NULL,
			.model = NULL,
			.layout = getenv("XKB_DEFAULT_LAYOUT") ?
				  getenv("XKB_DEFAULT_LAYOUT") : "us,ua",
			.variant = getenv("XKB_DEFAULT_VARIANT"),
			.options = getenv("XKB_DEFAULT_OPTIONS"),
		};
		t->keymap = xkb_keymap_new_from_names(t->xkb_ctx, &names, 0);
	}
	if (!t->keymap)
		return -1;
	t->state = xkb_state_new(t->keymap);
	if (!t->state)
		return -1;

	glob_t g;
	if (glob("/dev/input/event*", 0, NULL, &g) == 0) {
		for (size_t i = 0; i < g.gl_pathc && t->ninput < MAX_INPUT_FDS; i++) {
			int fd = open(g.gl_pathv[i], O_RDONLY | O_NONBLOCK | O_CLOEXEC);
			if (fd >= 0)
				t->input[t->ninput++] = fd;
		}
		globfree(&g);
	}
	return 0;
}

static void handle_key(struct term *t, uint16_t code, int value)
{
	xkb_keycode_t kc = (xkb_keycode_t)(code + 8);
	if (value == 0) {
		xkb_state_update_key(t->state, kc, XKB_KEY_UP);
		return;
	}
	if (value == 1)
		xkb_state_update_key(t->state, kc, XKB_KEY_DOWN);
	xkb_keysym_t sym = xkb_state_key_get_one_sym(t->state, kc);
	if (sym == XKB_KEY_NoSymbol)
		return;
	unsigned mods = 0;
	if (xkb_state_mod_name_is_active(t->state, XKB_MOD_NAME_SHIFT,
					 XKB_STATE_MODS_EFFECTIVE) > 0)
		mods |= TSM_SHIFT_MASK;
	if (xkb_state_mod_name_is_active(t->state, XKB_MOD_NAME_CTRL,
					 XKB_STATE_MODS_EFFECTIVE) > 0)
		mods |= TSM_CONTROL_MASK;
	if (xkb_state_mod_name_is_active(t->state, XKB_MOD_NAME_ALT,
					 XKB_STATE_MODS_EFFECTIVE) > 0)
		mods |= TSM_ALT_MASK;
	if (modifier_key(sym))
		return;
	if (sym == XKB_KEY_q && (mods & TSM_CONTROL_MASK) &&
	    (mods & TSM_SHIFT_MASK)) {
		t->quit = 1;
		return;
	}
	if ((mods & TSM_SHIFT_MASK) && sym == XKB_KEY_Page_Up) {
		tsm_screen_scroll_up(t->screen, (unsigned)t->rows / 2);
		t->dirty = 1;
		return;
	}
	if ((mods & TSM_SHIFT_MASK) && sym == XKB_KEY_Page_Down) {
		tsm_screen_scroll_down(t->screen, (unsigned)t->rows / 2);
		t->dirty = 1;
		return;
	}
	tsm_screen_sb_reset(t->screen);
	uint32_t unicode = xkb_state_key_get_utf32(t->state, kc);
	uint32_t ascii = unicode < 0x80 ? unicode : 0;
	tsm_vte_handle_keyboard(t->vte, (uint32_t)sym, ascii, mods,
				unicode ? unicode : TSM_VTE_INVALID);
	t->dirty = 1;
}

static void read_input(struct term *t, int fd)
{
	struct input_event ev;
	while (read(fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
		if (ev.type == EV_KEY)
			handle_key(t, ev.code, ev.value);
	}
}

/* ---------------------------------------------------------------- DRM */

static int setup_drm(struct term *t)
{
	t->drm_fd = env_int("CPZ_DRM_FD", -1);
	if (t->drm_fd < 0) {
		fprintf(stderr, "cpz-term: CPZ_DRM_FD is missing\n");
		return -1;
	}
	t->width = (uint32_t)env_int("CPZ_FB_WIDTH", 320);
	t->height = (uint32_t)env_int("CPZ_FB_HEIGHT", 170);
	t->stride_px = (uint32_t)env_int("CPZ_FB_STRIDE", (int)(t->width * 4)) / 4;
	t->fb_size = env_u64("CPZ_FB_SIZE", (uint64_t)t->stride_px * t->height * 4);
	t->crtc_id = env_int("CPZ_CRTC_ID", 0);
	t->fb[0] = env_int("CPZ_FB0_ID", 0);
	t->fb[1] = env_int("CPZ_FB1_ID", 0);
	t->offset[0] = env_u64("CPZ_FB0_OFFSET", 0);
	t->offset[1] = env_u64("CPZ_FB1_OFFSET", 0);
	for (int i = 0; i < 2; i++) {
		t->map[i] = mmap(NULL, t->fb_size, PROT_READ | PROT_WRITE,
				 MAP_SHARED, t->drm_fd, (off_t)t->offset[i]);
		if (t->map[i] == MAP_FAILED) {
			fprintf(stderr, "cpz-term: mmap fb%d: %s\n", i,
				strerror(errno));
			return -1;
		}
	}
	t->shadow = calloc(1, t->fb_size);
	if (!t->shadow)
		return -1;
	fill_rect(t->shadow, (int)t->stride_px, (int)t->width, (int)t->height,
		  0, 0, (int)t->width, (int)t->height, BG);
	for (int i = 0; i < 2; i++)
		add_rect(t, i, 0, 0, (int)t->width, (int)t->height);
	t->evctx.version = DRM_EVENT_CONTEXT_VERSION;
	t->evctx.page_flip_handler = page_flip_handler;
	fcntl(t->drm_fd, F_SETFD, FD_CLOEXEC);
	return 0;
}

/* ---------------------------------------------------------------- session */

static int init_vt(struct term *t)
{
	if (tsm_screen_new(&t->screen, NULL, NULL) < 0)
		return -1;
	tsm_screen_set_max_sb(t->screen, 2048);
	tsm_screen_set_flags(t->screen, TSM_SCREEN_HIDE_CURSOR);
	if (tsm_vte_new(&t->vte, t->screen, vte_write_cb, t, NULL, NULL) < 0)
		return -1;
	tsm_vte_set_backspace_sends_delete(t->vte, true);
	tsm_vte_set_custom_palette(t->vte, (uint8_t (*)[3])palette);
	tsm_vte_set_palette(t->vte, "custom");
	return 0;
}

static int alloc_grid(struct term *t)
{
	t->cols = (int)(t->width / (uint32_t)t->cell_w);
	t->rows = (int)(t->height / (uint32_t)t->cell_h);
	if (t->cols < 2) t->cols = 2;
	if (t->rows < 2) t->rows = 2;
	t->cells = calloc((size_t)t->cols * t->rows, sizeof(*t->cells));
	if (!t->cells)
		return -1;
	tsm_screen_resize(t->screen, (unsigned)t->cols, (unsigned)t->rows);
	return 0;
}

static void splash(struct term *t)
{
	fill_rect(t->shadow, (int)t->stride_px, (int)t->width, (int)t->height,
		  0, 0, (int)t->width, (int)t->height, BG);
	/* A tiny wordmark while tmux attaches. */
	const char *s = "cpz";
	int x = ((int)t->width - (int)strlen(s) * t->cell_w * 2) / 2;
	int y = (int)t->height / 2 - t->cell_h;
	for (size_t i = 0; s[i]; i++) {
		struct glyph *g = glyph_get(t, (uint32_t)s[i], 0);
		if (!g || !g->bmp)
			continue;
		blit_glyph(t->shadow, (int)t->stride_px,
			   (int)t->width, (int)t->height,
			   x + (int)i * t->cell_w * 2, y, g, 0x004ea1ff);
	}
	for (int b = 0; b < 2; b++)
		add_rect(t, b, 0, 0, (int)t->width, (int)t->height);
	present(t);
}

static int run_terminal(void)
{
	struct term t;
	int rc = 1;

	memset(&t, 0, sizeof(t));
	t.drm_fd = -1;
	t.master = -1;
	t.heartbeat_fd = -1;
	t.cursor_on = 1;
	t.last_cursor_ms = now_ms();

	signal(SIGPIPE, SIG_IGN);
	if (setup_drm(&t) < 0)
		return 1;
	if (init_font(&t) < 0) {
		fprintf(stderr, "cpz-term: no usable font\n");
		goto out;
	}
	if (init_vt(&t) < 0)
		goto out;
	load_icons(&t);
	if (alloc_grid(&t) < 0)
		goto out;
	if (setup_input(&t) < 0)
		fprintf(stderr, "cpz-term: input unavailable\n");
	splash(&t);
	if (start_pty(&t) < 0) {
		fprintf(stderr, "cpz-term: forkpty: %s\n", strerror(errno));
		goto out;
	}
	t.dirty = 1;

	while (!t.quit) {
		struct pollfd pfd[2 + MAX_INPUT_FDS];
		int nfds = 0;
		int master_idx, drm_idx, input_start;

		pfd[nfds].fd = t.master;
		pfd[nfds].events = POLLIN;
		master_idx = nfds++;
		pfd[nfds].fd = t.drm_fd;
		pfd[nfds].events = POLLIN;
		drm_idx = nfds++;
		input_start = nfds;
		for (int i = 0; i < t.ninput; i++) {
			pfd[nfds].fd = t.input[i];
			pfd[nfds].events = POLLIN;
			nfds++;
		}

		int r = poll(pfd, (nfds_t)nfds, 500);
		if (r < 0 && errno != EINTR) {
			fprintf(stderr, "cpz-term: poll: %s\n", strerror(errno));
			break;
		}
		if (pfd[master_idx].revents & (POLLIN | POLLHUP))
			read_pty(&t);
		if (pfd[drm_idx].revents & POLLIN)
			drmHandleEvent(t.drm_fd, &t.evctx);
		for (int i = 0; i < t.ninput; i++) {
			if (pfd[input_start + i].revents & POLLIN)
				read_input(&t, t.input[i]);
		}
		if (t.out.off < t.out.len)
			out_flush(&t);

		int status;
		if (t.pid > 0 && waitpid(t.pid, &status, WNOHANG) == t.pid)
			t.quit = 1;

		uint64_t ms = now_ms();
		if (ms - t.last_heartbeat_ms >= 1000) {
			if (t.heartbeat_fd < 0)
				t.heartbeat_fd = open("/run/cpz/term.heartbeat",
					O_WRONLY | O_CREAT, 0644);
			if (t.heartbeat_fd >= 0) {
				ftruncate(t.heartbeat_fd, 0);
				(void)write(t.heartbeat_fd, "1", 1);
			}
			t.last_heartbeat_ms = ms;
		}
		if (ms - t.last_cursor_ms >= 500) {
			t.last_cursor_ms = ms;
			t.cursor_on = !t.cursor_on;
			blink_cursor(&t);
			t.dirty = 1;
		}
		if (t.dirty)
			render_all(&t);
	}
	rc = 0;

	if (t.pid > 0) {
		kill(t.pid, SIGHUP);
		waitpid(t.pid, NULL, 0);
	}
out:
	if (t.vte)
		tsm_vte_unref(t.vte);
	if (t.screen)
		tsm_screen_unref(t.screen);
	glyph_free_all(&t);
	free_icons(&t);
	if (t.face) FT_Done_Face(t.face);
	if (t.bold_face) FT_Done_Face(t.bold_face);
	for (int i = 0; i < 3; i++)
		if (t.fallback[i]) FT_Done_Face(t.fallback[i]);
	if (t.ft) FT_Done_FreeType(t.ft);
	if (t.state) xkb_state_unref(t.state);
	if (t.keymap) xkb_keymap_unref(t.keymap);
	if (t.xkb_ctx) xkb_context_unref(t.xkb_ctx);
	for (int i = 0; i < t.ninput; i++)
		if (t.input[i] >= 0) close(t.input[i]);
	if (t.master >= 0) close(t.master);
	if (t.heartbeat_fd >= 0) close(t.heartbeat_fd);
	if (t.shadow) free(t.shadow);
	for (int i = 0; i < 2; i++)
		if (t.map[i] && t.map[i] != MAP_FAILED)
			munmap(t.map[i], t.fb_size);
	free(t.cells);
	free(t.out.data);
	return rc;
}

/* ---------------------------------------------------------------- tests */

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
	if (vte) tsm_vte_unref(vte);
	if (screen) tsm_screen_unref(screen);
	return ok ? 0 : 1;
}

static int headless(const char *path, int cols, int rows)
{
	struct term t;
	int rc = 1;

	memset(&t, 0, sizeof(t));
	t.drm_fd = -1;
	/* A nominal panel-sized surface selects the 10 px font; the real
	 * surface is the grid after the font metrics are known. */
	t.width = 320;
	t.height = 170;
	if (init_font(&t) < 0) {
		fprintf(stderr, "cpz-term: no font\n");
		return 1;
	}
	t.cols = cols;
	t.rows = rows;
	t.width = (uint32_t)(cols * t.cell_w);
	t.height = (uint32_t)(rows * t.cell_h);
	t.stride_px = t.width;
	t.fb_size = (size_t)t.width * t.height * 4;
	t.shadow = calloc(1, t.fb_size);
	if (!t.shadow)
		goto out;
	if (init_vt(&t) < 0)
		goto out;
	t.cells = calloc((size_t)cols * rows, sizeof(*t.cells));
	if (!t.cells)
		goto out;
	tsm_screen_resize(t.screen, (unsigned)cols, (unsigned)rows);
	const char *text = "cpz-term\r\n"
		"Кирилиця: Привіт, світе!\r\n"
		"\033[1;32mok\033[0m \033[38;5;208mcolour\033[0m\r\n";
	tsm_vte_input(t.vte, text, strlen(text));
	fill_rect(t.shadow, (int)t.stride_px, (int)t.width, (int)t.height,
		  0, 0, (int)t.width, (int)t.height, BG);
	tsm_screen_draw(t.screen, cell_cb, &t);
	FILE *f = fopen(path, "wb");
	if (!f)
		goto out;
	fprintf(f, "P6\n%d %d\n255\n", (int)t.width, (int)t.height);
	for (uint32_t y = 0; y < t.height; y++) {
		for (uint32_t x = 0; x < t.width; x++) {
			uint32_t p = t.shadow[(size_t)y * t.stride_px + x];
			unsigned char rgb[3] = {
				(unsigned char)((p >> 16) & 0xff),
				(unsigned char)((p >> 8) & 0xff),
				(unsigned char)(p & 0xff),
			};
			fwrite(rgb, 1, 3, f);
		}
	}
	fclose(f);
	printf("cpz-term: wrote %s (%dx%d)\n", path, (int)t.width,
	       (int)t.height);
	rc = 0;
out:
	if (t.vte) tsm_vte_unref(t.vte);
	if (t.screen) tsm_screen_unref(t.screen);
	glyph_free_all(&t);
	free_icons(&t);
	if (t.face) FT_Done_Face(t.face);
	if (t.bold_face) FT_Done_Face(t.bold_face);
	for (int i = 0; i < 3; i++)
		if (t.fallback[i]) FT_Done_Face(t.fallback[i]);
	if (t.ft) FT_Done_FreeType(t.ft);
	free(t.cells);
	free(t.shadow);
	return rc;
}

static void usage(FILE *out)
{
	fputs("usage: cpz-term [--selftest] [--headless FILE] "
	      "[--cols N] [--rows N] [--probe] [--version]\n", out);
}

int main(int argc, char **argv)
{
	const char *headless_path = NULL;
	int cols = 53, rows = 14;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--selftest"))
			return selftest();
		if (!strcmp(argv[i], "--headless") && i + 1 < argc) {
			headless_path = argv[++i];
		} else if (!strcmp(argv[i], "--cols") && i + 1 < argc) {
			cols = atoi(argv[++i]);
		} else if (!strcmp(argv[i], "--rows") && i + 1 < argc) {
			rows = atoi(argv[++i]);
		} else if (!strcmp(argv[i], "--probe")) {
			printf("drm_fd=%s %dx%d fb0=%s fb1=%s crtc=%s\n",
			       getenv("CPZ_DRM_FD") ?: "-",
			       env_int("CPZ_FB_WIDTH", 0),
			       env_int("CPZ_FB_HEIGHT", 0),
			       getenv("CPZ_FB0_ID") ?: "-",
			       getenv("CPZ_FB1_ID") ?: "-",
			       getenv("CPZ_CRTC_ID") ?: "-");
			return 0;
		} else if (!strcmp(argv[i], "--version")) {
			printf("cpz-term 1.0.0 (drm)\n");
			return 0;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(stdout);
			return 0;
		} else {
			usage(stderr);
			return 2;
		}
	}
	if (headless_path)
		return headless(headless_path, cols, rows);
	return run_terminal();
}
