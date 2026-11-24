/*
 * cpz-json — a small, allocation-based JSON reader/writer.
 *
 * The appliance image does not ship a JSON library, and the menu protocol is
 * NDJSON. This is deliberately just enough JSON for the protocol: objects,
 * arrays, strings with \u escapes, numbers, booleans and null. It is shared by
 * cpz-menud, cpz-menu, cpz-ui and cpz-session (the launch/run control payloads)
 * so every process reads the same grammar.
 */
#ifndef CPZ_JSON_H
#define CPZ_JSON_H

#include <stddef.h>

typedef enum {
	JV_NULL = 0,
	JV_BOOL,
	JV_NUMBER,
	JV_STRING,
	JV_ARRAY,
	JV_OBJECT,
} jv_type;

typedef struct jv jv;

struct jv {
	jv_type type;
	int boolean;
	double number;
	char *string;
	struct {
		jv **items;
		int n;
		int cap;
	} array;
	struct {
		char **keys;
		jv **vals;
		int n;
		int cap;
	} object;
};

jv *jv_parse(const char *text, size_t len, char **error);
void jv_free(jv *v);

jv *jv_object(void);
jv *jv_array(void);
jv *jv_string(const char *s);
jv *jv_number(double n);
jv *jv_bool(int b);
jv *jv_null(void);

int jv_obj_set(jv *obj, const char *key, jv *val);
int jv_arr_add(jv *arr, jv *val);
jv *jv_get(const jv *obj, const char *key);
jv *jv_at(const jv *arr, int i);
const char *jv_str(const jv *v);
double jv_num(const jv *v, double def);
int jv_boolean(const jv *v, int def);
int jv_len(const jv *v);

char *jv_dump(const jv *v, size_t *len);
void jv_free_string(char *s);

#endif
