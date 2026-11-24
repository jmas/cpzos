/*
 * cpz-backlight — panel backlight through the m5ioe1 PWM registers.
 *
 * The kernel backlight stack cannot drive this panel on the 6.18 kernel: the
 * vendor pwm-bl driver is bound, but the backlight core keeps BL_CORE_FBBLANK
 * set, so the PWM is never programmed and /sys/class/pwm cannot export the
 * channel. Writing the duty registers over I2C is the only working control.
 *
 * This is a port of CPZ's cpz-panel-backlight with the same register map:
 *   i2c bus 1, address 0x4f
 *   0x21/0x22  PWM channel 3 duty low/high (bit 7 of high = enable)
 *   0x25/0x26  shared PWM frequency
 *   period 50000 ns
 *
 *   cpz-backlight on | off | set N | status | --selftest
 *
 * CPZ_BACKLIGHT_LOG=<file> appends the register writes instead of touching
 * I2C, which is what the image build uses to verify the byte sequence.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <linux/i2c-dev.h>
#include <linux/i2c.h>

#define I2C_BUS        1
#define I2C_ADDR       0x4f
#define REG_PWM_LOW    0x21
#define REG_PWM_HIGH   0x22
#define REG_FREQ_LOW   0x25
#define REG_FREQ_HIGH  0x26
#define PERIOD_NS      50000
#define PWM_ENABLE     0x80

struct regs {
	uint8_t freq_low, freq_high, pwm_low, pwm_high;
};

static struct regs compute(int percent)
{
	struct regs r;
	int duty, freq;

	if (percent < 0)
		percent = 0;
	if (percent > 100)
		percent = 100;

	duty = (percent * 4095 + 50) / 100;
	freq = 1000000000 / PERIOD_NS;

	r.freq_low = (uint8_t)(freq & 0xff);
	r.freq_high = (uint8_t)((freq >> 8) & 0xff);
	r.pwm_low = (uint8_t)(duty & 0xff);
	r.pwm_high = (uint8_t)(((duty >> 8) & 0x0f) | PWM_ENABLE);
	return r;
}

static void dump(const struct regs *r)
{
	printf("  %02x=%02x  %02x=%02x  %02x=%02x  %02x=%02x\n",
	       REG_FREQ_LOW, r->freq_low, REG_FREQ_HIGH, r->freq_high,
	       REG_PWM_LOW, r->pwm_low, REG_PWM_HIGH, r->pwm_high);
}

static int i2c_write(int fd, uint8_t reg, uint8_t value)
{
	uint8_t buf[2] = { reg, value };
	struct i2c_msg msg = { .addr = I2C_ADDR, .flags = 0, .len = 2, .buf = buf };
	struct i2c_rdwr_ioctl_data data = { .msgs = &msg, .nmsgs = 1 };

	return ioctl(fd, I2C_RDWR, &data) < 0 ? -1 : 0;
}

static int i2c_read(int fd, uint8_t reg, uint8_t *value)
{
	uint8_t r = reg;
	struct i2c_msg msgs[2] = {
		{ .addr = I2C_ADDR, .flags = 0, .len = 1, .buf = &r },
		{ .addr = I2C_ADDR, .flags = I2C_M_RD, .len = 1, .buf = value },
	};
	struct i2c_rdwr_ioctl_data data = { .msgs = msgs, .nmsgs = 2 };

	return ioctl(fd, I2C_RDWR, &data) < 0 ? -1 : 0;
}

/* The sysfs brightness is the vendor pwm_bl driver's cached level; it does
 * not show whether PWM4 is actually enabled. Read the m5ioe1 registers. */
static void status_actual(void)
{
	char path[32];
	uint8_t freq_low = 0, freq_high = 0, pwm_low = 0, pwm_high = 0;
	int fd;

	snprintf(path, sizeof(path), "/dev/i2c-%d", I2C_BUS);
	fd = open(path, O_RDWR);
	if (fd < 0) {
		printf("hardware: %s: %s\n", path, strerror(errno));
		return;
	}
	if (i2c_read(fd, REG_FREQ_LOW, &freq_low) < 0 ||
	    i2c_read(fd, REG_FREQ_HIGH, &freq_high) < 0 ||
	    i2c_read(fd, REG_PWM_LOW, &pwm_low) < 0 ||
	    i2c_read(fd, REG_PWM_HIGH, &pwm_high) < 0) {
		printf("hardware: register read failed: %s\n", strerror(errno));
		close(fd);
		return;
	}
	close(fd);
	printf("hardware: %02x=%02x %02x=%02x %02x=%02x %02x=%02x  %s\n",
	       REG_FREQ_LOW, freq_low, REG_FREQ_HIGH, freq_high,
	       REG_PWM_LOW, pwm_low, REG_PWM_HIGH, pwm_high,
	       (pwm_high & PWM_ENABLE) ? "enabled" : "DISABLED");
}

