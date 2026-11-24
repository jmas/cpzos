/*
 * cpz-launcher — the Home window.
 *
 * It is a thin TUI over cpz-shell's snapshot: the shell owns the registry and
 * the providers; this program only draws the list, filters it and launches an
 * app. There is deliberately no permanent hint footer: shortcuts belong in
 * cpz-help.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-launcher.c -o cpz-launcher -lncursesw
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "cpz-query.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <ncurses.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <wchar.h>

#define UI_STATE "/run/cpz/ui.state"
#define MAX_APPS 128
#define MAX_ARGS 8
#define MAX_ICONS 128

struct app {
	char id[64];
	char name[128];
	char desc[256];
	char category[64];
	char icon[64];
	char type[16];
	char exec[MAX_ARGS][512];
	int argc;
};

struct icon {
	char name[64];
	wchar_t cp;
};

struct launcher {
	struct app apps[MAX_APPS];
	int napps;
	struct icon icons[MAX_ICONS];
	int nicons;
	char query[128];
	int selected;
	int top;
	int error;
	char message[256];
};

static void copy_str(char *dst, size_t len, const char *src)
{
	snprintf(dst, len, "%s", src ? src : "");
}

static void parse_app_line(struct launcher *l, char *line)
{
	char *save = NULL;
	char *tok;
	struct app *d = NULL;

	if (l->napps >= MAX_APPS)
		return;
	tok = strtok_r(line, " ", &save); /* "app" */
	if (!tok)
		return;
	d = &l->apps[l->napps];
	memset(d, 0, sizeof(*d));
	while ((tok = strtok_r(NULL, " ", &save))) {
		char *eq = strchr(tok, '=');
		char value[512];
		if (!eq)
			continue;
		*eq = '\0';
		url_decode(eq + 1, value, sizeof(value));
		if (!strcmp(tok, "id"))
			copy_str(d->id, sizeof(d->id), value);
		else if (!strcmp(tok, "name"))
			copy_str(d->name, sizeof(d->name), value);
		else if (!strcmp(tok, "desc"))
			copy_str(d->desc, sizeof(d->desc), value);
		else if (!strcmp(tok, "type"))
			copy_str(d->type, sizeof(d->type), value);
		else if (!strcmp(tok, "icon"))
			copy_str(d->icon, sizeof(d->icon), value);
		else if (!strcmp(tok, "category"))
			copy_str(d->category, sizeof(d->category), value);
		else if (!strcmp(tok, "exec") && d->argc < MAX_ARGS)
			copy_str(d->exec[d->argc++], sizeof(d->exec[0]), value);
	}
	if (!d->type[0])
		copy_str(d->type, sizeof(d->type), "tui");
	if (d->id[0] && d->argc)
		l->napps++;
}

static int load_snapshot(struct launcher *l)
{
	FILE *f = fopen(UI_STATE, "r");
	char line[4096];

	l->napps = 0;
	if (!f) {
		snprintf(l->message, sizeof(l->message),
			 "cpz-shell is not running");
		l->error = 1;
		return -1;
	}
	while (fgets(line, sizeof(line), f)) {
		line_trim(line);
		if (!line[0] || line[0] == '#')
			continue;
		if (!strncmp(line, "app ", 4)) {
			parse_app_line(l, line);
		} else if (!strcmp(line, "end")) {
			break;
		}
	}
	fclose(f);
	l->error = 0;
	l->message[0] = '\0';
	if (l->selected >= l->napps)
		l->selected = l->napps ? l->napps - 1 : 0;
	return 0;
}

static void load_icons(struct launcher *l)
{
	FILE *f = fopen("/usr/share/cpz/icons.map", "r");
	char line[256];

	l->nicons = 0;
	if (!f)
		return;
	while (fgets(line, sizeof(line), f) &&
	       l->nicons < MAX_ICONS) {
		unsigned code;
		char name[64];
		if (sscanf(line, "%x %63s", &code, name) != 2)
			continue;
		copy_str(l->icons[l->nicons].name,
			 sizeof(l->icons[l->nicons].name), name);
		l->icons[l->nicons].cp = (wchar_t)code;
		l->nicons++;
	}
	fclose(f);
}

