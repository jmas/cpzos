/*
 * cpz-help — the single place for shortcuts and instructions.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-help.c -o cpz-help -lncursesw
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <locale.h>
#include <ncurses.h>
#include <stdio.h>
#include <string.h>

static const char *lines[] = {
	"CPZ Help",
	"",
	"Getting around",
	"  Alt+Space      Home / command palette",
	"  Alt+T          New Home window",
	"  Alt+W          Close current window",
	"  Alt+1 … Alt+9  Switch to a window",
	"  Alt+Tab        Next window",
	"  Alt+H or ?     This help",
	"",
	"Home",
	"  Type           Filter applications",
	"  Up / Down      Move selection",
	"  Enter          Open",
	"  Esc            Clear filter",
	"  r              Reload the application list (empty filter)",
	"",
	"Terminal",
	"  Ctrl+Shift+Q   Close the terminal session (it restarts)",
	"  Shift+PgUp     Scroll back",
	"  Shift+PgDn     Scroll forward",
	"  tmux           Ctrl+a is the advanced prefix",
	"",
	"Applications",
	"  q / Esc        Close the current app",
	"  Settings       Display, input, power, language",
	"  Battery        Charge, voltage, health",
	"  Network        Wi-Fi and Ethernet",
	"  Sound          ALSA mixer",
	"  Files          nnn",
	"  Editor         vim",
	"",
	"System",
	"  The panel shows battery, network, volume and time.",
	"  Applications register themselves with a manifest.",
	"  Settings and Battery are ordinary applications.",
	"",
	"  Esc / q        Close help",
	NULL,
};

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--selftest")) {
			printf("cpz-help selftest: ok\n");
			return 0;
		}
		if (!strcmp(argv[i], "--version")) {
			printf("cpz-help 1.0.0\n");
			return 0;
		}
	}
	setlocale(LC_ALL, "");
	initscr();
	cbreak();
	noecho();
	keypad(stdscr, TRUE);
	curs_set(0);
	start_color();
	use_default_colors();
	init_pair(1, COLOR_CYAN, -1);
	init_pair(2, COLOR_WHITE, -1);

	int total = 0;
	while (lines[total])
		total++;
	int top = 0;
	for (;;) {
		int rows, cols;
		getmaxyx(stdscr, rows, cols);
		erase();
		attron(A_BOLD | COLOR_PAIR(1));
		mvprintw(0, 0, "Help");
		attroff(A_BOLD | COLOR_PAIR(1));
		for (int i = 0; i < rows - 2 && top + i < total; i++) {
			const char *line = lines[top + i];
			if (i == 0 && top == 0)
				continue;
			if (line[0] && line[1] != ' ') {
				attron(A_BOLD);
				mvprintw(i + 1, 1, "%.*s", cols - 1, line);
				attroff(A_BOLD);
			} else {
				mvprintw(i + 1, 1, "%.*s", cols - 1, line);
			}
		}
		attron(COLOR_PAIR(1));
		mvprintw(rows - 1, 0, "Esc/q close");
		attroff(COLOR_PAIR(1));
		refresh();
		int ch = getch();
		if (ch == 'q' || ch == 27)
			break;
		if (ch == KEY_DOWN || ch == KEY_NPAGE)
			top += (ch == KEY_NPAGE ? 8 : 1);
		if (ch == KEY_UP || ch == KEY_PPAGE)
			top -= (ch == KEY_PPAGE ? 8 : 1);
		if (top > total - 1)
			top = total - 1;
		if (top < 0)
			top = 0;
	}
	endwin();
	return 0;
}
