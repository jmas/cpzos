/*
 * cpz-menu — a small CLI for the menu/status daemon.
 *
 *   cpz-menu list                 human-readable menu tree
 *   cpz-menu snapshot             raw snapshot JSON
 *   cpz-menu status               status widgets
 *   cpz-menu rescan               ask the daemon to rescan manifests (root)
 *   cpz-menu register APP [FILE]  register/update a one-shot provider
 *   cpz-menu unregister APP
 *   cpz-menu notice APP TEXT
 *
 * It speaks the same NDJSON socket as the UI and providers; it is not a
 * privileged back door except for `rescan`, which the daemon restricts to uid 0.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "cpz-json.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define DEFAULT_SOCKET "/run/cpz/menu.sock"
#define DEFAULT_RUN "/run/cpz/menu"
#define MAX_MSG 65536

static const char *socket_path = DEFAULT_SOCKET;
static const char *run_dir = DEFAULT_RUN;
static char *opt_token;
static int opt_ttl = 10000;

static void usage(FILE *out)
{
	fputs("usage: cpz-menu [--socket PATH] [--run PATH] [--token TOKEN]\n"
	      "                 [--ttl MS] list|snapshot|status|rescan|\n"
	      "                 register APP [FILE]|unregister APP|\n"
	      "                 notice APP TEXT\n", out);
}

static char *xstrdup(const char *s)
{
	size_t n = strlen(s) + 1;
	char *p = calloc(n, 1);

	if (!p) {
		fputs("cpz-menu: out of memory\n", stderr);
		exit(1);
	}
	memcpy(p, s, n);
	return p;
}

static int connect_menu(void)
{
	struct sockaddr_un sa;
	int fd;

	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	if (strlen(socket_path) >= sizeof(sa.sun_path)) {
		fprintf(stderr, "cpz-menu: socket path too long\n");
		return -1;
	}
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", socket_path);
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		fprintf(stderr, "cpz-menu: socket: %s\n", strerror(errno));
		return -1;
	}
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		fprintf(stderr, "cpz-menu: connect %s: %s\n", socket_path,
			strerror(errno));
		close(fd);
		return -1;
	}
	return fd;
}

static int send_line(int fd, const char *s)
{
	size_t n = strlen(s);

	while (n > 0) {
		ssize_t w = write(fd, s, n);

		if (w < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		s += w;
		n -= (size_t)w;
	}
	return write(fd, "\n", 1) == 1 ? 0 : -1;
}

static char *read_line(int fd)
{
	static char *buf;
	static size_t cap;
	size_t n = 0;

	for (;;) {
		char c;
		ssize_t r = read(fd, &c, 1);

		if (r < 0) {
			if (errno == EINTR)
				continue;
			return NULL;
		}
		if (r == 0)
			return n ? buf : NULL;
		if (c == '\n') {
			if (n && buf[n - 1] == '\r')
				n--;
			buf[n] = '\0';
			return buf;
		}
		if (n + 2 > cap) {
			size_t ncap = cap ? cap * 2 : 4096;
			char *p = realloc(buf, ncap);

			if (!p)
				return NULL;
			buf = p;
			cap = ncap;
		}
		buf[n++] = c;
		if (n > MAX_MSG) {
			fprintf(stderr, "cpz-menu: response too large\n");
			return NULL;
		}
	}
}

static jv *parse_line(const char *line)
{
	char *err = NULL;
	jv *v;

	if (!line)
		return NULL;
	v = jv_parse(line, strlen(line), &err);
	if (!v) {
		fprintf(stderr, "cpz-menu: bad response: %s\n",
			err ? err : "parse error");
		free(err);
	}
	return v;
}

static void print_error(jv *v)
{
	const char *e = jv_str(jv_get(v, "error"));

	if (e)
		fprintf(stderr, "cpz-menu: %s\n", e);
}

static char *read_token(const char *app)
{
	char path[PATH_MAX];
	char buf[512];
	FILE *f;
	size_t n;

	if (opt_token)
		return xstrdup(opt_token);
	snprintf(path, sizeof(path), "%s/%s.token", run_dir, app);
	f = fopen(path, "r");
	if (!f) {
		fprintf(stderr, "cpz-menu: no token for %s at %s\n", app, path);
		return NULL;
	}
	if (!fgets(buf, sizeof(buf), f)) {
		fclose(f);
		return NULL;
	}
	fclose(f);
	n = strlen(buf);
	while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r' ||
		     buf[n - 1] == ' ' || buf[n - 1] == '\t'))
		buf[--n] = '\0';
	return xstrdup(buf);
}

static jv *hello(int fd, const char *role, const char *app, const char *token)
{
	jv *o = jv_object();
	jv *resp;

	jv_obj_set(o, "v", jv_number(1));
	jv_obj_set(o, "op", jv_string("hello"));
	jv_obj_set(o, "role", jv_string(role));
	if (app)
		jv_obj_set(o, "app", jv_string(app));
	if (token)
		jv_obj_set(o, "token", jv_string(token));
	{
		size_t len;
		char *s = jv_dump(o, &len);

		jv_free(o);
		if (!s || send_line(fd, s) < 0) {
			jv_free_string(s);
			return NULL;
		}
		jv_free_string(s);
	}
	resp = parse_line(read_line(fd));
	if (resp) {
		const char *e = jv_str(jv_get(resp, "error"));

		if (e) {
			print_error(resp);
			jv_free(resp);
			return NULL;
		}
	}
	return resp;
}

static int cmd_snapshot(int raw)
{
	int fd = connect_menu();
	jv *hello_resp, *snap = NULL;
	char *line;

	if (fd < 0)
		return 1;
	hello_resp = hello(fd, "ui", NULL, NULL);
	if (!hello_resp) {
		close(fd);
		return 1;
	}
	jv_free(hello_resp);
	/* hello replies with ok, then the current snapshot. */
	for (int i = 0; i < 4; i++) {
		line = read_line(fd);
		if (!line)
			break;
		snap = parse_line(line);
		if (snap && jv_get(snap, "menu"))
			break;
		jv_free(snap);
		snap = NULL;
	}
	close(fd);
	if (!snap) {
		fprintf(stderr, "cpz-menu: no snapshot\n");
		return 1;
	}
	if (raw) {
		size_t len;
		char *s = jv_dump(snap, &len);

		if (s) {
			printf("%s\n", s);
			jv_free_string(s);
		}
	} else {
		jv *menu = jv_get(snap, "menu");
		int n = jv_len(menu);

		printf("generation %g, %d item(s)\n",
		       jv_num(jv_get(snap, "generation"), 0), n);
		for (int i = 0; i < n; i++) {
			jv *it = jv_at(menu, i);
			const char *id = jv_str(jv_get(it, "id"));
			const char *label = jv_str(jv_get(it, "label"));
			const char *parent = jv_str(jv_get(it, "parent"));
			jv *act = jv_get(it, "action");
			const char *kind = "menu";

			if (act) {
				if (jv_get(act, "exec"))
					kind = "exec";
				else if (jv_get(act, "run"))
					kind = "run";
				else if (jv_get(act, "info"))
					kind = "info";
				else if (jv_get(act, "choice"))
					kind = "choice";
			}
			printf("%-24s %-30s parent=%-12s %s\n",
			       id ? id : "?", label ? label : "",
			       parent ? parent : "root", kind);
		}
	}
	jv_free(snap);
	return 0;
}

