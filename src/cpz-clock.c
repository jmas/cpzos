/*
 * cpz-clock — system status provider for the clock.
 *
 * The shell owns the status-bar layout; this daemon only supplies the text.
 * It updates once per minute (or when the wall clock changes form).
 *
 * Build: gcc -O2 -Wall -Wextra cpz-clock.c cpz-json.c -o cpz-clock
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "cpz-provider.h"

#include <signal.h>
#include <time.h>

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static jv *status_widget(const char *text)
{
	jv *w = jv_object();
	jv *arr = jv_array();

	jv_obj_set(w, "id", jv_string("clock"));
	jv_obj_set(w, "kind", jv_string("text"));
	jv_obj_set(w, "text", jv_string(text));
	jv_obj_set(w, "order", jv_number(30));
	jv_obj_set(w, "priority", jv_number(40));
	jv_arr_add(arr, w);
	return arr;
}

int main(int argc, char **argv)
{
	struct provider p;
	char last[16] = "";
	int registered = 0;

	memset(&p, 0, sizeof(p));
	p.fd = -1;
	snprintf(p.app, sizeof(p.app), "clock");
	snprintf(p.socket_path, sizeof(p.socket_path), "%s", PROV_SOCKET);
	snprintf(p.run_dir, sizeof(p.run_dir), "%s", PROV_RUN);

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--socket") && i + 1 < argc)
			snprintf(p.socket_path, sizeof(p.socket_path), "%s",
				 argv[++i]);
		else if (!strcmp(argv[i], "--run") && i + 1 < argc)
			snprintf(p.run_dir, sizeof(p.run_dir), "%s", argv[++i]);
		else if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-V")) {
			printf("cpz-clock 0.1.0\n");
			return 0;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			printf("usage: cpz-clock [--socket PATH] [--run PATH]\n");
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
		time_t t = time(NULL);
		struct tm tm;
		char text[8];

		localtime_r(&t, &tm);
		strftime(text, sizeof(text), "%H:%M", &tm);

		if (p.fd < 0) {
			if (prov_open(&p) < 0) {
				sleep(1);
				continue;
			}
			registered = 0;
			last[0] = '\0';
		}
		if (!registered) {
			jv *st = status_widget(text);

			if (prov_register(&p, NULL, st) < 0) {
				prov_close(&p);
				sleep(1);
				continue;
			}
			registered = 1;
			snprintf(last, sizeof(last), "%s", text);
		} else if (strcmp(last, text)) {
			jv *st = status_widget(text);

			if (prov_update(&p, NULL, st) < 0) {
				prov_close(&p);
				sleep(1);
				continue;
			}
			snprintf(last, sizeof(last), "%s", text);
		}
		sleep(1);
	}
	prov_close(&p);
	return 0;
}
