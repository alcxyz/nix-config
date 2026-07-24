#!/usr/bin/env python3
"""Mirror KDE Connect's XTest pointer into the nested Sway seat."""

import ctypes
import os
import socket
import struct
import time


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

        self.display = self.x11.XOpenDisplay(display_name.encode())
        if not self.display:
            raise RuntimeError("unable to open the X display")
        self.root = self.x11.XDefaultRootWindow(self.display)

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


def main():
    pointer = XPointer(os.environ["DISPLAY"])
    sway = SwayIpc(os.environ["SWAYSOCK"])
    hide_timeout = int(os.environ.get("NIXBOX_CURSOR_HIDE_TIMEOUT_MS", "8000"))
    cursor_size = int(os.environ.get("NIXBOX_CURSOR_SIZE", "48"))
    cursor_theme = os.environ.get("NIXBOX_CURSOR_THEME", "Adwaita")

    sway.command(f"seat seat0 hide_cursor {hide_timeout}")
    sway.command("seat seat0 hide_cursor when-typing enable")
    sway.command(f"seat seat0 xcursor_theme {cursor_theme} {cursor_size}")

    last_position = None
    while True:
        position = pointer.position()
        if position is not None and position != last_position:
            sway.command(f"seat seat0 cursor set {position[0]} {position[1]}")
            last_position = position
        time.sleep(0.005)


if __name__ == "__main__":
    main()
