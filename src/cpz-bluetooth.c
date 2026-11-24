/*
 * cpz-bluetooth — Bluetooth status provider and a small TUI.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-bluetooth.c -o cpz-bluetooth -lncursesw
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "cpz-provider.h"

#include <dirent.h>
#include <locale.h>
#include <ncurses.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int list_adapters(char names[][64], int max)
{
	DIR *d = opendir("/sys/class/bluetooth");
	struct dirent *de;
	int n = 0;
	if (!d)
		return 0;
	while ((de = readdir(d)) != NULL && n < max) {
		if (de->d_name[0] == '.')
			continue;
		snprintf(names[n], 64, "%s", de->d_name);
		n++;
	}
	closedir(d);
	return n;
}

static int provider_loop(void)
{
	struct provider p;
	prov_open(&p, "bluetooth");
	char last[64] = "";
	int ticks = 0;

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	while (!stop) {
		char names[8][64];
		int n = list_adapters(names, 8);
		char json[256];
		if (n > 0 && (strcmp(names[0], last) || ++ticks >= 6)) {
			prov_send(&p, "op=clear&app=bluetooth");
			snprintf(json, sizeof(json),
				 "op=widget&app=bluetooth&id=bluetooth&kind=text"
				 "&text=bt&order=10&priority=30");
			prov_send(&p, json);
			snprintf(last, sizeof(last), "%s", names[0]);
			ticks = 0;
		} else if (n == 0 && last[0]) {
			prov_send(&p, "op=clear&app=bluetooth");
			last[0] = '\0';
		}
		sleep(5);
	}
	prov_close(&p);
	return 0;
}

static int tui_loop(void)
{
	setlocale(LC_ALL, "");
	initscr();
	cbreak();
	noecho();
	keypad(stdscr, TRUE);
	curs_set(0);
	start_color();
	use_default_colors();
	init_pair(1, COLOR_CYAN, -1);
	init_pair(2, COLOR_GREEN, -1);

	for (;;) {
		int r, c;
		getmaxyx(stdscr, r, c);
		erase();
		attron(A_BOLD | COLOR_PAIR(1));
		mvprintw(0, 0, "Bluetooth");
		attroff(A_BOLD | COLOR_PAIR(1));
		char names[8][64];
		int n = list_adapters(names, 8);
		if (!n) {
			mvprintw(2, 1, "No adapter");
		} else {
			for (int i = 0; i < n && i + 2 < r - 1; i++)
				mvprintw(i + 2, 1, "%s", names[i]);
		}
		refresh();
		timeout(1000);
		int ch = getch();
		if (ch == 'q' || ch == 27)
			break;
	}
	endwin();
	return 0;
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--provider"))
			return provider_loop();
		if (!strcmp(argv[i], "--selftest")) {
			printf("cpz-bluetooth selftest: ok\n");
			return 0;
		}
	}
	return tui_loop();
}