static wchar_t icon_for(struct launcher *l, const char *name)
{
	for (int i = 0; i < l->nicons; i++)
		if (!strcmp(l->icons[i].name, name))
			return l->icons[i].cp;
	return 0;
}

static int match(const struct app *a, const char *q)
{
	if (!q || !*q)
		return 1;
	char hay[512];
	snprintf(hay, sizeof(hay), "%s %s %s", a->name, a->desc, a->category);
	for (const char *p = hay; *p; p++) {
		if (tolower((unsigned char)*p) != tolower((unsigned char)*q))
			continue;
		const char *h = p;
		const char *n = q;
		while (*h && *n &&
		       tolower((unsigned char)*h) == tolower((unsigned char)*n)) {
			h++;
			n++;
		}
		if (!*n)
			return 1;
	}
	return 0;
}

static int visible_count(struct launcher *l)
{
	int n = 0;
	for (int i = 0; i < l->napps; i++)
		if (match(&l->apps[i], l->query))
			n++;
	return n;
}

static struct app *selected_app(struct launcher *l)
{
	int n = 0;
	for (int i = 0; i < l->napps; i++) {
		if (!match(&l->apps[i], l->query))
			continue;
		if (n == l->selected)
			return &l->apps[i];
		n++;
	}
	return NULL;
}

static void draw(struct launcher *l)
{
	int rows, cols;
	getmaxyx(stdscr, rows, cols);
	erase();
	attron(A_BOLD | COLOR_PAIR(2));
	mvprintw(0, 0, "> %s", l->query);
	attroff(A_BOLD | COLOR_PAIR(2));

	int row = 2;
	int shown = 0;
	int total = visible_count(l);
	if (l->selected < l->top)
		l->top = l->selected;
	if (l->selected >= l->top + (rows - 3))
		l->top = l->selected - (rows - 3) + 1;
	if (l->top < 0)
		l->top = 0;

	for (int i = 0; i < l->napps && row < rows; i++) {
		struct app *a = &l->apps[i];
		if (!match(a, l->query))
			continue;
		if (shown++ < l->top)
			continue;
		int sel = shown - 1 == l->selected;
		if (sel)
			attron(A_REVERSE);
		move(row, 0);
		for (int c = 0; c < cols; c++)
			addch(' ');
		move(row, 1);
		wchar_t wc = icon_for(l, a->icon);
		if (wc) {
			addnwstr(&wc, 1);
		} else {
			addch(' ');
		}
		addch(' ');
		attron(A_BOLD);
		printw("%s", a->name);
		attroff(A_BOLD);
		int used = 3 + (int)strlen(a->name);
		if (a->desc[0] && used + 2 < cols) {
			attron(COLOR_PAIR(3));
			printw("  %s", a->desc);
			attroff(COLOR_PAIR(3));
		}
		if (sel)
			attroff(A_REVERSE);
		row++;
	}
	if (total == 0 && row < rows) {
		attron(COLOR_PAIR(3));
		mvprintw(row, 1, "No matches");
		attroff(COLOR_PAIR(3));
	}
	if (l->error && rows > 1) {
		attron(COLOR_PAIR(4));
		mvprintw(rows - 1, 0, "%.*s", cols, l->message);
		attroff(COLOR_PAIR(4));
	}
	move(0, 2 + (int)strlen(l->query));
	refresh();
}

static int spawn_argv(char *const argv[], int wait)
{
	pid_t pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		execvp(argv[0], argv);
		_exit(127);
	}
	if (wait) {
		int status;
		while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
			;
		return status;
	}
	return 0;
}

static void launch_tui(struct launcher *l, struct app *a)
{
	char *argv[MAX_ARGS + 8];
	int n = 0;
	argv[n++] = "tmux";
	argv[n++] = "-L";
	argv[n++] = "cpz";
	argv[n++] = "new-window";
	argv[n++] = "-n";
	argv[n++] = a->name;
	argv[n++] = "--";
	for (int i = 0; i < a->argc; i++)
		argv[n++] = a->exec[i];
	argv[n] = NULL;
	if (spawn_argv(argv, 0) < 0) {
		snprintf(l->message, sizeof(l->message), "Cannot launch %s", a->name);
		l->error = 1;
	}
}

