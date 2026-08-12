#define _GNU_SOURCE

#include <dlfcn.h>
#include <stdlib.h>
#include <time.h>

typedef struct _XDisplay Display;
typedef int Bool;
typedef Bool (*fake_button_fn)(Display *, unsigned int, Bool, unsigned long);

static long scroll_interval_ms(void)
{
    static long interval = -1;
    char *end = NULL;
    const char *configured;
    long parsed;

    if (interval >= 0)
        return interval;
    configured = getenv("KDECONNECT_SCROLL_INTERVAL_MS");
    if (!configured || !*configured) {
        interval = 0;
        return interval;
    }
    parsed = strtol(configured, &end, 10);
    interval = end != configured && *end == '\0' && parsed > 0 ? parsed : 0;
    return interval;
}

Bool XTestFakeButtonEvent(
    Display *display,
    unsigned int button,
    Bool is_press,
    unsigned long delay)
{
    static fake_button_fn real_fake_button;
    static long long last_scroll_ns;
    static Bool suppress_release[8];
    struct timespec now;
    long interval;
    long long now_ns;

    if (!real_fake_button)
        real_fake_button =
            (fake_button_fn)dlsym(RTLD_NEXT, "XTestFakeButtonEvent");
    if (!real_fake_button)
        return 0;

    interval = scroll_interval_ms();
    if (button >= 4 && button <= 7 && interval > 0) {
        if (!is_press && suppress_release[button]) {
            suppress_release[button] = 0;
            return 1;
        }
        if (is_press && clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
            now_ns = (long long)now.tv_sec * 1000000000LL + now.tv_nsec;
            if (last_scroll_ns != 0
                && now_ns - last_scroll_ns < interval * 1000000LL) {
                suppress_release[button] = 1;
                return 1;
            }
            last_scroll_ns = now_ns;
        }
    }

    return real_fake_button(display, button, is_press, delay);
}
