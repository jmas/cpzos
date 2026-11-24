/*
 * cpz-provider — small provider-side client for cpz-menud.
 *
 * A system provider is an ordinary daemon: connect, hello with its token,
 * register typed status widgets, update them on change and hold the connection
 * open. Closing the connection removes its data immediately.
 */
#ifndef CPZ_PROVIDER_H
#define CPZ_PROVIDER_H

#include "cpz-json.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define PROV_SOCKET "/run/cpz/menu.sock"
#define PROV_RUN "/run/cpz/menu"

struct provider {
	int fd;
	char app[64];
	char socket_path[PATH_MAX];
	char run_dir[PATH_MAX];
	char token[512];
	int ttl_ms;
};

static int prov_read_token(struct provider *p)
{
	char path[PATH_MAX + 128];
	FILE *f;
	size_t n;

	if (getenv("CPZ_MENU_TOKEN")) {
		snprintf(p->token, sizeof(p->token), "%s",
			 getenv("CPZ_MENU_TOKEN"));
		return 0;
	}
	snprintf(path, sizeof(path), "%s/%s.token", p->run_dir, p->app);
	f = fopen(path, "r");
	if (!f)
		return -1;
	if (!fgets(p->token, sizeof(p->token), f)) {
		fclose(f);
		return -1;
	}
	fclose(f);
	n = strlen(p->token);
	while (n && (p->token[n - 1] == '\n' || p->token[n - 1] == '\r' ||
		     p->token[n - 1] == ' ' || p->token[n - 1] == '\t'))
		p->token[--n] = '\0';
	return p->token[0] ? 0 : -1;
}

static int prov_send_json(struct provider *p, jv *v)
{
	size_t len;
	char *s = jv_dump(v, &len);
	char *base = s;

	jv_free(v);
	if (!s)
		return -1;
	while (len > 0) {
		ssize_t n = write(p->fd, s, len);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			jv_free_string(base);
			return -1;
		}
		s += n;
		len -= (size_t)n;
	}
	jv_free_string(base);
	return write(p->fd, "\n", 1) == 1 ? 0 : -1;
}

static char *prov_read_line(struct provider *p)
{
	static char buf[8192];
	size_t n = 0;

	for (;;) {
		struct pollfd fds = { .fd = p->fd, .events = POLLIN };
		int r = poll(&fds, 1, 2000);

		if (r < 0) {
			if (errno == EINTR)
				continue;
			return NULL;
		}
		if (r == 0)
			return NULL;
		char c;
		ssize_t got = read(p->fd, &c, 1);

		if (got < 0) {
			if (errno == EINTR)
				continue;
			return NULL;
		}
		if (got == 0)
			return NULL;
		if (c == '\n') {
			if (n && buf[n - 1] == '\r')
				n--;
			buf[n] = '\0';
			return buf;
		}
		if (n + 2 >= sizeof(buf))
			return NULL;
		buf[n++] = c;
	}
}

static int prov_check_response(struct provider *p)
{
	char *line = prov_read_line(p);
	jv *o;

	if (!line)
		return -1;
	o = jv_parse(line, strlen(line), NULL);
	if (!o)
		return 0;
	if (jv_get(o, "error")) {
		fprintf(stderr, "cpz-%s: %s\n", p->app,
			jv_str(jv_get(o, "error")));
		jv_free(o);
		return -1;
	}
	jv_free(o);
	return 0;
}

static void prov_close(struct provider *p)
{
	if (p->fd >= 0)
		close(p->fd);
	p->fd = -1;
}

static int prov_open(struct provider *p)
{
	struct sockaddr_un sa;
	jv *hello;
	int fd;

	if (prov_read_token(p) < 0) {
		fprintf(stderr, "cpz-%s: no token in %s\n", p->app,
			p->run_dir);
		return -1;
	}
	if (strlen(p->socket_path) >= sizeof(sa.sun_path))
		return -1;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", p->socket_path);

	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(fd);
		return -1;
	}
	p->fd = fd;

	hello = jv_object();
	jv_obj_set(hello, "v", jv_number(1));
	jv_obj_set(hello, "op", jv_string("hello"));
	jv_obj_set(hello, "role", jv_string("provider"));
	jv_obj_set(hello, "app", jv_string(p->app));
	jv_obj_set(hello, "token", jv_string(p->token));
	if (prov_send_json(p, hello) < 0 ||
	    prov_check_response(p) < 0) {
		prov_close(p);
		return -1;
	}
	return 0;
}

static int prov_register(struct provider *p, jv *menu, jv *status)
{
	jv *o = jv_object();

	jv_obj_set(o, "v", jv_number(1));
	jv_obj_set(o, "op", jv_string("register"));
	jv_obj_set(o, "ttl_ms", jv_number(p->ttl_ms));
	if (menu)
		jv_obj_set(o, "menu", menu);
	if (status)
		jv_obj_set(o, "status", status);
	if (prov_send_json(p, o) < 0)
		return -1;
	return prov_check_response(p);
}

static int prov_update(struct provider *p, jv *menu, jv *status)
{
	jv *o = jv_object();

	jv_obj_set(o, "v", jv_number(1));
	jv_obj_set(o, "op", jv_string("update"));
	if (menu)
		jv_obj_set(o, "menu", menu);
	if (status)
		jv_obj_set(o, "status", status);
	if (prov_send_json(p, o) < 0)
		return -1;
	return prov_check_response(p);
}

#endif
