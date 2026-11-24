/*
 * cpz-json — see cpz-json.h. No globals, no locale dependence for output
 * numbers (they are printed with "%.17g", which is locale-sensitive only for
 * the decimal separator; the daemon runs under C.UTF-8).
 */
#include "cpz-json.h"

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define JV_MAX_DEPTH 48

struct parse {
	const char *s;
	size_t n;
	size_t i;
	char *err;
};

static void *xcalloc(size_t n, size_t sz)
{
	void *p = calloc(n, sz);

	if (!p)
		abort();
	return p;
}

static char *xstrdup(const char *s)
{
	size_t n = strlen(s) + 1;
	char *p = xcalloc(n, 1);

	memcpy(p, s, n);
	return p;
}

static int fail(struct parse *p, const char *msg)
{
	if (!p->err) {
		char buf[160];

		snprintf(buf, sizeof(buf), "%s at byte %zu", msg, p->i);
		p->err = xstrdup(buf);
	}
	return -1;
}

static void skip_ws(struct parse *p)
{
	while (p->i < p->n) {
		unsigned char c = (unsigned char)p->s[p->i];

		if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
			p->i++;
		else
			break;
	}
}

static int hexval(int c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

static int read_hex4(struct parse *p, unsigned *out)
{
	unsigned v = 0;

	if (p->i + 4 > p->n)
		return fail(p, "truncated \\u escape");
	for (int k = 0; k < 4; k++) {
		int h = hexval((unsigned char)p->s[p->i + (size_t)k]);

		if (h < 0)
			return fail(p, "bad \\u escape");
		v = (v << 4) | (unsigned)h;
	}
	p->i += 4;
	*out = v;
	return 0;
}

static int put_utf8(char *buf, size_t cap, size_t *n, unsigned cp)
{
	if (cp <= 0x7f) {
		if (*n + 1 > cap)
			return -1;
		buf[(*n)++] = (char)cp;
	} else if (cp <= 0x7ff) {
		if (*n + 2 > cap)
			return -1;
		buf[(*n)++] = (char)(0xc0 | (cp >> 6));
		buf[(*n)++] = (char)(0x80 | (cp & 0x3f));
	} else if (cp <= 0xffff) {
		if (*n + 3 > cap)
			return -1;
		buf[(*n)++] = (char)(0xe0 | (cp >> 12));
		buf[(*n)++] = (char)(0x80 | ((cp >> 6) & 0x3f));
		buf[(*n)++] = (char)(0x80 | (cp & 0x3f));
	} else if (cp <= 0x10ffff) {
		if (*n + 4 > cap)
			return -1;
		buf[(*n)++] = (char)(0xf0 | (cp >> 18));
		buf[(*n)++] = (char)(0x80 | ((cp >> 12) & 0x3f));
		buf[(*n)++] = (char)(0x80 | ((cp >> 6) & 0x3f));
		buf[(*n)++] = (char)(0x80 | (cp & 0x3f));
	} else {
		return -1;
	}
	return 0;
}

/*
 * A string literal is decoded into a fresh buffer. The decoded form is never
 * longer than the escaped source, so the source length + 1 is a safe cap.
 */
static int parse_string(struct parse *p, char **out)
{
	size_t start;
	size_t cap;
	size_t n = 0;
	char *buf;

	skip_ws(p);
	if (p->i >= p->n || p->s[p->i] != '"')
		return fail(p, "expected string");
	p->i++;
	start = p->i;

	/* Find the closing quote first so the buffer cap is cheap. */
	{
		size_t j = p->i;
		int closed = 0;

		while (j < p->n) {
			if (p->s[j] == '\\') {
				j += 2;
				continue;
			}
			if (p->s[j] == '"') {
				closed = 1;
				break;
			}
			j++;
		}
		if (!closed)
			return fail(p, "unterminated string");
		cap = j - start + 1;
	}

	buf = xcalloc(cap + 1, 1);
	while (p->i < p->n) {
		unsigned char c = (unsigned char)p->s[p->i++];

		if (c == '"') {
			buf[n] = '\0';
			*out = buf;
			return 0;
		}
		if (c == '\\') {
			unsigned char e;

			if (p->i >= p->n)
				goto bad;
			e = (unsigned char)p->s[p->i++];
			switch (e) {
			case '"': buf[n++] = '"'; break;
			case '\\': buf[n++] = '\\'; break;
			case '/': buf[n++] = '/'; break;
			case 'b': buf[n++] = '\b'; break;
			case 'f': buf[n++] = '\f'; break;
			case 'n': buf[n++] = '\n'; break;
			case 'r': buf[n++] = '\r'; break;
			case 't': buf[n++] = '\t'; break;
			case 'u': {
				unsigned cp;

				if (read_hex4(p, &cp) < 0)
					goto bad;
				if (cp >= 0xd800 && cp <= 0xdbff) {
					unsigned lo;

					if (p->i + 2 > p->n ||
					    p->s[p->i] != '\\' ||
					    p->s[p->i + 1] != 'u') {
						free(buf);
						return fail(p, "lone high surrogate");
					}
					p->i += 2;
					if (read_hex4(p, &lo) < 0)
						goto bad;
					if (lo < 0xdc00 || lo > 0xdfff) {
						free(buf);
						return fail(p, "bad low surrogate");
					}
					cp = 0x10000 + ((cp - 0xd800) << 10) +
					     (lo - 0xdc00);
				} else if (cp >= 0xdc00 && cp <= 0xdfff) {
					free(buf);
					return fail(p, "lone low surrogate");
				}
				if (put_utf8(buf, cap, &n, cp) < 0) {
					free(buf);
					return fail(p, "unicode escape too large");
				}
				break;
			}
			default:
				goto bad;
			}
			continue;
		}
		if (c < 0x20)
			goto bad;
		buf[n++] = (char)c;
	}
bad:
	free(buf);
	return fail(p, "unterminated string");
}

static int parse_number(struct parse *p, double *out)
{
	size_t start = p->i;
	char tmp[64];
	size_t len;

	if (p->i < p->n && p->s[p->i] == '-')
		p->i++;
	while (p->i < p->n && isdigit((unsigned char)p->s[p->i]))
		p->i++;
	if (p->i < p->n && p->s[p->i] == '.') {
		p->i++;
		while (p->i < p->n && isdigit((unsigned char)p->s[p->i]))
			p->i++;
	}
	if (p->i < p->n && (p->s[p->i] == 'e' || p->s[p->i] == 'E')) {
		p->i++;
		if (p->i < p->n && (p->s[p->i] == '+' || p->s[p->i] == '-'))
			p->i++;
		while (p->i < p->n && isdigit((unsigned char)p->s[p->i]))
			p->i++;
	}
	len = p->i - start;
	if (len == 0 || len >= sizeof(tmp))
		return fail(p, "bad number");
	memcpy(tmp, p->s + start, len);
	tmp[len] = '\0';
	*out = strtod(tmp, NULL);
	return 0;
}

static jv *parse_value(struct parse *p, int depth);

static jv *parse_container(struct parse *p, int depth, int is_obj)
{
	jv *v = is_obj ? jv_object() : jv_array();

	if (!v)
		return NULL;
	skip_ws(p);
	if (p->i >= p->n) {
		fail(p, "truncated container");
		goto bad;
	}
	if (p->s[p->i] == (is_obj ? '}' : ']')) {
		p->i++;
		return v;
	}
	for (;;) {
		if (is_obj) {
			char *key = NULL;
			jv *val;

			if (parse_string(p, &key) < 0)
				goto bad;
			skip_ws(p);
			if (p->i >= p->n || p->s[p->i] != ':') {
				free(key);
				fail(p, "expected ':'");
				goto bad;
			}
			p->i++;
			val = parse_value(p, depth + 1);
			if (!val) {
				free(key);
				goto bad;
			}
			if (jv_obj_set(v, key, val) < 0) {
				free(key);
				jv_free(val);
				fail(p, "out of memory");
				goto bad;
			}
			free(key);
		} else {
			jv *val = parse_value(p, depth + 1);

			if (!val)
				goto bad;
			if (jv_arr_add(v, val) < 0) {
				jv_free(val);
				fail(p, "out of memory");
				goto bad;
			}
		}
		skip_ws(p);
		if (p->i >= p->n) {
			fail(p, "truncated container");
			goto bad;
		}
		if (p->s[p->i] == ',') {
			p->i++;
			continue;
		}
		if (p->s[p->i] == (is_obj ? '}' : ']')) {
			p->i++;
			return v;
		}
		fail(p, "expected ',' or container end");
		goto bad;
	}
bad:
	jv_free(v);
	return NULL;
}

static int match_word(struct parse *p, const char *word)
{
	size_t n = strlen(word);

	if (p->i + n > p->n || memcmp(p->s + p->i, word, n) != 0)
		return 0;
	p->i += n;
	return 1;
}

static jv *parse_value(struct parse *p, int depth)
{
	jv *v = NULL;

	if (depth > JV_MAX_DEPTH) {
		fail(p, "nesting too deep");
		return NULL;
	}
	skip_ws(p);
	if (p->i >= p->n) {
		fail(p, "unexpected end of input");
		return NULL;
	}
	switch (p->s[p->i]) {
	case '{':
		p->i++;
		return parse_container(p, depth, 1);
	case '[':
		p->i++;
		return parse_container(p, depth, 0);
	case '"': {
		char *s = NULL;

		if (parse_string(p, &s) < 0)
			return NULL;
		v = jv_string(s);
		free(s);
		return v;
	}
	case 't':
		if (match_word(p, "true"))
			return jv_bool(1);
		fail(p, "bad literal");
		return NULL;
	case 'f':
		if (match_word(p, "false"))
			return jv_bool(0);
		fail(p, "bad literal");
		return NULL;
	case 'n':
		if (match_word(p, "null"))
			return jv_null();
		fail(p, "bad literal");
		return NULL;
	default:
		break;
	}
	if (p->s[p->i] == '-' || isdigit((unsigned char)p->s[p->i])) {
		double d;

		if (parse_number(p, &d) < 0)
			return NULL;
		return jv_number(d);
	}
	fail(p, "unexpected character");
	return NULL;
}

jv *jv_parse(const char *text, size_t len, char **error)
{
	struct parse p;
	jv *v;

	memset(&p, 0, sizeof(p));
	p.s = text;
	p.n = len;
	v = parse_value(&p, 0);
	if (v) {
		skip_ws(&p);
		if (p.i != p.n) {
			jv_free(v);
			v = NULL;
			fail(&p, "trailing data");
		}
	}
	if (!v && error)
		*error = p.err ? xstrdup(p.err) : xstrdup("parse failed");
	else if (error)
		*error = NULL;
	free(p.err);
	return v;
}

void jv_free(jv *v)
{
	if (!v)
		return;
	free(v->string);
	if (v->type == JV_ARRAY) {
		for (int i = 0; i < v->array.n; i++)
			jv_free(v->array.items[i]);
		free(v->array.items);
	} else if (v->type == JV_OBJECT) {
		for (int i = 0; i < v->object.n; i++) {
			free(v->object.keys[i]);
			jv_free(v->object.vals[i]);
		}
		free(v->object.keys);
		free(v->object.vals);
	}
	free(v);
}

jv *jv_object(void)
{
	jv *v = xcalloc(1, sizeof(*v));

	v->type = JV_OBJECT;
	return v;
}

jv *jv_array(void)
{
	jv *v = xcalloc(1, sizeof(*v));

	v->type = JV_ARRAY;
	return v;
}

jv *jv_string(const char *s)
{
	jv *v = xcalloc(1, sizeof(*v));

	v->type = JV_STRING;
	v->string = xstrdup(s ? s : "");
	return v;
}

jv *jv_number(double n)
{
	jv *v = xcalloc(1, sizeof(*v));

	v->type = JV_NUMBER;
	v->number = n;
	return v;
}

jv *jv_bool(int b)
{
	jv *v = xcalloc(1, sizeof(*v));

	v->type = JV_BOOL;
	v->boolean = b ? 1 : 0;
	return v;
}

jv *jv_null(void)
{
	jv *v = xcalloc(1, sizeof(*v));

	v->type = JV_NULL;
	return v;
}

int jv_obj_set(jv *obj, const char *key, jv *val)
{
	if (!obj || obj->type != JV_OBJECT || !key)
		return -1;
	for (int i = 0; i < obj->object.n; i++) {
		if (!strcmp(obj->object.keys[i], key)) {
			jv_free(obj->object.vals[i]);
			obj->object.vals[i] = val;
			return 0;
		}
	}
	if (obj->object.n == obj->object.cap) {
		int cap = obj->object.cap ? obj->object.cap * 2 : 8;
		char **keys = realloc(obj->object.keys,
				      (size_t)cap * sizeof(*keys));
		jv **vals;

		if (!keys)
			return -1;
		obj->object.keys = keys;
		vals = realloc(obj->object.vals, (size_t)cap * sizeof(*vals));
		if (!vals)
			return -1;
		obj->object.vals = vals;
		obj->object.cap = cap;
	}
	obj->object.keys[obj->object.n] = xstrdup(key);
	obj->object.vals[obj->object.n] = val;
	obj->object.n++;
	return 0;
}

int jv_arr_add(jv *arr, jv *val)
{
	if (!arr || arr->type != JV_ARRAY)
		return -1;
	if (arr->array.n == arr->array.cap) {
		int cap = arr->array.cap ? arr->array.cap * 2 : 8;
		jv **items = realloc(arr->array.items,
				     (size_t)cap * sizeof(*items));

		if (!items)
			return -1;
		arr->array.items = items;
		arr->array.cap = cap;
	}
	arr->array.items[arr->array.n++] = val;
	return 0;
}

jv *jv_get(const jv *obj, const char *key)
{
	if (!obj || obj->type != JV_OBJECT || !key)
		return NULL;
	for (int i = 0; i < obj->object.n; i++)
		if (!strcmp(obj->object.keys[i], key))
			return obj->object.vals[i];
	return NULL;
}

jv *jv_at(const jv *arr, int i)
{
	if (!arr || arr->type != JV_ARRAY || i < 0 || i >= arr->array.n)
		return NULL;
	return arr->array.items[i];
}

const char *jv_str(const jv *v)
{
	if (!v || v->type != JV_STRING)
		return NULL;
	return v->string;
}

double jv_num(const jv *v, double def)
{
	return v && v->type == JV_NUMBER ? v->number : def;
}

int jv_boolean(const jv *v, int def)
{
	return v && v->type == JV_BOOL ? v->boolean : def;
}

int jv_len(const jv *v)
{
	if (!v)
		return 0;
	if (v->type == JV_ARRAY)
		return v->array.n;
	if (v->type == JV_OBJECT)
		return v->object.n;
	return 0;
}

/* ------------------------------------------------------------- serializer */

struct out {
	char *p;
	size_t n;
	size_t cap;
	int failed;
};

static void out_grow(struct out *o, size_t need)
{
	if (o->failed)
		return;
	if (o->n + need + 1 <= o->cap)
		return;
	size_t cap = o->cap ? o->cap : 256;
	while (cap < o->n + need + 1)
		cap *= 2;
	char *p = realloc(o->p, cap);

	if (!p) {
		o->failed = 1;
		return;
	}
	o->p = p;
	o->cap = cap;
}

static void out_putc(struct out *o, char c)
{
	out_grow(o, 1);
	if (!o->failed)
		o->p[o->n++] = c;
}

static void out_write(struct out *o, const char *s, size_t n)
{
	out_grow(o, n);
	if (!o->failed) {
		memcpy(o->p + o->n, s, n);
		o->n += n;
	}
}

static void out_str(struct out *o, const char *s)
{
	out_putc(o, '"');
	for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
		switch (*p) {
		case '"': out_write(o, "\\\"", 2); break;
		case '\\': out_write(o, "\\\\", 2); break;
		case '\b': out_write(o, "\\b", 2); break;
		case '\f': out_write(o, "\\f", 2); break;
		case '\n': out_write(o, "\\n", 2); break;
		case '\r': out_write(o, "\\r", 2); break;
		case '\t': out_write(o, "\\t", 2); break;
		default:
			if (*p < 0x20) {
				char buf[8];

				snprintf(buf, sizeof(buf), "\\u%04x", *p);
				out_write(o, buf, 6);
			} else {
				out_putc(o, (char)*p);
			}
		}
	}
	out_putc(o, '"');
}

