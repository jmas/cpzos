/*
 * cpz-bluetooth — system status provider for the Bluetooth indicator.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-bluetooth.c cpz-json.c -o cpz-bluetooth
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

static int bluetooth_present(void)
{
	DIR *d = opendir("/sys/class/bluetooth");
	struct dirent *de;
	int found = 0;

	if (!d)
		return 0;
	while ((de = readdir(d)) != NULL) {
		if (!strncmp(de->d_name, "hci", 3)) {
			found = 1;
			break;
		}
	}
	closedir(d);
	return found;
}

static jv *status_widget(int present)
{
	jv *arr = jv_array();

	if (present) {
		jv *w = jv_object();

		jv_obj_set(w, "id", jv_string("bluetooth"));
		jv_obj_set(w, "kind", jv_string("glyph"));
		jv_obj_set(w, "name", jv_string("bluetooth"));
		jv_obj_set(w, "order", jv_number(10));
		jv_obj_set(w, "priority", jv_number(45));
		jv_arr_add(arr, w);
	}
	return arr;
}

int main(int argc, char **argv)
{
	struct provider p;
	int last = -1;
	int registered = 0;

	memset(&p, 0, sizeof(p));
	p.fd = -1;
	snprintf(p.app, sizeof(p.app), "bluetooth");
	snprintf(p.socket_path, sizeof(p.socket_path), "%s", PROV_SOCKET);
	snprintf(p.run_dir, sizeof(p.run_dir), "%s", PROV_RUN);

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--socket") && i + 1 < argc)
			snprintf(p.socket_path, sizeof(p.socket_path), "%s",
				 argv[++i]);
		else if (!strcmp(argv[i], "--run") && i + 1 < argc)
			snprintf(p.run_dir, sizeof(p.run_dir), "%s", argv[++i]);
		else if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-V")) {
			printf("cpz-bluetooth 0.1.0\n");
			return 0;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			printf("usage: cpz-bluetooth [--socket PATH] [--run PATH]\n");
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
		int present = bluetooth_present();

		if (p.fd < 0) {
			if (prov_open(&p) < 0) {
				sleep(1);
				continue;
			}
			registered = 0;
			last = -1;
		}
		if (!registered) {
			jv *st = status_widget(present);

			if (prov_register(&p, NULL, st) < 0) {
				prov_close(&p);
				sleep(1);
				continue;
			}
			registered = 1;
			last = present;
		} else if (present != last) {
			jv *st = status_widget(present);

			if (prov_update(&p, NULL, st) < 0) {
				prov_close(&p);
				sleep(1);
				continue;
			}
			last = present;
		}
		sleep(5);
	}
	prov_close(&p);
	return 0;
}
