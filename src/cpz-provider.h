/*
 * cpz-provider — tiny provider-side client for cpz-shell.
 *
 * A provider is an ordinary daemon. It keeps one connection open and sends
 * typed status widgets; closing the connection removes its widgets.
 */
#ifndef CPZ_PROVIDER_H
#define CPZ_PROVIDER_H

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define PROV_SOCKET "/run/cpz/ui.sock"

struct provider {
	int fd;
	char app[64];
	char socket[PATH_MAX];
};

static int prov_open(struct provider *p, const char *app)
{
	struct sockaddr_un sa;
	char hello[256];
	char name[64];

	snprintf(name, sizeof(name), "%s", app ? app : "provider");
	memset(p, 0, sizeof(*p));
	p->fd = -1;
	snprintf(p->app, sizeof(p->app), "%s", name);
	snprintf(p->socket, sizeof(p->socket), "%s", PROV_SOCKET);
	p->fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (p->fd < 0)
		return -1;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", p->socket);
	if (connect(p->fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(p->fd);
		p->fd = -1;
		return -1;
	}
	snprintf(hello, sizeof(hello),
		 "op=hello&app=%s\n", p->app);
	if (write(p->fd, hello, strlen(hello)) != (ssize_t)strlen(hello)) {
		close(p->fd);
		p->fd = -1;
		return -1;
	}
	return 0;
}

static int prov_send(struct provider *p, const char *json)
{
	char line[2048];
	int n;

	if (p->fd < 0 && prov_open(p, p->app[0] ? p->app : "provider") < 0)
		return -1;
	n = snprintf(line, sizeof(line), "%s\n", json);
	if (n < 0 || (size_t)n >= sizeof(line))
		return -1;
	if (write(p->fd, line, (size_t)n) != n) {
		close(p->fd);
		p->fd = -1;
		return -1;
	}
	return 0;
}

static void prov_close(struct provider *p)
{
	if (p->fd >= 0)
		close(p->fd);
	p->fd = -1;
}

#endif