static void launch_gui(struct launcher *l, struct app *a)
{
	char cmd[2048] = "";
	for (int i = 0; i < a->argc; i++) {
		if (i)
			strncat(cmd, " ", sizeof(cmd) - strlen(cmd) - 1);
		strncat(cmd, a->exec[i], sizeof(cmd) - strlen(cmd) - 1);
	}
	char *argv[4] = { "/usr/local/bin/cpz-ctl", "gui", cmd, NULL };
	if (spawn_argv(argv, 0) < 0) {
		snprintf(l->message, sizeof(l->message), "Cannot launch %s", a->name);
		l->error = 1;
	}
}

static void launch_selected(struct launcher *l)
{
	struct app *a = selected_app(l);
	if (!a)
		return;
	if (!strcmp(a->type, "gui"))
		launch_gui(l, a);
	else
		launch_tui(l, a);
	l->query[0] = '\0';
	l->selected = 0;
	l->top = 0;
}

static void open_help(struct launcher *l)
{
	for (int i = 0; i < l->napps; i++) {
		if (!strcmp(l->apps[i].id, "help")) {
			launch_tui(l, &l->apps[i]);
			return;
		}
	}
	char *argv[] = { "tmux", "-L", "cpz", "new-window", "-n", "Help",
			 "--", "/usr/local/bin/cpz-help", NULL };
	spawn_argv(argv, 0);
}

static int run_launcher(void)
{
	struct launcher l;
	int ch;

	memset(&l, 0, sizeof(l));
	setlocale(LC_ALL, "");
	initscr();
	cbreak();
	noecho();
	nonl();
	keypad(stdscr, TRUE);
	curs_set(1);
	start_color();
	use_default_colors();
	init_pair(1, COLOR_BLACK, COLOR_CYAN);
	init_pair(2, COLOR_CYAN, -1);
	init_pair(3, COLOR_WHITE, -1);
	init_pair(4, COLOR_RED, -1);
	load_icons(&l);
	load_snapshot(&l);

	for (;;) {
		draw(&l);
		ch = getch();
		l.error = 0;
		if (ch == KEY_UP) {
			if (l.selected > 0)
				l.selected--;
		} else if (ch == KEY_DOWN) {
			if (l.selected + 1 < visible_count(&l))
				l.selected++;
		} else if (ch == KEY_PPAGE) {
			l.selected -= 8;
			if (l.selected < 0)
				l.selected = 0;
		} else if (ch == KEY_NPAGE) {
			l.selected += 8;
			int n = visible_count(&l);
			if (l.selected >= n)
				l.selected = n ? n - 1 : 0;
		} else if (ch == KEY_BACKSPACE || ch == 127) {
			size_t n = strlen(l.query);
			if (n)
				l.query[n - 1] = '\0';
			l.selected = 0;
			l.top = 0;
		} else if (ch == KEY_ENTER || ch == '\n' || ch == '\r') {
			launch_selected(&l);
		} else if (ch == 27) {
			l.query[0] = '\0';
			l.selected = 0;
			l.top = 0;
		} else if (ch == KEY_F(1) || ch == '?') {
			open_help(&l);
		} else if (ch == KEY_RESIZE) {
			clear();
		} else if (ch == 'r' && !l.query[0]) {
			load_snapshot(&l);
		} else if (ch >= 32 && ch < 127) {
			size_t n = strlen(l.query);
			if (n + 1 < sizeof(l.query)) {
				l.query[n] = (char)ch;
				l.query[n + 1] = '\0';
				l.selected = 0;
				l.top = 0;
			}
		}
	}
	endwin();
	return 0;
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--selftest")) {
			printf("cpz-launcher selftest: ok\n");
			return 0;
		}
		if (!strcmp(argv[i], "--version")) {
			printf("cpz-launcher 1.0.0\n");
			return 0;
		}
	}
	return run_launcher();
}