static int cmd_status(void)
{
	int fd = connect_menu();
	jv *hello_resp, *snap = NULL;
	char *line;

	if (fd < 0)
		return 1;
	hello_resp = hello(fd, "ui", NULL, NULL);
	if (!hello_resp) {
		close(fd);
		return 1;
	}
	jv_free(hello_resp);
	for (int i = 0; i < 4; i++) {
		line = read_line(fd);
		if (!line)
			break;
		snap = parse_line(line);
		if (snap && jv_get(snap, "status"))
			break;
		jv_free(snap);
		snap = NULL;
	}
	close(fd);
	if (!snap) {
		fprintf(stderr, "cpz-menu: no snapshot\n");
		return 1;
	}
	{
		jv *st = jv_get(snap, "status");
		int n = jv_len(st);

		printf("%d widget(s)\n", n);
		for (int i = 0; i < n; i++) {
			jv *w = jv_at(st, i);
			const char *id = jv_str(jv_get(w, "id"));
			const char *kind = jv_str(jv_get(w, "kind"));
			const char *text = jv_str(jv_get(w, "text"));
			const char *name = jv_str(jv_get(w, "name"));

			printf("%-16s %-8s", id ? id : "?", kind ? kind : "?");
			if (!strcmp(kind ? kind : "", "battery"))
				printf(" level=%.0f charging=%d",
				       jv_num(jv_get(w, "level"), 0),
				       jv_boolean(jv_get(w, "charging"), 0));
			else if (text)
				printf(" \"%s\"", text);
			else if (name)
				printf(" %s", name);
			printf(" order=%.0f priority=%.0f%s\n",
			       jv_num(jv_get(w, "order"), 0),
			       jv_num(jv_get(w, "priority"), 0),
			       jv_boolean(jv_get(w, "system"), 0) ?
			       " system" : "");
		}
	}
	jv_free(snap);
	return 0;
}