static int apply(int percent)
{
	struct regs r = compute(percent);
	const char *log = getenv("CPZ_BACKLIGHT_LOG");
	int fd;

	if (log) {
		FILE *f = fopen(log, "a");
		if (!f) {
			fprintf(stderr, "cpz-backlight: %s: %s\n", log, strerror(errno));
			return 1;
		}
		fprintf(f, "percent=%d\n", percent);
		fprintf(f, "%02x=%02x\n%02x=%02x\n%02x=%02x\n%02x=%02x\n",
			REG_FREQ_LOW, r.freq_low, REG_FREQ_HIGH, r.freq_high,
			REG_PWM_LOW, r.pwm_low, REG_PWM_HIGH, r.pwm_high);
		fclose(f);
		return 0;
	}

	char path[32];
	snprintf(path, sizeof(path), "/dev/i2c-%d", I2C_BUS);
	fd = open(path, O_RDWR);
	if (fd < 0) {
		/* i2c-dev creates /dev/i2c-1 when the adapter probes, which can
		 * be a few seconds after the service starts. Retry instead of
		 * failing and leaving the panel dark. */
		for (int i = 0; i < 100 && fd < 0; i++) {
			usleep(100000);
			fd = open(path, O_RDWR);
		}
	}
	if (fd < 0) {
		fprintf(stderr, "cpz-backlight: %s: %s\n", path, strerror(errno));
		fprintf(stderr, "  is i2c-dev loaded?  modprobe i2c-dev\n");
		return 1;
	}

	/* Frequency first, then duty with the enable bit. Same order as CPZ. */
	if (i2c_write(fd, REG_FREQ_LOW, r.freq_low) < 0 ||
	    i2c_write(fd, REG_FREQ_HIGH, r.freq_high) < 0 ||
	    i2c_write(fd, REG_PWM_LOW, r.pwm_low) < 0 ||
	    i2c_write(fd, REG_PWM_HIGH, r.pwm_high) < 0) {
		fprintf(stderr, "cpz-backlight: I2C write failed: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	close(fd);
	return 0;
}

static int status(void)
{
	printf("m5ioe1 backlight: i2c-%d 0x%02x, period %d ns\n",
	       I2C_BUS, I2C_ADDR, PERIOD_NS);
	status_actual();
	for (int pct = 0; pct <= 100; pct += 50) {
		struct regs r = compute(pct);
		printf("%3d%% ->", pct);
		dump(&r);
	}

	glob_t g;
	if (glob("/sys/class/backlight/*", 0, NULL, &g) == 0 && g.gl_pathc > 0) {
		for (size_t i = 0; i < g.gl_pathc; i++) {
			printf("sysfs: %s\n", g.gl_pathv[i]);
			for (const char *f = "brightness"; f;
			     f = !strcmp(f, "brightness") ? "actual_brightness"
			       : !strcmp(f, "actual_brightness") ? "max_brightness" : NULL) {
				char path[256], buf[64] = "";
				FILE *fp;
				snprintf(path, sizeof(path), "%s/%s", g.gl_pathv[i], f);
				fp = fopen(path, "r");
				if (!fp)
					continue;
				if (fgets(buf, sizeof(buf), fp))
					printf("  %-18s %s", f, buf);
				fclose(fp);
			}
		}
		globfree(&g);
	} else {
		printf("sysfs: no /sys/class/backlight device (expected on this panel)\n");
	}
	return 0;
}

static int selftest(void)
{
	static const int pct[] = { 0, 25, 50, 100 };

	printf("cpz-backlight: selftest\n");
	for (size_t i = 0; i < sizeof(pct) / sizeof(pct[0]); i++) {
		struct regs r = compute(pct[i]);
		printf("%3d%% ->", pct[i]);
		dump(&r);
	}
	return 0;
}

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "status";

	if (!strcmp(cmd, "--selftest") || !strcmp(cmd, "selftest"))
		return selftest();
	if (!strcmp(cmd, "-h") || !strcmp(cmd, "--help")) {
		printf("usage: cpz-backlight on|off|set N|status|--selftest\n");
		return 0;
	}
	if (!strcmp(cmd, "status")) {
		status();
		return 0;
	}
	if (!strcmp(cmd, "on"))
		return apply(100);
	if (!strcmp(cmd, "off"))
		return apply(0);
	if (!strcmp(cmd, "set")) {
		if (argc < 3) {
			fprintf(stderr, "usage: cpz-backlight set N\n");
			return 2;
		}
		return apply(atoi(argv[2]));
	}

	fprintf(stderr, "cpz-backlight: unknown command %s\n", cmd);
	return 2;
}
