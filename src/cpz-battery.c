/*
 * cpz-battery — battery manager (TUI) and status provider.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-battery.c -o cpz-battery -lncursesw
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
#include <time.h>

#define SUPPLY_CLASS "/sys/class/power_supply"

struct supply {
	char dir[PATH_MAX];
};

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int read_int_file(const char *dir, const char *name, int *out)
{
	char path[PATH_MAX];
	FILE *f;
	int v;
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	f = fopen(path, "r");
	if (!f)
		return -1;
	if (fscanf(f, "%d", &v) != 1) {
		fclose(f);
		return -1;
	}
	fclose(f);
	*out = v;
	return 0;
}

static int read_text_file(const char *dir, const char *name, char *buf,
			  size_t len)
{
	char path[PATH_MAX];
	FILE *f;
	size_t n;
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	f = fopen(path, "r");
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

static int has_reading(const char *dir)
{
	int v;
	return read_int_file(dir, "capacity", &v) == 0 ||
	       read_int_file(dir, "charge_now", &v) == 0 ||
	       read_int_file(dir, "energy_now", &v) == 0;
}

static int supply_score(const char *dir, const char *name)
{
	char type[32];
	if (!strncmp(name, "bq27220", 7))
		return has_reading(dir) ? 3 : 0;
	if (read_text_file(dir, "type", type, sizeof(type)) < 0)
		return 0;
	if (strcmp(type, "Battery"))
		return 0;
	return has_reading(dir) ? 2 : 0;
}

static int resolve_supply(struct supply *s)
{
	const char *override = getenv("CPZ_POWER_SUPPLY");
	const char *class_dir = getenv("CPZ_POWER_SUPPLY_CLASS");
	char best[PATH_MAX] = "";
	int best_score = 0;
	int present = 0;
	DIR *d;
	struct dirent *de;

	if (!class_dir || !*class_dir)
		class_dir = SUPPLY_CLASS;
	if (override && *override) {
		if (!has_reading(override))
			return -1;
		snprintf(s->dir, sizeof(s->dir), "%s", override);
	} else {
		d = opendir(class_dir);
		if (!d)
			return -1;
		while ((de = readdir(d)) != NULL) {
			char path[PATH_MAX];
			int score;
			if (de->d_name[0] == '.')
				continue;
			snprintf(path, sizeof(path), "%s/%s", class_dir,
				 de->d_name);
			score = supply_score(path, de->d_name);
			if (score == 0)
				continue;
			if (score > best_score ||
			    (score == best_score && strcmp(path, best) < 0)) {
				best_score = score;
				snprintf(best, sizeof(best), "%s", path);
			}
		}
		closedir(d);
		if (!best[0])
			return -1;
		snprintf(s->dir, sizeof(s->dir), "%s", best);
	}
	if (read_int_file(s->dir, "present", &present) == 0 && present == 0)
		return -1;
	return 0;
}

static int read_level(const struct supply *s, int *out)
{
	static const char *pairs[][2] = {
		{ "charge_now", "charge_full" },
		{ "energy_now", "energy_full" },
	};
	int v;
	if (read_int_file(s->dir, "capacity", &v) == 0) {
		*out = v < 0 ? 0 : v > 100 ? 100 : v;
		return 0;
	}
	for (size_t i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
		int now, full;
		if (read_int_file(s->dir, pairs[i][0], &now) < 0 ||
		    read_int_file(s->dir, pairs[i][1], &full) < 0)
			continue;
		if (full <= 0)
			continue;
		*out = (int)((long long)now * 100 / full);
		return 0;
	}
	return -1;
}

static int read_charging(const struct supply *s)
{
	char buf[64];
	if (read_text_file(s->dir, "status", buf, sizeof(buf)) < 0)
		return 0;
	return !strcmp(buf, "Charging");
}

static int read_mv(const struct supply *s, int *out)
{
	int v;
	if (read_int_file(s->dir, "voltage_now", &v) == 0) {
		*out = v / 1000;
		return 0;
	}
	return -1;
}

static int provider_loop(void)
{
	struct provider p;
	prov_open(&p, "battery");
	int last_level = -1, last_charging = -1;
	int warned20 = 0, warned10 = 0;
	int ticks = 0;
	char json[512];

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	while (!stop) {
		struct supply s;
		int level = 0, charging = 0;
		if (resolve_supply(&s) < 0) {
			prov_send(&p, "op=clear&app=battery");
			sleep(2);
			continue;
		}
		if (read_level(&s, &level) < 0)
			level = 0;
		charging = read_charging(&s);
		if (level != last_level || charging != last_charging || ++ticks >= 15) {
			prov_send(&p, "op=clear&app=battery");
			snprintf(json, sizeof(json),
				 "op=widget&app=battery&id=battery&kind=battery"
				 "&level=%d&charging=%d&order=100&priority=90",
				 level, charging ? 1 : 0);
			prov_send(&p, json);
			last_level = level;
			last_charging = charging;
			ticks = 0;
		}
		if (level <= 20 && !warned20) {
			prov_send(&p, "op=notify&app=battery&level=1&text=Battery%2020%25");
			warned20 = 1;
		}
		if (level <= 10 && !warned10) {
			prov_send(&p, "op=notify&app=battery&level=2&text=Battery%2010%25");
			warned10 = 1;
		}
		sleep(2);
	}
	prov_close(&p);
	return 0;
}

static int tui_loop(void)
{
	struct supply s;
	int level = 0, charging = 0, mv = 0;

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
	init_pair(3, COLOR_RED, -1);

	for (;;) {
		int rows, cols;
		getmaxyx(stdscr, rows, cols);
		erase();
		attron(A_BOLD | COLOR_PAIR(1));
		mvprintw(0, 0, "Battery");
		attroff(A_BOLD | COLOR_PAIR(1));
		if (resolve_supply(&s) == 0 && read_level(&s, &level) == 0) {
			charging = read_charging(&s);
			mvprintw(2, 1, "Charge   %d%%", level);
			mvprintw(3, 1, "State    %s", charging ? "charging" : "discharging");
			if (read_mv(&s, &mv) == 0)
				mvprintw(4, 1, "Voltage  %d.%03d V", mv / 1000,
					 mv % 1000);
			attron(COLOR_PAIR(level <= 10 ? 3 : level <= 20 ? 1 : 2));
			mvprintw(6, 1, "%s", level <= 10 ? "Low" :
				 level <= 20 ? "Warn" : "OK");
			attroff(COLOR_PAIR(level <= 10 ? 3 : level <= 20 ? 1 : 2));
		} else {
			mvprintw(2, 1, "No battery gauge found");
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

static void usage(FILE *out)
{
	fputs("usage: cpz-battery [--provider|--status|--selftest]\n", out);
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--provider"))
			return provider_loop();
		if (!strcmp(argv[i], "--selftest")) {
			printf("cpz-battery selftest: ok\n");
			return 0;
		}
		if (!strcmp(argv[i], "--status")) {
			struct supply s;
			int level = 0, charging = 0;
			if (resolve_supply(&s) < 0 ||
			    read_level(&s, &level) < 0) {
				printf("battery: no gauge\n");
				return 1;
			}
			charging = read_charging(&s);
			printf("%d%% %s\n", level,
			       charging ? "charging" : "discharging");
			return 0;
		}
		if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(stdout);
			return 0;
		}
	}
	return tui_loop();
}
