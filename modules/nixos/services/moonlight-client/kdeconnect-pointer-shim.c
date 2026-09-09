#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
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

    if (!real_warp_pointer)
        real_warp_pointer = (warp_pointer_fn)dlsym(RTLD_NEXT, "xcb_warp_pointer");

    if (destination_window != XCB_NONE) {
        query_cookie = xcb_query_pointer(connection, destination_window);
        query_reply = xcb_query_pointer_reply(connection, query_cookie, NULL);
    }
    if (query_reply) {
        send_motion("M",
                    (int)destination_x - (int)query_reply->root_x,
                    (int)destination_y - (int)query_reply->root_y);
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