static int cmd_rescan(void)
{
	int fd = connect_menu();
	jv *r;

	if (fd < 0)
		return 1;
	r = hello(fd, "admin", NULL, NULL);
	jv_free(r);
	if (!r) {
		close(fd);
		return 1;
	}
	if (send_line(fd, "{\"v\":1,\"op\":\"rescan\"}") < 0) {
		close(fd);
		return 1;
	}
	r = parse_line(read_line(fd));
	close(fd);
	if (!r)
		return 1;
	{
		int rc = jv_get(r, "error") ? 1 : 0;

		print_error(r);
		jv_free(r);
		return rc;
	}
}

static char *read_stdin(void)
{
	size_t cap = 4096, n = 0;
	char *buf = calloc(cap, 1);

	if (!buf)
		return NULL;
	for (;;) {
		if (n + 1024 + 1 > cap) {
			char *p = realloc(buf, cap * 2);

			if (!p) {
				free(buf);
				return NULL;
			}
			buf = p;
			cap *= 2;
		}
		size_t r = fread(buf + n, 1, 1024, stdin);

		n += r;
		if (r < 1024) {
			buf[n] = '\0';
			return buf;
		}
	}
}

static int cmd_register(const char *app, const char *file)
{
	char *token = read_token(app);
	char *payload = NULL;
	jv *body = NULL, *msg;
	int fd;
	jv *r;

	if (!token)
		return 1;
	if (file) {
		FILE *f = fopen(file, "rb");
		long sz;

		if (!f) {
			fprintf(stderr, "cpz-menu: %s: %s\n", file,
				strerror(errno));
			free(token);
			return 1;
		}
		fseek(f, 0, SEEK_END);
		sz = ftell(f);
		rewind(f);
		if (sz < 0 || sz > MAX_MSG) {
			fclose(f);
			free(token);
			return 1;
		}
		payload = calloc((size_t)sz + 1, 1);
		if (payload && fread(payload, 1, (size_t)sz, f) != (size_t)sz) {
			free(payload);
			payload = NULL;
		}
		fclose(f);
	} else {
		payload = read_stdin();
	}
	if (!payload) {
		free(token);
		return 1;
	}
	{
		char *err = NULL;

		body = jv_parse(payload, strlen(payload), &err);
		free(payload);
		if (!body) {
			fprintf(stderr, "cpz-menu: bad JSON: %s\n",
				err ? err : "parse error");
			free(err);
			free(token);
			return 1;
		}
	}
	if (body->type != JV_OBJECT) {
		fprintf(stderr, "cpz-menu: register payload must be an object\n");
		jv_free(body);
		free(token);
		return 1;
	}
	jv_obj_set(body, "v", jv_number(1));
	jv_obj_set(body, "op", jv_string("register"));
	if (!jv_get(body, "ttl_ms"))
		jv_obj_set(body, "ttl_ms", jv_number(opt_ttl));
	msg = body;

	fd = connect_menu();
	if (fd < 0) {
		jv_free(msg);
		free(token);
		return 1;
	}
	r = hello(fd, "provider", app, token);
	free(token);
	if (!r) {
		close(fd);
		jv_free(msg);
		return 1;
	}
	jv_free(r);
	{
		size_t len;
		char *s = jv_dump(msg, &len);

		jv_free(msg);
		if (!s || send_line(fd, s) < 0) {
			jv_free_string(s);
			close(fd);
			return 1;
		}
		jv_free_string(s);
	}
	r = parse_line(read_line(fd));
	close(fd);
	if (!r)
		return 1;
	{
		int rc = jv_get(r, "error") ? 1 : 0;

		print_error(r);
		jv_free(r);
		return rc;
	}
}

