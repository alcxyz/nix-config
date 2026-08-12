#!/usr/bin/env python3
"""Mirror KDE Connect's XTest pointer into the nested Sway seat."""

import ctypes
import math
import os
import socket
import struct
import threading
import time

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib


class SwayIpc:
    _header = struct.Struct("<6sII")

    def __init__(self, socket_path):
        self.socket_path = socket_path
        self.connection = None

    def _connect(self):
        if self.connection is None:
            self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.connection.connect(self.socket_path)

    def _read_exact(self, length):
        chunks = bytearray()
        while len(chunks) < length:
            chunk = self.connection.recv(length - len(chunks))
            if not chunk:
                raise ConnectionError("Sway IPC socket closed")
            chunks.extend(chunk)
        return bytes(chunks)

    def command(self, command):
        payload = command.encode()
        for attempt in range(2):
            try:
                self._connect()
                self.connection.sendall(
                    self._header.pack(b"i3-ipc", len(payload), 0) + payload
                )
                magic, response_length, _response_type = self._header.unpack(
                    self._read_exact(self._header.size)
                )
                if magic != b"i3-ipc":
                    raise ConnectionError("invalid Sway IPC response")
                self._read_exact(response_length)
                return
            except OSError:
                if self.connection is not None:
                    self.connection.close()
                    self.connection = None
                if attempt == 1:
                    raise


class XPointer:
    def __init__(self, display_name):
        self.x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.x11.XDefaultRootWindow.restype = ctypes.c_ulong
        self.x11.XDefaultScreen.argtypes = [ctypes.c_void_p]
        self.x11.XDisplayWidth.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.x11.XDisplayHeight.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.x11.XQueryPointer.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_uint),
        ]
        self.x11.XQueryPointer.restype = ctypes.c_int
        self.x11.XWarpPointer.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint,
            ctypes.c_uint,
            ctypes.c_int,
            ctypes.c_int,
        ]
        self.x11.XFlush.argtypes = [ctypes.c_void_p]

        self.display = self.x11.XOpenDisplay(display_name.encode())
        if not self.display:
            raise RuntimeError("unable to open the X display")
        self.root = self.x11.XDefaultRootWindow(self.display)
        screen = self.x11.XDefaultScreen(self.display)
        self.width = self.x11.XDisplayWidth(self.display, screen)
        self.height = self.x11.XDisplayHeight(self.display, screen)

    def position(self):
        root = ctypes.c_ulong()
        child = ctypes.c_ulong()
        root_x = ctypes.c_int()
        root_y = ctypes.c_int()
        window_x = ctypes.c_int()
        window_y = ctypes.c_int()
        mask = ctypes.c_uint()
        visible = self.x11.XQueryPointer(
            self.display,
            self.root,
            ctypes.byref(root),
            ctypes.byref(child),
            ctypes.byref(root_x),
            ctypes.byref(root_y),
            ctypes.byref(window_x),
            ctypes.byref(window_y),
            ctypes.byref(mask),
        )
        if not visible:
            return None
        return root_x.value, root_y.value

    def set_position(self, x, y):
        x = max(0, min(self.width - 1, x))
        y = max(0, min(self.height - 1, y))
        self.x11.XWarpPointer(
            self.display,
            0,
            self.root,
            0,
            0,
            0,
            0,
            x,
            y,
        )
        self.x11.XFlush(self.display)
        return x, y


class KdeConnectGate:
    _service = "org.kde.kdeconnect"
    _daemon_path = "/modules/kdeconnect"
    _daemon_interface = "org.kde.kdeconnect.daemon"
    _device_interface = "org.kde.kdeconnect.device"

    def __init__(self):
        DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SessionBus()
        self.daemon = dbus.Interface(
            self.bus.get_object(self._service, self._daemon_path),
            self._daemon_interface,
        )
        self.enabled = threading.Event()
        self.bus.add_signal_receiver(
            self._refresh,
            dbus_interface=self._daemon_interface,
        )
        self.bus.add_signal_receiver(
            self._refresh,
            dbus_interface=self._device_interface,
        )
        self.bus.add_signal_receiver(
            self._service_changed,
            signal_name="NameOwnerChanged",
            dbus_interface="org.freedesktop.DBus",
            arg0=self._service,
        )
        self.loop = GLib.MainLoop()
        self.thread = threading.Thread(target=self.loop.run, daemon=True)
        self.thread.start()
        self.refresh_thread = threading.Thread(
            target=self._periodic_refresh,
            daemon=True,
        )
        self.refresh_thread.start()
        self._refresh()

    def _periodic_refresh(self):
        while True:
            self._refresh()
            time.sleep(1)

    def _refresh(self, *_args, **_kwargs):
        try:
            # Keep the bridge armed whenever a paired device exists. KDE
            # Connect's reachability state can remain false after kdeconnectd
            # is reactivated even while remote-input XTest events are arriving.
            # Actual pointer movement remains the trigger for cursor mirroring.
            has_paired_device = bool(self.daemon.devices(False, True))
        except dbus.DBusException:
            has_paired_device = False
        if has_paired_device:
            self.enabled.set()
        else:
            self.enabled.clear()

    def _service_changed(self, _name, _old_owner, new_owner):
        if new_owner:
            self._refresh()
        else:
            self.enabled.clear()


