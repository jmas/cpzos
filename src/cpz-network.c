/*
 * cpz-network — system status provider for the network indicator.
 *
 * The RFC deliberately keeps this typed: the provider says "wifi" or
 * "ethernet"; the shell owns the 12 px glyph and its place in the bar.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-network.c cpz-json.c -o cpz-network
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "cpz-provider.h"

#include <dirent.h>
#include <signal.h>
#include <sys/stat.h>

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int dir_exists(const char *path)
{
	struct stat st;

	return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int read_status(const char *ifname, char *buf, size_t len)
{
	char path[PATH_MAX];
	FILE *f;

	snprintf(path, sizeof(path), "/sys/class/net/%s/operstate", ifname);
	f = fopen(path, "r");
	if (!f)
		return -1;
	if (!fgets(buf, (int)len, f)) {
		fclose(f);
		return -1;
	}
	fclose(f);
	size_t n = strlen(buf);
	while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
		buf[--n] = '\0';
	return 0;
}

/* Return "wifi", "ethernet" or NULL. */
static const char *network_glyph(void)
{
	DIR *d = opendir("/sys/class/net");
	struct dirent *de;
	const char *found = NULL;

	if (!d)
		return NULL;
	while ((de = readdir(d)) != NULL) {
		char state[32];
		char path[PATH_MAX];

		if (de->d_name[0] == '.')
			continue;
		if (!strcmp(de->d_name, "lo"))
			continue;
		if (read_status(de->d_name, state, sizeof(state)) < 0)
			continue;
		if (strcmp(state, "up") && strcmp(state, "unknown"))
			continue;
		snprintf(path, sizeof(path), "/sys/class/net/%s/wireless",
			 de->d_name);
		if (!strncmp(de->d_name, "wl", 2) || dir_exists(path)) {
			found = "wifi";
			break;
		}
		if (!strncmp(de->d_name, "en", 2) ||
		    !strncmp(de->d_name, "eth", 3))
			found = "ethernet";
	}
	closedir(d);
	return found;
}

static jv *status_widget(const char *glyph)
{
	jv *arr = jv_array();

	if (glyph) {
		jv *w = jv_object();

		jv_obj_set(w, "id", jv_string("network"));
		jv_obj_set(w, "kind", jv_string("glyph"));
		jv_obj_set(w, "name", jv_string(glyph));
		jv_obj_set(w, "order", jv_number(20));
		jv_obj_set(w, "priority", jv_number(50));
		jv_arr_add(arr, w);
	}
	return arr;
}

int main(int argc, char **argv)
{
	struct provider p;
	char last[32] = "";
	int registered = 0;

	memset(&p, 0, sizeof(p));
	p.fd = -1;
	snprintf(p.app, sizeof(p.app), "network");
	snprintf(p.socket_path, sizeof(p.socket_path), "%s", PROV_SOCKET);
	snprintf(p.run_dir, sizeof(p.run_dir), "%s", PROV_RUN);

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--socket") && i + 1 < argc)
			snprintf(p.socket_path, sizeof(p.socket_path), "%s",
				 argv[++i]);
		else if (!strcmp(argv[i], "--run") && i + 1 < argc)
			snprintf(p.run_dir, sizeof(p.run_dir), "%s", argv[++i]);
		else if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-V")) {
			printf("cpz-network 0.1.0\n");
			return 0;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			printf("usage: cpz-network [--socket PATH] [--run PATH]\n");
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
		const char *glyph = network_glyph();
		const char *name = glyph ? glyph : "";

		if (p.fd < 0) {
			if (prov_open(&p) < 0) {
				sleep(1);
				continue;
			}
			registered = 0;
			last[0] = '\0';
		}
		if (!registered) {
			jv *st = status_widget(glyph);

			if (prov_register(&p, NULL, st) < 0) {
				prov_close(&p);
				sleep(1);
				continue;
			}
			registered = 1;
			snprintf(last, sizeof(last), "%s", name);
		} else if (strcmp(last, name)) {
			jv *st = status_widget(glyph);

			if (prov_update(&p, NULL, st) < 0) {
				prov_close(&p);
				sleep(1);
				continue;
			}
			snprintf(last, sizeof(last), "%s", name);
		}
		sleep(5);
	}
	prov_close(&p);
	return 0;
}
