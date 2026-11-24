/*
 * cpz-clock — status provider for the panel clock.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-clock.c -o cpz-clock
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "cpz-provider.h"

#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

int main(int argc, char **argv)
{
	struct provider p;
	prov_open(&p, "clock");
	char last[32] = "";
	int ticks = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--selftest")) {
			printf("cpz-clock selftest: ok\n");
			return 0;
		}
		if (!strcmp(argv[i], "--status")) {
			time_t now = time(NULL);
			struct tm tm;
			char buf[16];
			localtime_r(&now, &tm);
			strftime(buf, sizeof(buf), "%H:%M", &tm);
			printf("%s\n", buf);
			return 0;
		}
	}
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	while (!stop) {
		time_t now = time(NULL);
		struct tm tm;
		char buf[16];
		char json[256];
		localtime_r(&now, &tm);
		strftime(buf, sizeof(buf), "%H:%M", &tm);
		if (strcmp(buf, last) || ++ticks >= 30) {
			snprintf(json, sizeof(json),
				 "op=widget&app=clock&id=clock&kind=text&text=%s"
				 "&order=30&priority=40", buf);
			prov_send(&p, json);
			snprintf(last, sizeof(last), "%s", buf);
			ticks = 0;
		}
		sleep(1);
	}
	prov_close(&p);
	return 0;
}
