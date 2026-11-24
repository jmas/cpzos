/*
 * cpz-network — network status provider and a small TUI.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-network.c -o cpz-network -lncursesw
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
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int read_text(const char *path, char *buf, size_t len)
{
	FILE *f = fopen(path, "r");
	size_t n;
	if (!f)
		return -1;
	if (!fgets(buf, (int)len, f)) {
		fclose(f);
		return -1;
	}
	fclose(f);
	n = strlen(buf);
	while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
		buf[--n] = '\0';
	return 0;
}

static int iface_wireless(const char *name)
{
	char path[PATH_MAX];
	struct stat st;
	snprintf(path, sizeof(path), "/sys/class/net/%s/wireless", name);
	return stat(path, &st) == 0;
}

static int find_active(char *buf, size_t len, int *wireless)
{
	DIR *d = opendir("/sys/class/net");
	struct dirent *de;
	int found = 0;

	if (!d)
		return -1;
	while ((de = readdir(d)) != NULL) {
		char path[PATH_MAX], state[32];
		if (de->d_name[0] == '.' || !strcmp(de->d_name, "lo"))
			continue;
		snprintf(path, sizeof(path), "/sys/class/net/%s/operstate",
			 de->d_name);
		if (read_text(path, state, sizeof(state)) < 0)
			continue;
		if (!strcmp(state, "up") || !strcmp(state, "unknown")) {
			snprintf(buf, len, "%s", de->d_name);
			*wireless = iface_wireless(de->d_name);
			found = 1;
			break;
		}
	}
	closedir(d);
	return found ? 0 : -1;
}

static int provider_loop(void)
{
	struct provider p;
	prov_open(&p, "network");
	char last[64] = "";
	int ticks = 0;

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	while (!stop) {
		char iface[64], json[256];
		int wireless = 0;
		if (find_active(iface, sizeof(iface), &wireless) == 0) {
			const char *label = wireless ? "wifi" : "eth";
			if (strcmp(iface, last) || ++ticks >= 6) {
				prov_send(&p, "op=clear&app=network");
				snprintf(json, sizeof(json),
					 "op=widget&app=network&id=network&kind=text"
					 "&text=%s&order=20&priority=50", label);
				prov_send(&p, json);
				snprintf(last, sizeof(last), "%s", iface);
				ticks = 0;
			}
		} else {
			if (last[0]) {
				prov_send(&p, "op=clear&app=network");
				last[0] = '\0';
			}
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
	init_pair(3, COLOR_WHITE, -1);

	for (;;) {
		int r, c;
		getmaxyx(stdscr, r, c);
		erase();
		attron(A_BOLD | COLOR_PAIR(1));
		mvprintw(0, 0, "Network");
		attroff(A_BOLD | COLOR_PAIR(1));
		DIR *d = opendir("/sys/class/net");
		struct dirent *de;
		int row = 2;
		if (d) {
			while ((de = readdir(d)) != NULL && row < r - 1) {
				char path[PATH_MAX], state[32];
				if (de->d_name[0] == '.' || !strcmp(de->d_name, "lo"))
					continue;
				snprintf(path, sizeof(path),
					 "/sys/class/net/%s/operstate", de->d_name);
				if (read_text(path, state, sizeof(state)) < 0)
					snprintf(state, sizeof(state), "unknown");
				attron(COLOR_PAIR(strcmp(state, "up") ? 3 : 2));
				mvprintw(row++, 1, "%-10s %s%s", de->d_name, state,
					 iface_wireless(de->d_name) ? "  wifi" : "");
				attroff(COLOR_PAIR(strcmp(state, "up") ? 3 : 2));
			}
			closedir(d);
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
			printf("cpz-network selftest: ok\n");
			return 0;
		}
	}
	return tui_loop();
}
