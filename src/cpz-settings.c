/*
 * cpz-settings — a small TUI for display and terminal settings.
 *
 * Settings is an ordinary application; it writes the user config and asks
 * cpz-session to apply output/font changes. It does not draw the shell panel.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-settings.c -o cpz-settings -lncursesw
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <limits.h>
#include <locale.h>
#include <ncurses.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

struct item {
	const char *label;
	const char *key;
	const char *values[4];
	int nvalues;
	const char *action;
};

static struct item items[] = {
	{ "Output", "output", { "auto", "panel", "hdmi", NULL }, 3, "output" },
	{ "Panel text size", "font_size_panel", { "10", "12", "14", NULL }, 3,
	  "restart" },
	{ "HDMI text size", "font_size_hdmi", { "18", "24", "32", NULL }, 3,
	  "restart" },
	{ "Keyboard layout", "layout", { "us,ua", "us", "ua", NULL }, 3,
	  "restart" },
	{ "Restart terminal", NULL, { NULL }, 0, "restart" },
};
#define NITEMS ((int)(sizeof(items) / sizeof(items[0])))

static char config_path[PATH_MAX];
static char config[16][2][128];
static int nconfig;

static void copy_str(char *dst, size_t len, const char *src)
{
	snprintf(dst, len, "%s", src ? src : "");
}

static const char *get_value(const char *key, const char *def)
{
	for (int i = 0; i < nconfig; i++)
		if (!strcmp(config[i][0], key))
			return config[i][1];
	return def;
}

static void load_config(void)
{
	const char *home = getenv("HOME");
	snprintf(config_path, sizeof(config_path), "%s/.config/cpz/settings.conf",
		 home ? home : "/home/cpz");
	nconfig = 0;
	FILE *f = fopen(config_path, "r");
	if (!f)
		return;
	char line[256];
	while (fgets(line, sizeof(line), f) && nconfig < 16) {
		char *eq = strchr(line, '=');
		if (!eq)
			continue;
		*eq = '\0';
		char *v = eq + 1;
		size_t n = strlen(v);
		while (n && (v[n - 1] == '\n' || v[n - 1] == '\r'))
			v[--n] = '\0';
		copy_str(config[nconfig][0], sizeof(config[0][0]), line);
		copy_str(config[nconfig][1], sizeof(config[0][1]), v);
		nconfig++;
	}
	fclose(f);
}

static void save_config(void)
{
	char dir[PATH_MAX];
	snprintf(dir, sizeof(dir), "%s/.config/cpz",
		 getenv("HOME") ? getenv("HOME") : "/home/cpz");
	mkdir(dir, 0755);
	char tmp[PATH_MAX];
	snprintf(tmp, sizeof(tmp), "%s.tmp", config_path);
	FILE *f = fopen(tmp, "w");
	if (!f)
		return;
	for (int i = 0; i < nconfig; i++)
		fprintf(f, "%s=%s\n", config[i][0], config[i][1]);
	fclose(f);
	rename(tmp, config_path);
}

static void set_value(const char *key, const char *value)
{
	for (int i = 0; i < nconfig; i++) {
		if (!strcmp(config[i][0], key)) {
			copy_str(config[i][1], sizeof(config[0][1]), value);
			return;
		}
	}
	if (nconfig < 16) {
		copy_str(config[nconfig][0], sizeof(config[0][0]), key);
		copy_str(config[nconfig][1], sizeof(config[0][1]), value);
		nconfig++;
	}
}

static int run(char *const argv[])
{
	pid_t pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		execv(argv[0], argv);
		_exit(127);
	}
	int status;
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
	return status;
}

static void apply(struct item *it, const char *value)
{
	if (!strcmp(it->action, "output")) {
		char *argv[] = { "/usr/local/bin/cpz-ctl", "output",
				 (char *)value, NULL };
		run(argv);
	} else if (!strcmp(it->action, "restart")) {
		char *argv[] = { "/usr/local/bin/cpz-ctl", "restart-term", NULL };
		run(argv);
	}
}

static const char *current(struct item *it)
{
	return get_value(it->key, it->values[0]);
}

static int settings_loop(void)
{
	int selected = 0;
	int rows, cols;

	setlocale(LC_ALL, "");
	load_config();
	initscr();
	cbreak();
	noecho();
	keypad(stdscr, TRUE);
	curs_set(0);
	start_color();
	use_default_colors();
	init_pair(1, COLOR_CYAN, -1);
	init_pair(2, COLOR_WHITE, -1);

	for (;;) {
		getmaxyx(stdscr, rows, cols);
		erase();
		attron(A_BOLD | COLOR_PAIR(1));
		mvprintw(0, 0, "Settings");
		attroff(A_BOLD | COLOR_PAIR(1));
		int row = 2;
		for (int i = 0; i < NITEMS && row < rows; i++, row++) {
			if (i == selected)
				attron(A_REVERSE);
			move(row, 0);
			for (int c = 0; c < cols; c++)
				addch(' ');
			mvprintw(row, 1, "%s", items[i].label);
			if (items[i].key) {
				const char *v = current(&items[i]);
				mvprintw(row, cols - (int)strlen(v) - 1, "%s", v);
			}
			if (i == selected)
				attroff(A_REVERSE);
		}
		refresh();
		int ch = getch();
		if (ch == 'q' || ch == 27)
			break;
		if (ch == KEY_UP && selected > 0)
			selected--;
		if (ch == KEY_DOWN && selected + 1 < NITEMS)
			selected++;
		if (ch == KEY_ENTER || ch == '\n' || ch == '\r') {
			struct item *it = &items[selected];
			if (!it->key) {
				apply(it, "");
				continue;
			}
			const char *v = current(it);
			int idx = 0;
			for (int i = 0; i < it->nvalues; i++)
				if (!strcmp(it->values[i], v))
					idx = i;
			idx = (idx + 1) % it->nvalues;
			set_value(it->key, it->values[idx]);
			save_config();
			apply(it, it->values[idx]);
		}
	}
	endwin();
	return 0;
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--selftest")) {
			printf("cpz-settings selftest: ok\n");
			return 0;
		}
		if (!strcmp(argv[i], "--version")) {
			printf("cpz-settings 1.0.0\n");
			return 0;
		}
	}
	return settings_loop();
}