static int cmd_unregister(const char *app)
{
	char *token = read_token(app);
	int fd;
	jv *r;

	if (!token)
		return 1;
	fd = connect_menu();
	if (fd < 0) {
		free(token);
		return 1;
	}
	r = hello(fd, "provider", app, token);
	free(token);
	if (!r) {
		close(fd);
		return 1;
	}
	jv_free(r);
	if (send_line(fd, "{\"v\":1,\"op\":\"unregister\"}") < 0) {
		close(fd);
		return 1;
	}
	r = parse_line(read_line(fd));
	close(fd);
	if (!r)
		return 1;
	{
		int rc = jv_get(r, "error") ? 1 : 0;

		print_error(r);
		jv_free(r);
		return rc;
	}
}

static int cmd_notice(const char *app, const char *text)
{
	char *token = read_token(app);
	int fd;
	jv *o, *r;

	if (!token)
		return 1;
	fd = connect_menu();
	if (fd < 0) {
		free(token);
		return 1;
	}
	r = hello(fd, "provider", app, token);
	free(token);
	if (!r) {
		close(fd);
		return 1;
	}
	jv_free(r);
	o = jv_object();
	jv_obj_set(o, "v", jv_number(1));
	jv_obj_set(o, "op", jv_string("notice"));
	jv_obj_set(o, "text", jv_string(text));
	{
		size_t len;
		char *s = jv_dump(o, &len);

		jv_free(o);
		if (!s || send_line(fd, s) < 0) {
			jv_free_string(s);
			close(fd);
			return 1;
		}
		jv_free_string(s);
	}
	r = parse_line(read_line(fd));
	close(fd);
	if (!r)
		return 1;
	{
		int rc = jv_get(r, "error") ? 1 : 0;

		print_error(r);
		jv_free(r);
		return rc;
	}
}

int main(int argc, char **argv)
{
	int i;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
			socket_path = argv[++i];
		} else if (!strcmp(argv[i], "--run") && i + 1 < argc) {
			run_dir = argv[++i];
		} else if (!strcmp(argv[i], "--token") && i + 1 < argc) {
			opt_token = argv[++i];
		} else if (!strcmp(argv[i], "--ttl") && i + 1 < argc) {
			opt_ttl = atoi(argv[++i]);
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(stdout);
			return 0;
		} else if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-V")) {
			printf("cpz-menu 0.1.0\n");
			return 0;
		} else {
			break;
		}
	}
	if (i >= argc) {
		usage(stderr);
		return 2;
	}
	const char *cmd = argv[i++];
	if (!strcmp(cmd, "list"))
		return cmd_snapshot(0);
	if (!strcmp(cmd, "snapshot"))
		return cmd_snapshot(1);
	if (!strcmp(cmd, "status"))
		return cmd_status();
	if (!strcmp(cmd, "rescan"))
		return cmd_rescan();
	if (!strcmp(cmd, "register")) {
		if (i >= argc) {
			usage(stderr);
			return 2;
		}
		return cmd_register(argv[i], i + 1 < argc ? argv[i + 1] : NULL);
	}
	if (!strcmp(cmd, "unregister")) {
		if (i >= argc) {
			usage(stderr);
			return 2;
		}
		return cmd_unregister(argv[i]);
	}
	if (!strcmp(cmd, "notice")) {
		if (i + 1 >= argc) {
			usage(stderr);
			return 2;
		}
		return cmd_notice(argv[i], argv[i + 1]);
	}
	usage(stderr);
	return 2;
}
