/*
 * cpz-ctl — small control client for /run/cpz/session.sock.
 *
 * Build: gcc -O2 -Wall -Wextra cpz-ctl.c -o cpz-ctl
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define SOCKET "/run/cpz/session.sock"

static int send_command(const char *cmd)
{
	struct sockaddr_un sa;
	int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0) {
		perror("cpz-ctl: socket");
		return 1;
	}
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", SOCKET);
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		fprintf(stderr, "cpz-ctl: cpz-session is not running\n");
		close(fd);
		return 1;
	}
	char line[4096];
	snprintf(line, sizeof(line), "%s\n", cmd);
	if (write(fd, line, strlen(line)) != (ssize_t)strlen(line)) {
		perror("cpz-ctl: write");
		close(fd);
		return 1;
	}
	char reply[4096];
	ssize_t n = read(fd, reply, sizeof(reply) - 1);
	close(fd);
	if (n > 0) {
		reply[n] = '\0';
		fputs(reply, stdout);
	}
	return 0;
}

static void usage(FILE *out)
{
	fputs("usage: cpz-ctl status|output auto|panel|hdmi|restart-term|"
	      "poweroff|reboot|gui COMMAND\n", out);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		usage(stderr);
		return 2;
	}
	if (!strcmp(argv[1], "--selftest")) {
		printf("cpz-ctl selftest: ok\n");
		return 0;
	}
	if (!strcmp(argv[1], "status") || !strcmp(argv[1], "restart-term") ||
	    !strcmp(argv[1], "poweroff") || !strcmp(argv[1], "reboot"))
		return send_command(argv[1]);
	if (!strcmp(argv[1], "output") && argc == 3) {
		char cmd[64];
		snprintf(cmd, sizeof(cmd), "output %s", argv[2]);
		return send_command(cmd);
	}
	if (!strcmp(argv[1], "gui") && argc >= 3) {
		char cmd[4096] = "gui ";
		for (int i = 2; i < argc; i++) {
			if (strlen(cmd) + strlen(argv[i]) + 2 >= sizeof(cmd))
				break;
			if (i > 2)
				strncat(cmd, " ", sizeof(cmd) - strlen(cmd) - 1);
			strncat(cmd, argv[i], sizeof(cmd) - strlen(cmd) - 1);
		}
		return send_command(cmd);
	}
	usage(stderr);
	return 2;
}