static void dump_value(struct out *o, const jv *v)
{
	if (!v) {
		out_write(o, "null", 4);
		return;
	}
	switch (v->type) {
	case JV_NULL:
		out_write(o, "null", 4);
		break;
	case JV_BOOL:
		out_write(o, v->boolean ? "true" : "false",
			  v->boolean ? 4 : 5);
		break;
	case JV_NUMBER: {
		char buf[64];
		double d = v->number;

		if (d == 0)
			d = 0;
		if (d == (double)(long long)d)
			snprintf(buf, sizeof(buf), "%lld", (long long)d);
		else
			snprintf(buf, sizeof(buf), "%.17g", d);
		out_write(o, buf, strlen(buf));
		break;
	}
	case JV_STRING:
		out_str(o, v->string ? v->string : "");
		break;
	case JV_ARRAY:
		out_putc(o, '[');
		for (int i = 0; i < v->array.n; i++) {
			if (i)
				out_putc(o, ',');
			dump_value(o, v->array.items[i]);
		}
		out_putc(o, ']');
		break;
	case JV_OBJECT:
		out_putc(o, '{');
		for (int i = 0; i < v->object.n; i++) {
			if (i)
				out_putc(o, ',');
			out_str(o, v->object.keys[i]);
			out_putc(o, ':');
			dump_value(o, v->object.vals[i]);
		}
		out_putc(o, '}');
		break;
	}
}

char *jv_dump(const jv *v, size_t *len)
{
	struct out o;

	memset(&o, 0, sizeof(o));
	dump_value(&o, v);
	if (o.failed) {
		free(o.p);
		if (len)
			*len = 0;
		return NULL;
	}
	out_grow(&o, 0);
	if (!o.failed)
		o.p[o.n] = '\0';
	if (len)
		*len = o.n;
	return o.p;
}

void jv_free_string(char *s)
{
	free(s);
}
