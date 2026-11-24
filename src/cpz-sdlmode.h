/*
 * Small shared helper: pick a sane fullscreen mode instead of inheriting the
 * current fbdev mode. On vc4 the kernel can leave the connector at 720x400
 * (a VGA text mode) even when the monitor advertises 1080p; SDL's
 * FULLSCREEN_DESKTOP then keeps that mode and the monitor shows nothing.
 *
 * Rule: largest progressive-ish mode up to 1080p, at least 320x170. This
 * covers both the SPI panel (only 320x170) and HDMI (prefer 1080p, cap at
 * 1080p so text stays readable on 4K monitors).
 */
#ifndef CPZ_SDLMODE_H
#define CPZ_SDLMODE_H

#include <SDL2/SDL.h>
#include <stdlib.h>
#include <string.h>

static int cpz_pick_display_mode(int display, SDL_DisplayMode *out)
{
	int n = SDL_GetNumDisplayModes(display);
	SDL_DisplayMode best;
	int have = 0;

	for (int i = 0; i < n; i++) {
		SDL_DisplayMode m;
		if (SDL_GetDisplayMode(display, i, &m) != 0)
			continue;
		if (m.w > 1920 || m.h > 1080)
			continue;
		if (m.w < 320 || m.h < 170)
			continue;
		if (!have) {
			best = m;
			have = 1;
			continue;
		}
		long area = (long)m.w * m.h;
		long best_area = (long)best.w * best.h;
		if (area > best_area ||
		    (area == best_area && m.refresh_rate > best.refresh_rate))
			best = m;
	}
	if (have)
		*out = best;
	return have;
}

static void cpz_apply_display_mode(SDL_Window *win)
{
	SDL_DisplayMode mode;
	if (cpz_pick_display_mode(0, &mode) &&
	    SDL_SetWindowDisplayMode(win, &mode) == 0 &&
	    SDL_SetWindowFullscreen(win, SDL_WINDOW_FULLSCREEN) == 0)
		return;
	SDL_SetWindowFullscreen(win, SDL_WINDOW_FULLSCREEN_DESKTOP);
}

/*
 * The SPI panel has no render node: "accelerated" there means Mesa's
 * kms_swrast, which loads the Gallium/LLVM stack (~220 MiB of libraries) and
 * JIT-compiles a blit shader for a 320x170 menu. Ask for the SDL software
 * renderer directly when the supervisor says the output is the panel; HDMI
 * keeps GLES. CPZ_RENDERER=software|accelerated overrides the choice.
 */
static inline int cpz_wants_software_renderer(void)
{
	const char *want = getenv("CPZ_RENDERER");
	const char *out = getenv("CPZ_OUTPUT");

	if (want && *want)
		return strcmp(want, "software") == 0;
	return out && strcmp(out, "panel") == 0;
}

static inline SDL_Renderer *cpz_create_renderer(SDL_Window *win)
{
	SDL_Renderer *ren = NULL;

	if (cpz_wants_software_renderer())
		ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
	if (!ren)
		ren = SDL_CreateRenderer(win, -1,
					 SDL_RENDERER_ACCELERATED |
					 SDL_RENDERER_PRESENTVSYNC);
	if (!ren)
		ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
	if (!ren)
		ren = SDL_CreateRenderer(win, -1, 0);
	return ren;
}

#endif
