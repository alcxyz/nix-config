{
  audioOutputControl,
  browserSelectorEnabled,
  browserStreamEnabled,
  cfg,
  couchBrowser,
  directDrmBrowserEnabled,
  directDrmStreamEnabled,
  displayLayoutControl,
  displayMirrorToggle,
  kdeConnectDirectInputEnabled,
  kdeConnectExecutable,
  kdeConnectHyprlandInput,
  lib,
  mergedUiControl,
  modeStateFile,
  pkgs,
  sessionMode,
}: let
  couchStreamControl = pkgs.writeShellApplication {
    name = "couch-stream-control";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.procps
      pkgs.systemd
    ];
    text = ''
      case "''${1:-}" in
        start)
          systemctl --user start couch-moonlight-stream.service
          hyprctl dispatch workspace 1 >/dev/null 2>&1 || true
          ;;
        remote-browser)
          systemctl --user start couch-moonlight-browser-stream.service
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          ;;
        private-browser)
          systemctl --user start couch-moonlight-browser-selector.service
          hyprctl dispatch workspace 3 >/dev/null 2>&1 || true
          ;;
        browser)
          ${
        if browserStreamEnabled
        then ''
          systemctl --user start couch-moonlight-browser-stream.service
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
        ''
        else if cfg.enableLocalBrowser
        then ''
          ${lib.getExe mergedUiControl} browser
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          if ! pgrep -u "$USER" -f -- ${lib.escapeShellArg cfg.browserProfileDirectory} \
            >/dev/null 2>&1; then
            ${lib.getExe couchBrowser} >/dev/null 2>&1 &
          fi
        ''
        else ''
          echo "No local or remote browser is configured" >&2
          exit 1
        ''
      }
          ;;
        *)
          echo "usage: couch-stream-control {start|remote-browser|private-browser|browser}" >&2
          exit 2
          ;;
      esac
    '';
  };

  closeActiveWindow = pkgs.writeShellApplication {
    name = "couch-close-active-window";
    runtimeInputs = [
      pkgs.gawk
      pkgs.hyprland
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      active_pid="$(hyprctl -j activewindow 2>/dev/null | jq -r '.pid // 0')"
      managed_unit=""

      if [[ "$active_pid" =~ ^[1-9][0-9]*$ ]] && [ -r "/proc/$active_pid/cgroup" ]; then
        cgroup="$(awk -F: '$1 == "0" { print $3; exit }' "/proc/$active_pid/cgroup")"
        case "$cgroup" in
          */couch-moonlight-stream.service)
            managed_unit=couch-moonlight-stream.service
            ;;
          */couch-moonlight-browser-stream.service)
            managed_unit=couch-moonlight-browser-stream.service
            ;;
          */couch-moonlight-browser-selector.service)
            managed_unit=couch-moonlight-browser-selector.service
            ;;
        esac
      fi

      if [ -n "$managed_unit" ]; then
        # A stalled decoder can leave Moonlight's GUI event loop unable to
        # honor Hyprland's close request. Stop the owning cgroup instead; the
        # unit applies a bounded graceful timeout before killing leftovers.
        exec systemctl --user --no-block stop "$managed_unit"
      fi

      exec hyprctl dispatch killactive
    '';
  };

  couchControlHelp = pkgs.writeShellApplication {
    name = "couch-control-help";
    text = ''
      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        echo "DMS is not installed in the user profile" >&2
        exit 1
      fi

      exec "$dms" ipc call keybinds toggle xps-media-center
    '';
  };

  controllerPython = pkgs.python3.withPackages (pythonPackages: [pythonPackages.evdev]);
  controllerDaemonSource = pkgs.writeText "couch-controller.py" ''
    import select
    import subprocess
    import time

    from evdev import InputDevice, ecodes, list_devices


    DEVICE_NAME = ${builtins.toJSON cfg.controllerDeviceName}
    HOLD_SECONDS = ${toString cfg.controllerHoldSeconds}
    ACTIONS = {
        "start": {ecodes.BTN_MODE, ecodes.BTN_EAST},
        ${lib.optionalString browserStreamEnabled ''
      "remote_browser": {ecodes.BTN_MODE, ecodes.BTN_NORTH},
    ''}
        ${lib.optionalString (browserStreamEnabled || cfg.enableLocalBrowser) ''
      "browser": {ecodes.BTN_THUMBL, ecodes.BTN_THUMBR},
    ''}
        ${lib.optionalString (cfg.enableDms || cfg.enableMergedProfile) ''
      "help": {ecodes.BTN_SELECT, ecodes.BTN_SOUTH},
    ''}
        ${lib.optionalString cfg.enableMirrorToggle ''
      "mirror": {ecodes.BTN_SELECT, ecodes.BTN_START},
    ''}
        ${lib.optionalString cfg.enableAdaptiveDisplayLayout ''
      "layout": {ecodes.BTN_SELECT, ecodes.BTN_NORTH},
    ''}
        ${lib.optionalString cfg.enableAudioOutputCycle ''
      "audio": {ecodes.BTN_SELECT, ecodes.BTN_WEST},
    ''}
    }
    COMMANDS = {
        "start": [${builtins.toJSON (lib.getExe couchStreamControl)}, "start"],
        ${lib.optionalString browserStreamEnabled ''
      "remote_browser": [${builtins.toJSON (lib.getExe couchStreamControl)}, "remote-browser"],
    ''}
        ${lib.optionalString (browserStreamEnabled || cfg.enableLocalBrowser) ''
      "browser": [${builtins.toJSON (lib.getExe couchStreamControl)}, "browser"],
    ''}
        ${lib.optionalString (cfg.enableDms || cfg.enableMergedProfile) ''
      "help": [${builtins.toJSON (lib.getExe couchControlHelp)}],
    ''}
        ${lib.optionalString cfg.enableMirrorToggle ''
      "mirror": [${builtins.toJSON (lib.getExe displayMirrorToggle)}, "toggle"],
    ''}
        ${lib.optionalString cfg.enableAdaptiveDisplayLayout ''
      "layout": [${builtins.toJSON (lib.getExe displayLayoutControl)}, "cycle"],
    ''}
        ${lib.optionalString cfg.enableAudioOutputCycle ''
      "audio": [${builtins.toJSON (lib.getExe audioOutputControl)}, "cycle"],
    ''}
    }


    def find_controller():
        for path in list_devices():
            device = InputDevice(path)
            if device.name == DEVICE_NAME and ecodes.EV_KEY in device.capabilities():
                return device
            device.close()
        return None


    def run_action(action):
        subprocess.Popen(
            COMMANDS[action],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )


    while True:
        controller = find_controller()
        if controller is None:
            time.sleep(2)
            continue

        pressed = set()
        started_at = {}
        triggered = set()

        try:
            while True:
                readable, _, _ = select.select([controller.fd], [], [], 0.1)
                if readable:
                    for event in controller.read():
                        if event.type != ecodes.EV_KEY:
                            continue
                        if event.value:
                            pressed.add(event.code)
                        else:
                            pressed.discard(event.code)

                now = time.monotonic()
                for action, buttons in ACTIONS.items():
                    if buttons.issubset(pressed):
                        started_at.setdefault(action, now)
                        if action not in triggered and now - started_at[action] >= HOLD_SECONDS:
                            run_action(action)
                            triggered.add(action)
                    else:
                        started_at.pop(action, None)
                        triggered.discard(action)
        except (OSError, ValueError):
            controller.close()
            time.sleep(1)
  '';

  controllerDaemon = pkgs.writeShellApplication {
    name = "couch-controller";
    text = ''
      exec ${controllerPython}/bin/python ${controllerDaemonSource}
    '';
  };

  directModeInputDaemonSource = pkgs.writeText "nixbox-direct-input.py" ''
    import os
    import select
    import socket
    import subprocess
    import time

    from evdev import InputDevice, UInput, ecodes, list_devices


    MODE_FILE = ${builtins.toJSON modeStateFile}
    CONTROLLER_NAME = ${builtins.toJSON cfg.controllerDeviceName}
    CONTROLLER_HOLD_SECONDS = ${toString cfg.controllerHoldSeconds}
    DEVICE_REFRESH_SECONDS = 1.0
    INACTIVE_MODE_SLEEP_SECONDS = 0.5
    KDECONNECT_DIRECT_INPUT = ${
      if kdeConnectDirectInputEnabled
      then "True"
      else "False"
    }
    KDECONNECT_SOCKET_PATH = os.path.join(
        os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"),
        "kdeconnect-hypr-pointer.sock",
    )
    IGNORED_KEYBOARD_NAMES = ("kde connect", "moonlight", "uinput", "virtual", "waynergy")
    KDECONNECT_BUTTONS = {
        1: ecodes.BTN_LEFT,
        2: ecodes.BTN_MIDDLE,
        3: ecodes.BTN_RIGHT,
        8: ecodes.BTN_SIDE,
        9: ecodes.BTN_EXTRA,
    }
    KDECONNECT_SCROLL = {
        4: (ecodes.REL_WHEEL, 1),
        5: (ecodes.REL_WHEEL, -1),
        6: (ecodes.REL_HWHEEL, -1),
        7: (ecodes.REL_HWHEEL, 1),
    }
    KDECONNECT_UINPUT_CAPABILITIES = {
        ecodes.EV_KEY: list(range(1, ecodes.KEY_MAX + 1)),
        ecodes.EV_REL: [
            ecodes.REL_X,
            ecodes.REL_Y,
            ecodes.REL_WHEEL,
            ecodes.REL_HWHEEL,
        ],
    }
    COMMANDS = {
        ${lib.optionalString directDrmBrowserEnabled ''
      "direct-browser": [${builtins.toJSON (lib.getExe sessionMode)}, "direct-browser"],
    ''}
        ${lib.optionalString directDrmStreamEnabled ''
      "direct-stream": [${builtins.toJSON (lib.getExe sessionMode)}, "direct-stream"],
    ''}
        ${lib.optionalString (directDrmBrowserEnabled && browserSelectorEnabled) ''
      "direct-private": [${builtins.toJSON (lib.getExe sessionMode)}, "direct-private"],
    ''}
    }


    def current_mode():
        try:
            with open(MODE_FILE, encoding="utf-8") as mode_file:
                return mode_file.read().strip().split(":", 1)[0]
        except OSError:
            return ""


    def open_kdeconnect_input():
        if not KDECONNECT_DIRECT_INPUT:
            return None, None
        try:
            os.unlink(KDECONNECT_SOCKET_PATH)
        except FileNotFoundError:
            pass
        input_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            input_socket.bind(KDECONNECT_SOCKET_PATH)
            os.chmod(KDECONNECT_SOCKET_PATH, 0o600)
            input_socket.setblocking(False)
            virtual_input = UInput(
                KDECONNECT_UINPUT_CAPABILITIES,
                name="Nixbox KDE Connect Direct Input",
            )
        except Exception:
            input_socket.close()
            try:
                os.unlink(KDECONNECT_SOCKET_PATH)
            except FileNotFoundError:
                pass
            raise
        print("Listening for direct KDE Connect input", flush=True)
        return input_socket, virtual_input


    def close_kdeconnect_input(input_socket, virtual_input):
        if input_socket is None and virtual_input is None:
            return
        if input_socket is not None:
            input_socket.close()
        if virtual_input is not None:
            virtual_input.close()
        try:
            os.unlink(KDECONNECT_SOCKET_PATH)
        except FileNotFoundError:
            pass


    def inject_kdeconnect_message(virtual_input, message):
        try:
            kind, first, second = message.decode().split()
            first = int(first)
            second = int(second)
        except (UnicodeDecodeError, ValueError):
            return

        if kind == "K":
            # Xorg's standard evdev keycodes are Linux input codes plus eight.
            code = first - 8
            if 0 < code <= ecodes.KEY_MAX:
                virtual_input.write(ecodes.EV_KEY, code, int(bool(second)))
                virtual_input.syn()
        elif kind == "B":
            if first in KDECONNECT_SCROLL:
                if second:
                    code, value = KDECONNECT_SCROLL[first]
                    virtual_input.write(ecodes.EV_REL, code, value)
                    virtual_input.syn()
            elif first in KDECONNECT_BUTTONS:
                virtual_input.write(
                    ecodes.EV_KEY,
                    KDECONNECT_BUTTONS[first],
                    int(bool(second)),
                )
                virtual_input.syn()
        elif kind == "M" and (first or second):
            if first:
                virtual_input.write(ecodes.EV_REL, ecodes.REL_X, first)
            if second:
                virtual_input.write(ecodes.EV_REL, ecodes.REL_Y, second)
            virtual_input.syn()


    def close_devices(devices):
        for state in devices.values():
            state["device"].close()
        devices.clear()


    def classify_device(device):
        capabilities = device.capabilities()
        keys = set(capabilities.get(ecodes.EV_KEY, []))

        if device.name == CONTROLLER_NAME and ecodes.BTN_MODE in keys:
            return "controller"

        name = device.name.lower()
        if any(fragment in name for fragment in IGNORED_KEYBOARD_NAMES):
            return None
        has_meta = ecodes.KEY_LEFTMETA in keys or ecodes.KEY_RIGHTMETA in keys
        if has_meta and ecodes.KEY_R in keys and ecodes.KEY_M in keys:
            return "keyboard"
        return None


    def refresh_devices(devices):
        available_paths = set(list_devices())
        for path in list(devices):
            if path not in available_paths:
                devices.pop(path)["device"].close()

        for path in sorted(available_paths - set(devices)):
            try:
                device = InputDevice(path)
                role = classify_device(device)
                if role is None:
                    device.close()
                    continue
                devices[path] = {
                    "device": device,
                    "role": role,
                    "pressed": set(),
                    "hat_up": False,
                    "candidate": None,
                    "candidate_since": None,
                    "latched": False,
                }
                print(f"Listening to {role} input from {device.name}", flush=True)
            except (OSError, PermissionError):
                continue


    def keyboard_action(state):
        pressed = state["pressed"]
        meta = ecodes.KEY_LEFTMETA in pressed or ecodes.KEY_RIGHTMETA in pressed
        shift = ecodes.KEY_LEFTSHIFT in pressed or ecodes.KEY_RIGHTSHIFT in pressed
        if not meta:
            return None
        ${lib.optionalString (
      directDrmBrowserEnabled && browserSelectorEnabled
    ) "if shift and ecodes.KEY_R in pressed:\n        return \"direct-private\"\n"}
        ${lib.optionalString directDrmBrowserEnabled "if not shift and ecodes.KEY_R in pressed:\n        return \"direct-browser\"\n"}
        ${lib.optionalString directDrmStreamEnabled "if not shift and ecodes.KEY_M in pressed:\n        return \"direct-stream\"\n"}
        return None


    def controller_action(state):
        pressed = state["pressed"]
        ${
      lib.optionalString (directDrmBrowserEnabled && browserSelectorEnabled)
      "if (\n        state[\"hat_up\"]\n        and ecodes.BTN_START in pressed\n        and ecodes.BTN_TR in pressed\n    ):\n        return \"direct-private\"\n"
    }
        ${lib.optionalString directDrmBrowserEnabled "if ecodes.BTN_MODE in pressed and ecodes.BTN_NORTH in pressed:\n        return \"direct-browser\"\n"}
        ${lib.optionalString directDrmStreamEnabled "if ecodes.BTN_MODE in pressed and ecodes.BTN_EAST in pressed:\n        return \"direct-stream\"\n"}
        return None


    def requested_action(state):
        if state["role"] == "keyboard":
            return keyboard_action(state)
        return controller_action(state)


    def run_action(action):
        print(f"Requesting {action}", flush=True)
        subprocess.Popen(
            COMMANDS[action],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )


    devices = {}
    next_refresh = 0.0
    kdeconnect_socket = None
    kdeconnect_uinput = None

    while True:
        if not current_mode().startswith("direct-"):
            close_devices(devices)
            close_kdeconnect_input(kdeconnect_socket, kdeconnect_uinput)
            kdeconnect_socket = None
            kdeconnect_uinput = None
            next_refresh = 0.0
            time.sleep(INACTIVE_MODE_SLEEP_SECONDS)
            continue

        if KDECONNECT_DIRECT_INPUT and kdeconnect_socket is None:
            try:
                kdeconnect_socket, kdeconnect_uinput = open_kdeconnect_input()
            except (OSError, PermissionError) as error:
                print(f"Waiting for KDE Connect direct input: {error}", flush=True)
                time.sleep(INACTIVE_MODE_SLEEP_SECONDS)
                continue

        now = time.monotonic()
        if now >= next_refresh:
            refresh_devices(devices)
            next_refresh = now + DEVICE_REFRESH_SECONDS

        readers = [state["device"].fd for state in devices.values()]
        if kdeconnect_socket is not None:
            readers.append(kdeconnect_socket)
        if not readers:
            time.sleep(INACTIVE_MODE_SLEEP_SECONDS)
            continue

        try:
            readable, _, _ = select.select(
                readers,
                [],
                [],
                0.1,
            )
        except (OSError, ValueError):
            close_devices(devices)
            close_kdeconnect_input(kdeconnect_socket, kdeconnect_uinput)
            kdeconnect_socket = None
            kdeconnect_uinput = None
            next_refresh = 0.0
            continue

        if kdeconnect_socket is not None and kdeconnect_socket in readable:
            while True:
                try:
                    message = kdeconnect_socket.recv(96)
                except BlockingIOError:
                    break
                try:
                    inject_kdeconnect_message(kdeconnect_uinput, message)
                except OSError:
                    close_kdeconnect_input(kdeconnect_socket, kdeconnect_uinput)
                    kdeconnect_socket = None
                    kdeconnect_uinput = None
                    break

        readable_fds = {
            item if isinstance(item, int) else item.fileno()
            for item in readable
        }
        for path, state in list(devices.items()):
            if state["device"].fd not in readable_fds:
                continue
            try:
                for event in state["device"].read():
                    if event.type == ecodes.EV_KEY:
                        if event.value:
                            state["pressed"].add(event.code)
                        else:
                            state["pressed"].discard(event.code)
                    elif (
                        state["role"] == "controller"
                        and event.type == ecodes.EV_ABS
                        and event.code == ecodes.ABS_HAT0Y
                    ):
                        state["hat_up"] = event.value < 0
            except (OSError, ValueError):
                devices.pop(path)["device"].close()
                continue

        now = time.monotonic()
        for state in devices.values():
            action = requested_action(state)
            if action is None:
                state["candidate"] = None
                state["candidate_since"] = None
                state["latched"] = False
                continue
            if state["latched"]:
                continue
            if state["candidate"] != action:
                state["candidate"] = action
                state["candidate_since"] = now
                continue
            hold_seconds = 0.0 if state["role"] == "keyboard" else CONTROLLER_HOLD_SECONDS
            if now - state["candidate_since"] >= hold_seconds:
                run_action(action)
                state["latched"] = True
  '';

  directModeInputDaemon = pkgs.writeShellApplication {
    name = "nixbox-direct-input";
    text = ''
      exec ${controllerPython}/bin/python ${directModeInputDaemonSource}
    '';
  };

  kdeConnectPointerShimSource = pkgs.writeText "kdeconnect-hypr-pointer-shim.c" ''
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
  '';

  kdeConnectPointerShim =
    pkgs.runCommandCC "kdeconnect-hypr-pointer-shim"
    {
      nativeBuildInputs = [pkgs.pkg-config];
      buildInputs = [
        pkgs.libx11
        pkgs.libxcb
        pkgs.libxi
        pkgs.libxtst
      ];
    }
    ''
      install -d "$out/lib"
      "$CC" \
        -shared \
        -fPIC \
        -Wall \
        -Wextra \
        -Werror \
        $(${pkgs.pkg-config}/bin/pkg-config --cflags x11 xcb xi xtst) \
        -o "$out/lib/libkdeconnect-hypr-pointer-shim.so" \
        ${kdeConnectPointerShimSource} \
        $(${pkgs.pkg-config}/bin/pkg-config --libs x11 xcb xi xtst) \
        -ldl
    '';

  kdeConnectSessionLauncher = pkgs.writeShellApplication {
    name = "nixbox-kdeconnect-session";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.xorg-server
    ];
    text = ''
      mode="$(
        tr -d '[:space:]' \
          < ${lib.escapeShellArg modeStateFile} \
          2>/dev/null \
          || true
      )"
      case "''${mode%%:*}" in
        direct-*) ;;
        *)
          export DISPLAY=:0
          exec ${kdeConnectExecutable} --replace
          ;;
      esac

      display_file="$(mktemp -p "''${XDG_RUNTIME_DIR:-/tmp}" kdeconnect-xvfb.XXXXXX)"
      xvfb_pid=
      kdeconnect_pid=

      cleanup() {
        trap - EXIT INT TERM
        if [ -n "$kdeconnect_pid" ]; then
          kill "$kdeconnect_pid" >/dev/null 2>&1 || true
        fi
        if [ -n "$xvfb_pid" ]; then
          kill "$xvfb_pid" >/dev/null 2>&1 || true
        fi
        rm -f "$display_file"
      }
      terminate() {
        exit 0
      }
      trap cleanup EXIT
      trap terminate INT TERM

      ${lib.getExe' pkgs.xorg-server "Xvfb"} \
        -displayfd 3 \
        -nolisten tcp \
        -noreset \
        -screen 0 2560x1440x24 \
        3>"$display_file" &
      xvfb_pid=$!

      for _attempt in $(seq 1 50); do
        if [ -s "$display_file" ]; then
          break
        fi
        if ! kill -0 "$xvfb_pid" >/dev/null 2>&1; then
          echo "KDE Connect Xvfb exited before becoming ready" >&2
          exit 1
        fi
        sleep 0.1
      done
      if [ ! -s "$display_file" ]; then
        echo "KDE Connect Xvfb did not become ready" >&2
        exit 1
      fi

      display_number="$(tr -d '[:space:]' < "$display_file")"
      export DISPLAY=":$display_number"
      ${kdeConnectExecutable} --replace &
      kdeconnect_pid=$!
      wait "$kdeconnect_pid"
    '';
  };

  pointerSyncSource = pkgs.writeText "couch-xwayland-pointer-bridge.py" ''
    import json
    import os
    import re
    import socket
    import subprocess
    import time


    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    signature = os.environ["HYPRLAND_INSTANCE_SIGNATURE"]
    hypr_socket = os.path.join(runtime_dir, "hypr", signature, ".socket.sock")
    kdeconnect_socket_path = os.path.join(
        runtime_dir, "kdeconnect-hypr-pointer.sock"
    )
    xrandr_output = re.compile(
        r"^(\S+) connected(?: primary)? (\d+)x(\d+)\+(-?\d+)\+(-?\d+)"
    )
    def hypr_request(command):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(0.25)
                client.connect(hypr_socket)
                client.sendall(command.encode())
                response = bytearray()
                while True:
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    response.extend(chunk)
                return response.decode()
        except (OSError, UnicodeDecodeError):
            return ""


    def monitor_mapping():
        try:
            xrandr = subprocess.run(
                [${builtins.toJSON (lib.getExe pkgs.xrandr)}, "--query"],
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=2,
            ).stdout
            hypr = json.loads(hypr_request("j/monitors all") or "[]")
        except (json.JSONDecodeError, OSError, subprocess.SubprocessError):
            return []

        x_outputs = {}
        for line in xrandr.splitlines():
            match = xrandr_output.match(line)
            if match:
                name, width, height, x, y = match.groups()
                x_outputs[name] = tuple(map(int, (x, y, width, height)))

        mapping = []
        for monitor in hypr:
            source = x_outputs.get(monitor.get("name"))
            scale = float(monitor.get("scale") or 1)
            if source is None or scale <= 0:
                continue
            mapping.append(
                (
                    source,
                    (
                        int(monitor.get("x", 0)),
                        int(monitor.get("y", 0)),
                        round(int(monitor.get("width", 0)) / scale),
                        round(int(monitor.get("height", 0)) / scale),
                    ),
                )
            )
        return mapping


    def translate(x, y, mapping):
        for (source_x, source_y, source_width, source_height), (
            target_x,
            target_y,
            target_width,
            target_height,
        ) in mapping:
            if (
                source_width > 0
                and source_height > 0
                and source_x <= x < source_x + source_width
                and source_y <= y < source_y + source_height
            ):
                local_x = (x - source_x) / source_width
                local_y = (y - source_y) / source_height
                return (
                    round(target_x + local_x * target_width),
                    round(target_y + local_y * target_height),
                )
        return None


    try:
        os.unlink(kdeconnect_socket_path)
    except FileNotFoundError:
        pass
    kdeconnect_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    kdeconnect_socket.bind(kdeconnect_socket_path)
    os.chmod(kdeconnect_socket_path, 0o600)
    kdeconnect_socket.setblocking(False)
    mapping = []
    mapping_updated_at = 0.0

    while True:
        now = time.monotonic()
        if now - mapping_updated_at >= 2:
            mapping = monitor_mapping()
            mapping_updated_at = now

        while True:
            try:
                message = kdeconnect_socket.recv(96).decode().split()
            except BlockingIOError:
                break
            except (OSError, UnicodeDecodeError):
                continue

            try:
                kind, first, second = message
                first = float(first)
                second = float(second)
            except (ValueError, TypeError):
                continue

            if kind == "M":
                try:
                    current = json.loads(hypr_request("j/cursorpos") or "{}")
                    target = (
                        round(float(current["x"]) + first),
                        round(float(current["y"]) + second),
                    )
                except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                    continue
            elif kind == "A":
                target = translate(first, second, mapping)
                if target is None:
                    continue
            else:
                continue
            hypr_request(f"dispatch movecursor {target[0]} {target[1]}")

        time.sleep(1 / 60)
  '';

  pointerSync = kdeConnectHyprlandInput;

  kdeConnectDbusServiceOverride = pkgs.writeTextFile {
    name = "kdeconnect-dbus-systemd-service";
    destination = "/share/dbus-1/services/org.kde.kdeconnect.service";
    text = ''
      [D-BUS Service]
      Name=org.kde.kdeconnect
      Exec=${pkgs.systemd}/bin/systemctl --user start kdeconnect.service
      SystemdService=kdeconnect.service
    '';
  };
in {
  inherit
    closeActiveWindow
    controllerDaemon
    couchControlHelp
    couchStreamControl
    directModeInputDaemon
    kdeConnectDbusServiceOverride
    kdeConnectSessionLauncher
    pointerSync
    ;
}
