/*
 * cpz-sessionctl — send one control line to cpz-session.
 *
 * Menu actions are argv arrays, never shell strings. Settings items can use a
 * `run` action like:
 *
 *   ["/usr/local/bin/cpz-sessionctl", "output", "panel"]
 *
 * which cpz-session starts in the background while the launcher stays visible.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-sessionctl.c -o cpz-sessionctl
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define DEFAULT_SOCKET "/run/cpz/session.sock"

static void usage(FILE *out)
{
	fputs("usage: cpz-sessionctl [--socket PATH] status|ping|home|\n"
	      "       output auto|panel|hdmi|reboot|poweroff\n", out);
}

int main(int argc, char **argv)
{
	const char *sock = DEFAULT_SOCKET;
	char cmd[256];
	struct sockaddr_un sa;
	char reply[256];
	int fd, i;
	ssize_t n;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
			sock = argv[++i];
		} else if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-V")) {
			printf("cpz-sessionctl 0.1.0\n");
			return 0;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(stdout);
			return 0;
		} else {
			break;
		}
	}
	if (i >= argc) {
		usage(stderr);
		return 2;
	}
	if (!strcmp(argv[i], "output")) {
		if (i + 1 >= argc) {
			usage(stderr);
			return 2;
		}
		snprintf(cmd, sizeof(cmd), "output %s\n", argv[i + 1]);
	} else if (!strcmp(argv[i], "status") || !strcmp(argv[i], "ping") ||
		   !strcmp(argv[i], "home") || !strcmp(argv[i], "reboot") ||
		   !strcmp(argv[i], "poweroff")) {
		snprintf(cmd, sizeof(cmd), "%s\n", argv[i]);
	} else {
		usage(stderr);
		return 2;
	}

	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", sock);
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		fprintf(stderr, "cpz-sessionctl: socket: %s\n", strerror(errno));
		return 1;
	}
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		fprintf(stderr, "cpz-sessionctl: connect: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	if (write(fd, cmd, strlen(cmd)) != (ssize_t)strlen(cmd)) {
		close(fd);
		return 1;
	}
	n = read(fd, reply, sizeof(reply) - 1);
	close(fd);
	if (n <= 0)
		return 1;
	reply[n] = '\0';
	fputs(reply, stdout);
	return strncmp(reply, "ok", 2) == 0 ? 0 : 1;
}
