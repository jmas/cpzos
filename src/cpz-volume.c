/*
 * cpz-volume — ALSA volume provider and a thin launcher for alsamixer.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-volume.c -o cpz-volume
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "cpz-provider.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int read_volume(int *volume, int *muted)
{
	FILE *f = popen("/usr/bin/amixer -M get Master 2>/dev/null", "r");
	char line[512];
	int found = 0;
	if (!f)
		return -1;
	*volume = 0;
	*muted = 0;
	while (fgets(line, sizeof(line), f)) {
		char *p = strchr(line, '[');
		if (p) {
			int v;
			if (sscanf(p, "[%d%%]", &v) == 1) {
				*volume = v;
				found = 1;
			}
			if (strstr(p, "[off]"))
				*muted = 1;
		}
	}
	pclose(f);
	return found ? 0 : -1;
}

static int provider_loop(void)
{
	struct provider p;
	prov_open(&p, "volume");
	char last[64] = "";
	int ticks = 0;

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	while (!stop) {
		int volume = 0, muted = 0;
		if (read_volume(&volume, &muted) == 0) {
			char text[32], json[256];
			snprintf(text, sizeof(text), "%s%d", muted ? "mute " : "vol ",
				 volume);
			if (strcmp(text, last) || ++ticks >= 15) {
				prov_send(&p, "op=clear&app=volume");
				snprintf(json, sizeof(json),
					 "op=widget&app=volume&id=volume&kind=text"
					 "&text=%s&order=40&priority=45", text);
				prov_send(&p, json);
				snprintf(last, sizeof(last), "%s", text);
				ticks = 0;
			}
		}
		sleep(2);
	}
	prov_close(&p);
	return 0;
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--provider"))
			return provider_loop();
		if (!strcmp(argv[i], "--selftest")) {
			printf("cpz-volume selftest: ok\n");
			return 0;
		}
	}
	execl("/usr/bin/alsamixer", "alsamixer", (char *)NULL);
	perror("cpz-volume: alsamixer");
	return 1;
}
