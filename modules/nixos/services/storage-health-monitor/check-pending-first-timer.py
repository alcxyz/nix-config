#!/usr/bin/env python3
"""Validate a bounded first-timer exception using numeric systemd D-Bus data."""

import json
import subprocess
import sys
import time

USEC = 1_000_000
INFINITY = 2**64 - 1
DESTINATION = "org.freedesktop.systemd1"


def busctl(*arguments):
    result = subprocess.run(
        ["busctl", "--system", "--json=short", "--timeout=5s", *arguments],
        check=True, capture_output=True, text=True, timeout=6,
    )
    return result.stdout


def properties(name, interface):
    reply = json.loads(busctl("call", DESTINATION, "/org/freedesktop/systemd1",
                            DESTINATION + ".Manager", "GetUnit", "s", name))
    if reply["type"] != "o" or len(reply["data"]) != 1:
        raise ValueError("invalid unit lookup")
    names = {
        DESTINATION + ".Unit": ("LoadState", "ActiveState", "SubState"),
        DESTINATION + ".Timer": ("Unit", "Result", "LastTriggerUSec", "LastTriggerUSecMonotonic",
                                 "AccuracyUSec", "NextElapseUSecMonotonic", "NextElapseUSecRealtime"),
        DESTINATION + ".Service": ("Result", "ExecMainCode", "ExecMainStatus", "ExecMainStartTimestampMonotonic"),
    }[interface]
    # Request only the required properties. In particular, never collect a
    # service's Environment or credential-related properties via GetAll.
    lines = busctl("get-property", DESTINATION, reply["data"][0], interface, *names).splitlines()
    if len(lines) != len(names):
        raise ValueError("invalid property reply")
    return dict(zip(names, (json.loads(line) for line in lines)))


def value(properties, name, signature):
    item = properties[name]
    data = item["data"]
    if item["type"] != signature:
        raise ValueError("invalid property type")
    if signature in ("t", "i"):
        if type(data) is not int or not 0 <= data < INFINITY:
            raise ValueError("invalid numeric property")
    elif type(data) is not str or not data or "\n" in data:
        raise ValueError("invalid string property")
    return data


def check(unit, cap, timer_unit, timer, service_unit, service, monotonic, realtime, boottime):
    for state in (timer_unit, service_unit):
        if value(state, "LoadState", "s") != "loaded":
            raise ValueError("unit is not loaded")
    if (value(timer_unit, "ActiveState", "s") != "active"
            or value(timer_unit, "SubState", "s") != "waiting"
            or value(timer, "Unit", "s") != unit
            or value(timer, "Result", "s") != "success"):
        raise ValueError("matching timer is not waiting")
    if (value(service_unit, "ActiveState", "s") != "inactive"
            or value(service, "Result", "s") != "success"
            or value(service, "ExecMainCode", "i") != 0
            or value(service, "ExecMainStatus", "i") != 0
            or value(service, "ExecMainStartTimestampMonotonic", "t") != 0):
        raise ValueError("service has already executed or is not idle")

    last = value(timer, "LastTriggerUSec", "t")
    last_monotonic = value(timer, "LastTriggerUSecMonotonic", "t")
    # Persistent calendar timers can restore a wall-clock trigger from an older
    # boot. Only current-boot triggers end the exception.
    if last_monotonic != 0 or (last != 0 and last >= realtime - monotonic):
        raise ValueError("timer has already triggered this boot")

    accuracy = value(timer, "AccuracyUSec", "t")
    next_monotonic = value(timer, "NextElapseUSecMonotonic", "t")
    next_realtime = value(timer, "NextElapseUSecRealtime", "t")
    deadlines = []
    if next_monotonic:
        deadlines.append(next_monotonic + accuracy - monotonic)
    if next_realtime:
        deadlines.append(next_realtime + accuracy - realtime)
    # RandomizedDelaySec is already included in next-elapse. AccuracySec is
    # separately applied by systemd, so allow only its finite scheduling window.
    if not deadlines or min(deadlines) <= 0:
        raise ValueError("first timer deadline is absent or overdue")
    # CLOCK_BOOTTIME includes suspend and cannot be extended by restarting the
    # timer. NextElapseUSecMonotonic uses CLOCK_MONOTONIC, a different clock.
    if boottime >= cap * USEC:
        raise ValueError("first timer boot-age cap has expired")


def main():
    if len(sys.argv) != 3 or not sys.argv[2].isdigit() or int(sys.argv[2]) <= 0:
        print("usage: check-pending-first-timer UNIT MAXIMUM_BOOT_AGE", file=sys.stderr)
        return 2
    unit = sys.argv[1]
    timer_name = unit.removesuffix(".service") + ".timer"
    try:
        timer_unit = properties(timer_name, DESTINATION + ".Unit")
        timer = properties(timer_name, DESTINATION + ".Timer")
        service_unit = properties(unit, DESTINATION + ".Unit")
        service = properties(unit, DESTINATION + ".Service")
        check(unit, int(sys.argv[2]), timer_unit, timer, service_unit, service,
              time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1000,
              time.time_ns() // 1000,
              time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1000)
    except (ValueError, KeyError, TypeError, IndexError, OSError, subprocess.SubprocessError):
        print(f"{unit}: bounded first-timer exception is unavailable or expired")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
