/*
 * cpz-sdlprobe — hardware probe and display test.
 *
 * It uses the same SDL2/KMSDRM path as the launcher and applications, so a
 * successful run proves that:
 *
 *   - SDL picked the requested DRM card (SDL_KMSDRM_DEVICE_INDEX),
 *   - the panel can be driven through Mesa kms_swrast, or HDMI through vc4,
 *   - input events arrive,
 *   - SDL_ttf can render Unicode (Cyrillic) on that output.
 *
 * Usage:
 *   cpz-sdlprobe                 run the interactive test
 *   cpz-sdlprobe --probe         print cards, displays and modes, no drawing
 *   cpz-sdlprobe --selftest      render one frame in memory, print a checksum
 *   cpz-sdlprobe --seconds N     auto-exit after N seconds (test rigs)
 *
 * Build: gcc -O2 -Wall -Wextra cpz-sdlprobe.c -o cpz-sdlprobe \
 *            $(pkg-config --cflags --libs sdl2 SDL2_ttf)
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>
#include "cpz-sdlmode.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define WIN_W 960
#define WIN_H 540

static uint32_t fnv1a(const void *data, size_t len)
{
	const uint8_t *p = data;
	uint32_t h = 2166136261u;
	for (size_t i = 0; i < len; i++) {
		h ^= p[i];
		h *= 16777619u;
	}
	return h;
}

static const char *font_candidates[] = {
	"/usr/share/fonts/cpz/NotoSans-Regular.ttf",
	"/usr/share/fonts/TTF/PTSans-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu/DejaVuSans.ttf",
	NULL,
};

static TTF_Font *open_font(int px)
{
	const char *env = getenv("CPZ_FONT");
	if (env && *env) {
		TTF_Font *f = TTF_OpenFont(env, px);
		if (f)
			return f;
	}
	for (int i = 0; font_candidates[i]; i++) {
		TTF_Font *f = TTF_OpenFont(font_candidates[i], px);
		if (f) {
			TTF_SetFontHinting(f, TTF_HINTING_MONO);
			return f;
		}
	}
	return NULL;
}

static void draw_text(SDL_Renderer *ren, TTF_Font *font, const char *text,
		      int x, int y, SDL_Color color, int centered, int width)
{
	SDL_Surface *surf;
	SDL_Texture *tex;
	SDL_Rect dst;

	if (!font || !text || !*text)
		return;
	surf = TTF_RenderUTF8_Blended(font, text, color);
	if (!surf)
		return;
	tex = SDL_CreateTextureFromSurface(ren, surf);
	if (!tex) {
		SDL_FreeSurface(surf);
		return;
	}
	dst.w = surf->w;
	dst.h = surf->h;
	dst.x = centered ? (width - dst.w) / 2 : x;
	dst.y = y;
	SDL_RenderCopy(ren, tex, NULL, &dst);
	SDL_DestroyTexture(tex);
	SDL_FreeSurface(surf);
}

static int selftest(void)
{
	const int w = 320, h = 170;
	SDL_Surface *surf;
	SDL_Renderer *ren;
	uint32_t *pixels = NULL;
	int ret = 0;

	if (SDL_Init(0) != 0) {
		fprintf(stderr, "cpz-sdlprobe: SDL_Init: %s\n", SDL_GetError());
		return 1;
	}
	surf = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_ARGB8888);
	if (!surf) {
		fprintf(stderr, "cpz-sdlprobe: surface: %s\n", SDL_GetError());
		SDL_Quit();
		return 1;
	}
	ren = SDL_CreateSoftwareRenderer(surf);
	if (!ren) {
		fprintf(stderr, "cpz-sdlprobe: software renderer: %s\n",
			SDL_GetError());
		SDL_FreeSurface(surf);
		SDL_Quit();
		return 1;
	}

	for (int i = 0; i < 8; i++) {
		SDL_Rect r = { i * w / 8, 0, w / 8 + 1, h * 2 / 3 };
		SDL_SetRenderDrawColor(ren, (i & 1) ? 255 : 0,
				       (i & 2) ? 255 : 0, (i & 4) ? 255 : 0, 255);
		SDL_RenderFillRect(ren, &r);
	}
	SDL_SetRenderDrawColor(ren, 16, 16, 24, 255);
	SDL_Rect bottom = { 0, h * 2 / 3, w, h - h * 2 / 3 };
	SDL_RenderFillRect(ren, &bottom);
	SDL_SetRenderDrawColor(ren, 232, 176, 75, 255);
	SDL_Rect cursor = { w / 2 - 8, h / 2 - 8, 16, 16 };
	SDL_RenderFillRect(ren, &cursor);
	SDL_RenderPresent(ren);

	pixels = malloc((size_t)w * h * 4);
	if (!pixels) {
		ret = 1;
		goto out;
	}
	if (SDL_RenderReadPixels(ren, NULL, SDL_PIXELFORMAT_ARGB8888,
				 pixels, w * 4) != 0) {
		fprintf(stderr, "cpz-sdlprobe: read pixels: %s\n", SDL_GetError());
		ret = 1;
		goto out;
	}
	uint32_t sum = fnv1a(pixels, (size_t)w * h * 4);
	printf("cpz-sdlprobe selftest: %dx%d fnv1a 0x%08x\n", w, h, sum);

	if (TTF_Init() == 0) {
		TTF_Font *font = open_font(18);
		if (font) {
			SDL_Color white = { 255, 255, 255, 255 };
			SDL_Surface *text = TTF_RenderUTF8_Blended(font,
				"Привіт, світе!", white);
			if (text) {
				printf("cpz-sdlprobe font: ok (%dx%d, UTF-8)\n",
				       text->w, text->h);
				SDL_FreeSurface(text);
			} else {
				fprintf(stderr, "cpz-sdlprobe: font render: %s\n",
					TTF_GetError());
				ret = 1;
			}
			TTF_CloseFont(font);
		} else {
			fprintf(stderr, "cpz-sdlprobe: no font found\n");
			ret = 1;
		}
		TTF_Quit();
	} else {
		fprintf(stderr, "cpz-sdlprobe: TTF_Init: %s\n", TTF_GetError());
		ret = 1;
	}
out:
	free(pixels);
	SDL_DestroyRenderer(ren);
	SDL_FreeSurface(surf);
	SDL_Quit();
	return ret;
}

static int probe(void)
{
	int n;

	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		fprintf(stderr, "cpz-sdlprobe: SDL_Init(video): %s\n",
			SDL_GetError());
		return 1;
	}
	printf("SDL video driver: %s\n", SDL_GetCurrentVideoDriver());
	printf("SDL version: %d.%d.%d\n", SDL_MAJOR_VERSION, SDL_MINOR_VERSION,
	       SDL_PATCHLEVEL);
	n = SDL_GetNumVideoDisplays();
	printf("displays: %d\n", n);
	for (int i = 0; i < n; i++) {
		SDL_DisplayMode mode;
		const char *name = SDL_GetDisplayName(i);
		if (SDL_GetCurrentDisplayMode(i, &mode) == 0)
			printf("  %d: %s  %dx%d @ %d Hz  fmt %s\n", i,
			       name ? name : "?", mode.w, mode.h, mode.refresh_rate,
			       SDL_GetPixelFormatName(mode.format));
		else
			printf("  %d: %s  (no mode: %s)\n", i,
			       name ? name : "?", SDL_GetError());
	}
	const char *idx = getenv("SDL_KMSDRM_DEVICE_INDEX");
	printf("SDL_KMSDRM_DEVICE_INDEX: %s\n", idx ? idx : "(unset)");
	printf("CPZ_OUTPUT: %s\n", getenv("CPZ_OUTPUT") ?: "(unset)");
	printf("CPZ_DRM_CARD: %s\n", getenv("CPZ_DRM_CARD") ?: "(unset)");
	SDL_Quit();
	return n > 0 ? 0 : 1;
}

static void draw_scene(SDL_Renderer *ren, TTF_Font *font, int w, int h,
		       uint64_t frame, int info, int fullscreen)
{
	char line[256];
	SDL_Color white = { 240, 240, 240, 255 };
	SDL_Color muted = { 150, 150, 165, 255 };
	SDL_Color accent = { 232, 176, 75, 255 };
	SDL_RendererInfo ri;
	const char *driver = SDL_GetCurrentVideoDriver();
	SDL_DisplayMode mode;
	int lh = font ? TTF_FontLineSkip(font) : 24;
	int top = h / 3 + 16;

	memset(&ri, 0, sizeof(ri));
	memset(&mode, 0, sizeof(mode));

	SDL_SetRenderDrawColor(ren, 14, 14, 22, 255);
	SDL_RenderClear(ren);

	for (int i = 0; i < 8; i++) {
		int bw = w / 8 + 1;
		SDL_Rect r = { i * w / 8, 0, bw, h / 3 };
		SDL_SetRenderDrawColor(ren, (i & 1) ? 220 : 20,
				       (i & 2) ? 220 : 20, (i & 4) ? 220 : 20, 255);
		SDL_RenderFillRect(ren, &r);
	}

	int box = h / 8;
	int x = (int)((frame * 6) % (uint64_t)(w + box)) - box;
	int y = h / 2 - box / 2;
	SDL_SetRenderDrawColor(ren, 232, 176, 75, 255);
	SDL_Rect moving = { x, y, box, box };
	SDL_RenderFillRect(ren, &moving);

	SDL_GetRendererInfo(ren, &ri);
	SDL_GetCurrentDisplayMode(0, &mode);
	snprintf(line, sizeof(line), "CPZ · %s · %dx%d",
		 driver ? driver : "?", mode.w, mode.h);
	draw_text(ren, font, line, 20, top, white, 0, w);
	snprintf(line, sizeof(line), "renderer: %s", ri.name ? ri.name : "?");
	draw_text(ren, font, line, 20, top + lh, muted, 0, w);
	snprintf(line, sizeof(line), "output: %s   card: %s",
		 getenv("CPZ_OUTPUT") ?: "?", getenv("CPZ_DRM_CARD") ?: "?");
	draw_text(ren, font, line, 20, top + 2 * lh, muted, 0, w);
	snprintf(line, sizeof(line), "Кирилиця: Привіт, світе!  ✓");
	draw_text(ren, font, line, 20, top + 3 * lh, accent, 0, w);

	if (info) {
		snprintf(line, sizeof(line),
			 "q/esc вихід · f fullscreen (%s) · i info · s screenshot",
			 fullscreen ? "on" : "off");
		draw_text(ren, font, line, 20, h - lh - 16, muted, 0, w);
	}
	SDL_RenderPresent(ren);
}

static int interactive(int seconds)
{
	SDL_Window *win = NULL;
	SDL_Renderer *ren = NULL;
	TTF_Font *font = NULL;
	SDL_Event ev;
	int w = WIN_W, h = WIN_H;
	int info = 1, fullscreen = 0, running = 1;
	uint64_t start = SDL_GetTicks64();
	uint64_t frame = 0;
	int rc = 1;

	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_TIMER) != 0) {
		fprintf(stderr, "cpz-sdlprobe: SDL_Init: %s\n", SDL_GetError());
		return 1;
	}
	SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "1");
	SDL_ShowCursor(SDL_DISABLE);

	win = SDL_CreateWindow("cpz-sdlprobe", SDL_WINDOWPOS_CENTERED,
			       SDL_WINDOWPOS_CENTERED, w, h, SDL_WINDOW_SHOWN);
	if (!win) {
		fprintf(stderr, "cpz-sdlprobe: window: %s\n", SDL_GetError());
		goto out;
	}
	cpz_apply_display_mode(win);
	ren = SDL_CreateRenderer(win, -1,
				 SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
	if (!ren) {
		fprintf(stderr, "cpz-sdlprobe: accelerated renderer failed: %s; "
			"trying software\n", SDL_GetError());
		ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
	}
	if (!ren)
		ren = SDL_CreateRenderer(win, -1, 0);
	if (!ren) {
		fprintf(stderr, "cpz-sdlprobe: renderer: %s\n", SDL_GetError());
		goto out;
	}
	if (TTF_Init() == 0) {
		int rw = 0, rh = 0;
		SDL_GetRendererOutputSize(ren, &rw, &rh);
		font = open_font(rh >= 700 ? 28 : (rh >= 400 ? 18 : 12));
	} else {
		fprintf(stderr, "cpz-sdlprobe: TTF_Init: %s\n", TTF_GetError());
	}

	SDL_RendererInfo ri;
	SDL_GetRendererInfo(ren, &ri);
	printf("cpz-sdlprobe: driver=%s renderer=%s output=%s card=%s\n",
	       SDL_GetCurrentVideoDriver(), ri.name ? ri.name : "?",
	       getenv("CPZ_OUTPUT") ?: "?", getenv("CPZ_DRM_CARD") ?: "?");

	while (running) {
		while (SDL_PollEvent(&ev)) {
			if (ev.type == SDL_QUIT) {
				running = 0;
			} else if (ev.type == SDL_KEYDOWN) {
				switch (ev.key.keysym.sym) {
				case SDLK_q:
				case SDLK_ESCAPE:
					running = 0;
					break;
				case SDLK_f:
					fullscreen = !fullscreen;
					SDL_SetWindowFullscreen(win, fullscreen ?
						SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
					break;
				case SDLK_i:
					info = !info;
					break;
				case SDLK_s: {
					int rw, rh;
					SDL_GetRendererOutputSize(ren, &rw, &rh);
					SDL_Surface *shot = SDL_CreateRGBSurfaceWithFormat(
						0, rw, rh, 32, SDL_PIXELFORMAT_ARGB8888);
					if (shot &&
					    SDL_RenderReadPixels(ren, NULL,
						SDL_PIXELFORMAT_ARGB8888,
						shot->pixels, shot->pitch) == 0) {
						SDL_SaveBMP(shot, "/tmp/cpz-sdlprobe.bmp");
						printf("screenshot: /tmp/cpz-sdlprobe.bmp\n");
					}
					SDL_FreeSurface(shot);
					break;
				}
				default:
					break;
				}
			}
		}

		SDL_GetRendererOutputSize(ren, &w, &h);
		draw_scene(ren, font, w, h, frame++, info, fullscreen);
		if (seconds > 0 && SDL_GetTicks64() - start >= (uint64_t)seconds * 1000)
			running = 0;
		SDL_Delay(16);
	}
	rc = 0;
out:
	if (font)
		TTF_CloseFont(font);
	if (TTF_WasInit())
		TTF_Quit();
	if (ren)
		SDL_DestroyRenderer(ren);
	if (win)
		SDL_DestroyWindow(win);
	SDL_Quit();
	return rc;
}

static void usage(FILE *out)
{
	fputs("usage: cpz-sdlprobe [--probe|--selftest|--seconds N] [--version]\n",
	      out);
}

int main(int argc, char **argv)
{
	int seconds = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--selftest"))
			return selftest();
		if (!strcmp(argv[i], "--probe"))
			return probe();
		if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
			seconds = atoi(argv[++i]);
			continue;
		}
		if (!strcmp(argv[i], "--version")) {
			printf("cpz-sdlprobe 0.2.0\n");
			return 0;
		}
		if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(stdout);
			return 0;
		}
		usage(stderr);
		return 2;
	}
	return interactive(seconds);
}
