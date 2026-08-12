#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <xcb/xcb.h>

typedef xcb_void_cookie_t (*warp_pointer_fn)(
    xcb_connection_t *, xcb_window_t, xcb_window_t,
    int16_t, int16_t, uint16_t, uint16_t, int16_t, int16_t);
typedef Bool (*fake_button_fn)(Display *, unsigned int, Bool, unsigned long);
typedef Bool (*fake_key_fn)(Display *, unsigned int, Bool, unsigned long);

struct pointer_acceleration {
    double minimum_gain;
    double maximum_gain;
    double start_speed;
    double full_speed;
    double remainder_x;
    double remainder_y;
    long long last_motion_ns;
    int initialized;
};

static double configured_double(const char *name, double fallback)
{
    const char *configured = getenv(name);
    char *end = NULL;
    double parsed;

    if (!configured || !*configured)
        return fallback;
    parsed = strtod(configured, &end);
    if (end == configured || *end != '\0' || !isfinite(parsed))
        return fallback;
    return parsed;
}

static struct pointer_acceleration *acceleration(void)
{
    static struct pointer_acceleration state;

    if (!state.initialized) {
        state.minimum_gain = configured_double(
            "KDECONNECT_POINTER_PRECISION_SENSITIVITY", 0.55);
        state.maximum_gain = configured_double(
            "KDECONNECT_POINTER_SENSITIVITY", 2.0);
        state.start_speed = configured_double(
            "KDECONNECT_POINTER_ACCELERATION_START", 120.0);
        state.full_speed = configured_double(
            "KDECONNECT_POINTER_ACCELERATION_FULL", 900.0);
        if (state.minimum_gain <= 0.0)
            state.minimum_gain = 0.55;
        if (state.maximum_gain < state.minimum_gain)
            state.maximum_gain = state.minimum_gain;
        if (state.start_speed < 0.0)
            state.start_speed = 120.0;
        if (state.full_speed <= state.start_speed)
            state.full_speed = state.start_speed + 1.0;
        state.initialized = 1;
    }
    return &state;
}

static void send_motion(const char *kind, int x, int y)
{
    const char *runtime_dir = getenv("XDG_RUNTIME_DIR");
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    char message[96];
    int fd;
    int message_length;

    if (!runtime_dir || !*runtime_dir)
        return;
    if (snprintf(address.sun_path, sizeof(address.sun_path),
                 "%s/kdeconnect-hypr-pointer.sock", runtime_dir)
        >= (int)sizeof(address.sun_path))
        return;

    message_length = snprintf(message, sizeof(message), "%s %d %d", kind, x, y);
    if (message_length <= 0 || message_length >= (int)sizeof(message))
        return;

    fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return;
    (void)sendto(fd, message, (size_t)message_length, MSG_DONTWAIT,
                 (const struct sockaddr *)&address, sizeof(address));
    close(fd);
}

static void accelerated_motion(
    int delta_x,
    int delta_y,
    int *output_x,
    int *output_y)
{
    struct pointer_acceleration *state = acceleration();
    struct timespec now;
    double elapsed = 0.05;
    double speed;
    double progress;
    double smooth_progress;
    double gain;
    double scaled_x;
    double scaled_y;
    long long now_ns;

    if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
        now_ns = (long long)now.tv_sec * 1000000000LL + now.tv_nsec;
        if (state->last_motion_ns != 0)
            elapsed = (double)(now_ns - state->last_motion_ns) / 1000000000.0;
        state->last_motion_ns = now_ns;
    }
    elapsed = fmax(0.001, fmin(elapsed, 0.05));
    speed = hypot((double)delta_x, (double)delta_y) / elapsed;
    progress = (speed - state->start_speed)
        / (state->full_speed - state->start_speed);
    progress = fmax(0.0, fmin(progress, 1.0));
    smooth_progress = progress * progress * (3.0 - 2.0 * progress);
    gain = state->minimum_gain
        + (state->maximum_gain - state->minimum_gain) * smooth_progress;

    scaled_x = (double)delta_x * gain + state->remainder_x;
    scaled_y = (double)delta_y * gain + state->remainder_y;
    *output_x = (int)trunc(scaled_x);
    *output_y = (int)trunc(scaled_y);
    state->remainder_x = scaled_x - (double)*output_x;
    state->remainder_y = scaled_y - (double)*output_y;
}

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
        return False;

    interval = scroll_interval_ms();
    if (button >= 4 && button <= 7 && interval > 0) {
        if (!is_press && suppress_release[button]) {
            suppress_release[button] = False;
            return True;
        }
        if (is_press && clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
            now_ns = (long long)now.tv_sec * 1000000000LL + now.tv_nsec;
            if (last_scroll_ns != 0
                && now_ns - last_scroll_ns < interval * 1000000LL) {
                suppress_release[button] = True;
                return True;
            }
            last_scroll_ns = now_ns;
        }
    }

    send_motion("B", (int)button, is_press ? 1 : 0);
    return real_fake_button(display, button, is_press, delay);
}

Bool XTestFakeKeyEvent(
    Display *display,
    unsigned int keycode,
    Bool is_press,
    unsigned long delay)
{
    static fake_key_fn real_fake_key;

    if (!real_fake_key)
        real_fake_key = (fake_key_fn)dlsym(RTLD_NEXT, "XTestFakeKeyEvent");
    if (!real_fake_key)
        return False;

    send_motion("K", (int)keycode, is_press ? 1 : 0);
    return real_fake_key(display, keycode, is_press, delay);
}

xcb_void_cookie_t xcb_warp_pointer(
    xcb_connection_t *connection,
    xcb_window_t source_window,
    xcb_window_t destination_window,
    int16_t source_x,
    int16_t source_y,
    uint16_t source_width,
    uint16_t source_height,
    int16_t destination_x,
    int16_t destination_y)
{
    static warp_pointer_fn real_warp_pointer;
    xcb_query_pointer_cookie_t query_cookie;
    xcb_query_pointer_reply_t *query_reply = NULL;
    xcb_void_cookie_t result = { 0 };
    int delta_x;
    int delta_y;
    int adjusted_x;
    int adjusted_y;

    if (!real_warp_pointer)
        real_warp_pointer = (warp_pointer_fn)dlsym(RTLD_NEXT, "xcb_warp_pointer");

    if (destination_window != XCB_NONE) {
        query_cookie = xcb_query_pointer(connection, destination_window);
        query_reply = xcb_query_pointer_reply(connection, query_cookie, NULL);
    }
    if (query_reply) {
        accelerated_motion(
            (int)destination_x - (int)query_reply->root_x,
            (int)destination_y - (int)query_reply->root_y,
            &delta_x,
            &delta_y);
        send_motion("M", delta_x, delta_y);
        adjusted_x = (int)query_reply->root_x + delta_x;
        adjusted_y = (int)query_reply->root_y + delta_y;
        destination_x = (int16_t)fmax(INT16_MIN, fmin(adjusted_x, INT16_MAX));
        destination_y = (int16_t)fmax(INT16_MIN, fmin(adjusted_y, INT16_MAX));
        free(query_reply);
    } else {
        send_motion("A", destination_x, destination_y);
    }

    if (real_warp_pointer) {
        result = real_warp_pointer(
            connection,
            source_window,
            destination_window,
            source_x,
            source_y,
            source_width,
            source_height,
            destination_x,
            destination_y);
    }
    return result;
}
