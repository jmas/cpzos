/*
 * Give cage a fresh XKB keymap without restarting the compositor.
 *
 * cage 0.3.1 calls xkb_keymap_new_from_names(context, NULL, ...) whenever a
 * keyboard is added. wlroots keeps the environment of a running process, so a
 * new layout would normally require a new cage and a full screen refresh.
 *
 * This shim intercepts that call and fills the layout from the file
 * cpz-keyboard-layout already publishes for cage. A udev remove/add of the
 * keyboard devices then makes cage create a new keymap in place; the tmux
 * session, foot window, DRM mode and screen stay untouched.
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STATE_FILE "/run/cpz-layout.xkb"

struct xkb_context;
struct xkb_keymap;

/* Public ABI of libxkbcommon; the opaque types are enough here. */
struct xkb_rule_names {
	const char *rules;
	const char *model;
	const char *layout;
	const char *variant;
	const char *options;
};

typedef struct xkb_keymap *(*new_from_names_fn)(
	struct xkb_context *context,
	const struct xkb_rule_names *names,
	int flags);

static new_from_names_fn resolve_new_from_names(void)
{
	static new_from_names_fn real;

	if (real == NULL) {
		real = (new_from_names_fn)dlsym(RTLD_NEXT,
			"xkb_keymap_new_from_names");
	}
	return real;
}

static int valid_layout(const char *layout)
{
	if (*layout == '\0') {
		return 0;
	}
	for (const char *p = layout; *p != '\0'; p++) {
		if (!isalnum((unsigned char)*p) && *p != '_' && *p != '-' &&
			*p != ',') {
			return 0;
		}
	}
	return 1;
}

static int read_state(char *layout, size_t layout_size, char *variant,
	size_t variant_size)
{
	FILE *handle;
	char line[256];
	int found = 0;

	handle = fopen(STATE_FILE, "r");
	if (handle == NULL) {
		return 0;
	}
	while (fgets(line, sizeof(line), handle) != NULL) {
		char *value = strchr(line, '=');

		if (value == NULL) {
			continue;
		}
		*value++ = '\0';
		value[strcspn(value, "\r\n")] = '\0';
		if (strcmp(line, "layout") == 0) {
			snprintf(layout, layout_size, "%s", value);
			found = 1;
		} else if (strcmp(line, "variant") == 0) {
			snprintf(variant, variant_size, "%s", value);
		}
	}
	fclose(handle);
	return found && valid_layout(layout);
}

struct xkb_keymap *xkb_keymap_new_from_names(
	struct xkb_context *context,
	const struct xkb_rule_names *names,
	int flags)
{
	new_from_names_fn real = resolve_new_from_names();
	char layout[64] = {0};
	char variant[64] = {0};
	struct xkb_rule_names copy;

	if (real == NULL) {
		return NULL;
	}
	if (names != NULL) {
		return real(context, names, flags);
	}
	if (!read_state(layout, sizeof(layout), variant, sizeof(variant))) {
		return real(context, names, flags);
	}

	copy.rules = getenv("XKB_DEFAULT_RULES");
	copy.model = getenv("XKB_DEFAULT_MODEL");
	copy.layout = layout;
	copy.variant = variant[0] != '\0' ? variant : NULL;
	copy.options = getenv("XKB_DEFAULT_OPTIONS");
	return real(context, &copy, flags);
}
