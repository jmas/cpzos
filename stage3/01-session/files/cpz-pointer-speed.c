/*
 * cpz-pointer-speed: apply the CPZ pointer speed inside cage.
 *
 * cage 0.3.1 (wlroots) exposes no pointer-acceleration setting, so the
 * compositor never calls libinput_device_config_accel_set_speed(). This tiny
 * LD_PRELOAD shim interposes libinput_get_event() and configures a device
 * before wlroots sees its DEVICE_ADDED event. cpz-pointer writes the desired
 * value to /run/cpz-pointer/speed; Settings > Input > Mouse Speed is the UI.
 *
 * libinput is resolved through dlsym, so the shim needs no libinput headers at
 * build time and the runtime soname version cannot break the link.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

#define SPEED_FILE "/run/cpz-pointer/speed"
#define SPEED_ENV "CPZ_POINTER_SPEED"
/* libinput.h: LIBINPUT_EVENT_NONE = 0, LIBINPUT_EVENT_DEVICE_ADDED = 1. */
#define EVENT_DEVICE_ADDED 1

struct libinput;
struct libinput_event;
struct libinput_device;

typedef struct libinput_event *(*get_event_fn)(struct libinput *);
typedef int (*event_type_fn)(struct libinput_event *);
typedef struct libinput_device *(*event_device_fn)(struct libinput_event *);
typedef int (*accel_available_fn)(struct libinput_device *);
typedef int (*accel_set_speed_fn)(struct libinput_device *, double);

static get_event_fn real_get_event;
static event_type_fn event_type;
static event_device_fn event_device;
static accel_available_fn accel_available;
static accel_set_speed_fn accel_set_speed;

static double read_speed(void)
{
	double speed = 0.0;
	FILE *handle = fopen(SPEED_FILE, "r");

	if (handle) {
		if (fscanf(handle, "%lf", &speed) != 1)
			speed = 0.0;
		fclose(handle);
	} else {
		const char *env = getenv(SPEED_ENV);

		if (env && *env)
			speed = strtod(env, NULL);
	}
	if (speed < -1.0)
		speed = -1.0;
	if (speed > 1.0)
		speed = 1.0;
	return speed;
}

static void configure_device(struct libinput_device *device)
{
	if (!device || !accel_available || !accel_set_speed)
		return;
	if (accel_available(device))
		accel_set_speed(device, read_speed());
}

struct libinput_event *libinput_get_event(struct libinput *libinput)
{
	struct libinput_event *event;

	if (!real_get_event) {
		real_get_event =
			(get_event_fn)dlsym(RTLD_NEXT, "libinput_get_event");
		event_type =
			(event_type_fn)dlsym(RTLD_NEXT, "libinput_event_get_type");
		event_device = (event_device_fn)dlsym(
			RTLD_NEXT, "libinput_event_get_device");
		accel_available = (accel_available_fn)dlsym(
			RTLD_NEXT, "libinput_device_config_accel_is_available");
		accel_set_speed = (accel_set_speed_fn)dlsym(
			RTLD_NEXT, "libinput_device_config_accel_set_speed");
	}
	if (!real_get_event)
		return NULL;
	event = real_get_event(libinput);
	if (event && event_type && event_device &&
	    event_type(event) == EVENT_DEVICE_ADDED)
		configure_device(event_device(event));
	return event;
}
