/*
 * cpz-battery — system status provider for the battery gauge.
 *
 * Reads the BQ27220 sysfs files and registers a typed `battery` widget, then
 * pushes a new widget whenever the charge or the charging state changes. The
 * shell draws the iPod-style battery; it never touches sysfs itself. This is
 * the RFC's "system provider" model.
 *
 * The vendor bq27xxx driver names the supply after the i2c device and appends
 * an IDA index, e.g. /sys/class/power_supply/bq27220-0 — not `bq27220`. The
 * provider therefore scans the power_supply class instead of hardcoding one
 * name, and falls back to any supply with `type == Battery` that exposes a
 * capacity. `CPZ_POWER_SUPPLY` overrides the device directory and
 * `CPZ_POWER_SUPPLY_CLASS` the class directory (both for tests).
 *
 * Build: gcc -O2 -Wall -Wextra cpz-battery.c cpz-json.c -o cpz-battery
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "cpz-provider.h"

#include <dirent.h>
#include <signal.h>
#include <time.h>

#define SUPPLY_CLASS "/sys/class/power_supply"
#define POLL_SECONDS 1

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

static int clamp_level(int v)
{
	if (v < 0)
		return 0;
	if (v > 100)
		return 100;
	return v;
}

/* A supply is usable if it reports any of the readings we can turn into a
 * percentage. `capacity` is exact; charge/energy are the fallback. */
static int has_reading(const char *dir)
{
	int v;

	if (read_int_file(dir, "capacity", &v) == 0)
		return 1;
	if (read_int_file(dir, "charge_now", &v) == 0)
		return 1;
	if (read_int_file(dir, "energy_now", &v) == 0)
		return 1;
	return 0;
}

/*
 * Score a candidate supply. The vendor gauge wins over a generic battery; a
 * plain mains/USB supply is never used, otherwise its "capacity" would replace
 * the real charge.
 */
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

struct supply {
	char dir[PATH_MAX];
};

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
			/* Highest score; stable on name for equal scores. */
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
		*out = clamp_level(v);
		return 0;
	}
	for (size_t i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
		int now, full;

		if (read_int_file(s->dir, pairs[i][0], &now) < 0 ||
		    read_int_file(s->dir, pairs[i][1], &full) < 0)
			continue;
		if (full <= 0)
			continue;
		*out = clamp_level((int)((long long)now * 100 / full));
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

static jv *status_widget(int level, int charging)
{
	jv *w = jv_object();
	jv *arr = jv_array();

	jv_obj_set(w, "id", jv_string("battery"));
	jv_obj_set(w, "kind", jv_string("battery"));
	jv_obj_set(w, "level", jv_number(level));
	jv_obj_set(w, "charging", jv_bool(charging));
	jv_obj_set(w, "order", jv_number(100));
	jv_obj_set(w, "priority", jv_number(90));
	jv_obj_set(w, "system", jv_bool(1));
	jv_arr_add(arr, w);
	return arr;
}

static int print_status(void)
{
	struct supply s;
	int level, charging;

	if (resolve_supply(&s) < 0) {
		fprintf(stderr, "cpz-battery: no battery supply in %s\n",
			SUPPLY_CLASS);
		return 1;
	}
	if (read_level(&s, &level) < 0) {
		fprintf(stderr, "cpz-battery: %s has no usable charge reading\n",
			s.dir);
		return 1;
	}
	charging = read_charging(&s);
	printf("path=%s level=%d charging=%d\n", s.dir, level, charging);
	return 0;
}

int main(int argc, char **argv)
{
	struct provider p;
	int level = -1, charging = -1;
	int registered = 0;
	char last_dir[PATH_MAX] = "";

	memset(&p, 0, sizeof(p));
	p.fd = -1;
	snprintf(p.app, sizeof(p.app), "battery");
	snprintf(p.socket_path, sizeof(p.socket_path), "%s", PROV_SOCKET);
	snprintf(p.run_dir, sizeof(p.run_dir), "%s", PROV_RUN);

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--socket") && i + 1 < argc)
			snprintf(p.socket_path, sizeof(p.socket_path), "%s",
				 argv[++i]);
		else if (!strcmp(argv[i], "--run") && i + 1 < argc)
			snprintf(p.run_dir, sizeof(p.run_dir), "%s", argv[++i]);
		else if (!strcmp(argv[i], "--status")) {
			return print_status();
		} else if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-V")) {
			printf("cpz-battery 0.1.0\n");
			return 0;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			printf("usage: cpz-battery [--socket PATH] [--run PATH]\n"
			       "       cpz-battery --status\n");
			return 0;
		}
	}

	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	while (!stop) {
		struct supply s;
		int nl, nc;

		if (resolve_supply(&s) < 0 || read_level(&s, &nl) < 0) {
			/*
			 * The gauge disappeared (driver rebind, dead module)
			 * or is not ready yet. Drop the widget so the shell
			 * never shows a stale charge, and retry.
			 */
			if (p.fd >= 0) {
				prov_close(&p);
				registered = 0;
				level = -1;
				charging = -1;
			}
			sleep(POLL_SECONDS);
			continue;
		}
		nc = read_charging(&s);
		if (strcmp(last_dir, s.dir)) {
			fprintf(stderr, "cpz-battery: using %s\n", s.dir);
			snprintf(last_dir, sizeof(last_dir), "%s", s.dir);
		}

		if (p.fd < 0) {
			if (prov_open(&p) < 0) {
				sleep(POLL_SECONDS);
				continue;
			}
			registered = 0;
			level = -1;
			charging = -1;
		}
		if (!registered) {
			jv *st = status_widget(nl, nc);

			if (prov_register(&p, NULL, st) < 0) {
				prov_close(&p);
				registered = 0;
				level = -1;
				charging = -1;
				sleep(POLL_SECONDS);
				continue;
			}
			registered = 1;
			level = nl;
			charging = nc;
		} else if (nl != level || nc != charging) {
			jv *st = status_widget(nl, nc);

			if (prov_update(&p, NULL, st) < 0) {
				prov_close(&p);
				registered = 0;
				level = -1;
				charging = -1;
				sleep(POLL_SECONDS);
				continue;
			}
			level = nl;
			charging = nc;
		}
		sleep(POLL_SECONDS);
	}
	prov_close(&p);
	return 0;
}
