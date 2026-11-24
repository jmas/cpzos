/*
 * cpz-query — line-oriented key=value helpers.
 *
 * One line is one message. Pairs are separated by '&'; values are
 * percent-encoded. This replaces JSON in the runtime protocol and manifests.
 */
#ifndef CPZ_QUERY_H
#define CPZ_QUERY_H

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static int hexval(int c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static void url_decode(const char *src, char *dst, size_t len)
{
	size_t o = 0;
	while (*src && o + 1 < len) {
		if (*src == '%' && hexval(src[1]) >= 0 && hexval(src[2]) >= 0) {
			dst[o++] = (char)((hexval(src[1]) << 4) | hexval(src[2]));
			src += 3;
		} else if (*src == '+') {
			dst[o++] = ' ';
			src++;
		} else {
			dst[o++] = *src++;
		}
	}
	dst[o] = '\0';
}

static void url_encode(const char *src, char *dst, size_t len)
{
	static const char hex[] = "0123456789ABCDEF";
	size_t o = 0;
	while (*src && o + 4 < len) {
		unsigned char c = (unsigned char)*src++;
		if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
			dst[o++] = (char)c;
		} else {
			dst[o++] = '%';
			dst[o++] = hex[c >> 4];
			dst[o++] = hex[c & 15];
		}
	}
	dst[o] = '\0';
}

static int kv_get(const char *line, const char *key, char *out, size_t len)
{
	size_t klen = strlen(key);
	const char *p = line;

	while (*p) {
		const char *amp = strchr(p, '&');
		size_t plen = amp ? (size_t)(amp - p) : strlen(p);
		const char *eq = memchr(p, '=', plen);
		if (eq && (size_t)(eq - p) == klen && !memcmp(p, key, klen)) {
			char raw[1024];
			size_t vlen = plen - (size_t)(eq + 1 - p);
			if (vlen >= sizeof(raw))
				vlen = sizeof(raw) - 1;
			memcpy(raw, eq + 1, vlen);
			raw[vlen] = '\0';
			url_decode(raw, out, len);
			return 0;
		}
		if (!amp)
			break;
		p = amp + 1;
	}
	return -1;
}

static int kv_int(const char *line, const char *key, int def)
{
	char tmp[64];
	if (kv_get(line, key, tmp, sizeof(tmp)) < 0)
		return def;
	return atoi(tmp);
}

static int kv_bool(const char *line, const char *key, int def)
{
	char tmp[32];
	if (kv_get(line, key, tmp, sizeof(tmp)) < 0)
		return def;
	return !strcmp(tmp, "1") || !strcasecmp(tmp, "true") ||
	       !strcasecmp(tmp, "yes");
}

/* Remove trailing CR/LF and surrounding spaces from a manifest line. */
static void line_trim(char *s)
{
	size_t n = strlen(s);
	while (n && (s[n - 1] == '\n' || s[n - 1] == '\r' ||
		     s[n - 1] == ' ' || s[n - 1] == '\t'))
		s[--n] = '\0';
}

#endif