class PointerAcceleration:
    def __init__(self, minimum_gain, maximum_gain, start_speed, full_speed):
        if minimum_gain <= 0:
            raise ValueError("minimum pointer gain must be positive")
        if maximum_gain < minimum_gain:
            raise ValueError("maximum pointer gain must not be below minimum gain")
        if start_speed < 0:
            raise ValueError("pointer acceleration start speed must not be negative")
        if full_speed <= start_speed:
            raise ValueError(
                "pointer acceleration full speed must exceed its start speed"
            )
        self.minimum_gain = minimum_gain
        self.maximum_gain = maximum_gain
        self.start_speed = start_speed
        self.full_speed = full_speed
        self.remainder_x = 0.0
        self.remainder_y = 0.0
        self.last_sample = None

    def reset(self, now):
        self.remainder_x = 0.0
        self.remainder_y = 0.0
        self.last_sample = now

    def scale(self, delta_x, delta_y, now):
        elapsed = now - self.last_sample if self.last_sample is not None else 0.05
        # An idle pause should not make the first sample of a fast swipe look
        # artificially slow, while the floor prevents a short scheduler tick
        # from producing an unbounded velocity estimate.
        elapsed = max(0.001, min(elapsed, 0.05))
        self.last_sample = now
        speed = math.hypot(delta_x, delta_y) / elapsed
        progress = max(
            0.0,
            min(
                1.0,
                (speed - self.start_speed)
                / (self.full_speed - self.start_speed),
            ),
        )
        smooth_progress = progress * progress * (3.0 - 2.0 * progress)
        gain = self.minimum_gain + (
            self.maximum_gain - self.minimum_gain
        ) * smooth_progress

        scaled_x = delta_x * gain + self.remainder_x
        scaled_y = delta_y * gain + self.remainder_y
        output_x = math.trunc(scaled_x)
        output_y = math.trunc(scaled_y)
        self.remainder_x = scaled_x - output_x
        self.remainder_y = scaled_y - output_y
        return output_x, output_y


def main():
    pointer = XPointer(os.environ["DISPLAY"])
    kdeconnect = KdeConnectGate()
    sway = SwayIpc(os.environ["SWAYSOCK"])
    hide_timeout = int(os.environ.get("NIXBOX_CURSOR_HIDE_TIMEOUT_MS", "8000"))
    hide_timeout_seconds = hide_timeout / 1000
    poll_seconds = float(os.environ.get("NIXBOX_CURSOR_POLL_MS", "1")) / 1000
    cursor_size = int(os.environ.get("NIXBOX_CURSOR_SIZE", "48"))
    cursor_theme = os.environ.get("NIXBOX_CURSOR_THEME", "Adwaita")
    pointer_sensitivity = float(
        os.environ.get("NIXBOX_KDECONNECT_POINTER_SENSITIVITY", "2.0")
    )
    precision_sensitivity = float(
        os.environ.get("NIXBOX_KDECONNECT_POINTER_PRECISION_SENSITIVITY", "0.55")
    )
    acceleration_start = float(
        os.environ.get("NIXBOX_KDECONNECT_POINTER_ACCELERATION_START", "120")
    )
    acceleration_full = float(
        os.environ.get("NIXBOX_KDECONNECT_POINTER_ACCELERATION_FULL", "900")
    )
    acceleration = PointerAcceleration(
        precision_sensitivity,
        pointer_sensitivity,
        acceleration_start,
        acceleration_full,
    )

    sway.command(f"seat seat0 hide_cursor {hide_timeout}")
    sway.command("seat seat0 hide_cursor when-typing disable")
    sway.command(f"seat seat0 xcursor_theme {cursor_theme} {cursor_size}")

    while True:
        kdeconnect.enabled.wait()
        last_position = pointer.position()
        if last_position is None:
            sway.command("seat seat0 hide_cursor 0")
        else:
            sway.command(
                "seat seat0 hide_cursor 0; "
                f"seat seat0 cursor set {last_position[0]} {last_position[1]}"
            )
        last_motion = time.monotonic()
        acceleration.reset(last_motion)
        hidden = False

        while kdeconnect.enabled.is_set():
            position = pointer.position()
            if position is not None and position != last_position:
                now = time.monotonic()
                if last_position is not None:
                    delta_x, delta_y = acceleration.scale(
                        position[0] - last_position[0],
                        position[1] - last_position[1],
                        now,
                    )
                    position = (
                        last_position[0] + delta_x,
                        last_position[1] + delta_y,
                    )
                    position = pointer.set_position(*position)
                if hidden:
                    sway.command(
                        "seat seat0 hide_cursor 0; "
                        f"seat seat0 cursor set {position[0]} {position[1]}"
                    )
                    hidden = False
                else:
                    sway.command(
                        f"seat seat0 cursor set {position[0]} {position[1]}"
                    )
                last_position = position
                last_motion = now
            elif (
                not hidden
                and time.monotonic() - last_motion >= hide_timeout_seconds
            ):
                sway.command("seat seat0 hide_cursor 1")
                hidden = True
            time.sleep(poll_seconds)

        sway.command(f"seat seat0 hide_cursor {hide_timeout}")


if __name__ == "__main__":
    main()
