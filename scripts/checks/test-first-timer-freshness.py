#!/usr/bin/env python3
"""Exercise the shell checker and bounded timer policy together with fake clocks."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "modules/nixos/services/storage-health-monitor"
spec = importlib.util.spec_from_file_location("pending", SOURCE / "check-pending-first-timer.py")
pending = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pending)
NOW = 2_000_000_000


def prop(signature, data):
    return {"type": signature, "data": data}


def baseline():
    return {
        "timer_unit": {key: prop("s", value) for key, value in {
            "LoadState": "loaded", "ActiveState": "active", "SubState": "waiting"}.items()},
        "timer": {
            "Unit": prop("s", "fixture.service"), "Result": prop("s", "success"),
            "LastTriggerUSec": prop("t", 0), "LastTriggerUSecMonotonic": prop("t", 0),
            "NextElapseUSecMonotonic": prop("t", 1260_000_000),
            "NextElapseUSecRealtime": prop("t", 0), "AccuracyUSec": prop("t", 60_000_000),
        },
        "service_unit": {key: prop("s", value) for key, value in {
            "LoadState": "loaded", "ActiveState": "inactive"}.items()},
        "service": {"Result": prop("s", "success"), "ExecMainCode": prop("i", 0),
                    "ExecMainStatus": prop("i", 0), "ExecMainStartTimestampMonotonic": prop("t", 0)},
        "monotonic": 1200, "boottime": 1200, "realtime": NOW,
    }


def fixture_helper():
    fixture = json.loads(Path(os.environ["FIRST_TIMER_FIXTURE"]).read_text())

    def properties(name, interface):
        if fixture.get("unavailable"):
            raise OSError("fixture unavailable")
        prefix = "timer" if name.endswith(".timer") else "service"
        return fixture[prefix + ("_unit" if interface.endswith(".Unit") else "")]

    def clock(clock_id):
        return int(fixture["boottime" if clock_id == pending.time.CLOCK_BOOTTIME else "monotonic"] * 1_000_000_000)

    sys.argv = [sys.argv[0], *sys.argv[2:]]
    with patch.object(pending, "properties", properties), patch.object(pending.time, "clock_gettime_ns", clock), \
            patch.object(pending.time, "time_ns", lambda: fixture["realtime"] * 1_000_000_000):
        return pending.main()


class Freshness(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.fixture = baseline()
        self.marker = self.root / "marker"
        self.marker.write_text(f"{NOW - 2100}\n")
        self.fixture_path = self.root / "fixture.json"
        self.uptime = self.root / "uptime"
        self.ctl = self.root / "systemctl"
        self.ctl.write_text(
            f"#!{sys.executable}\nimport json,os,sys\n"
            "f=json.load(open(os.environ['FIRST_TIMER_FIXTURE']))\n"
            "p=sys.argv[4]\n"
            "s=f['service']\n"
            "v=f.get('shell',{}).get(p, s.get(p,{}).get('data',0))\n"
            "print(v)\n"
        )
        self.ctl.chmod(0o700)
        self.clock = self.root / "date"
        self.clock.write_text(f"#!/bin/sh\nprintf '{NOW}\\n'\n")
        self.clock.chmod(0o700)
        self.helper = self.root / "pending"
        self.helper.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(Path(__file__).resolve()))} --helper \"$@\"\n")
        self.helper.chmod(0o700)

    def check(self, healthy, *, enabled=True, cap=1320, age=1800):
        self.fixture_path.write_text(json.dumps(self.fixture))
        self.uptime.write_text(f"{self.fixture['boottime']} 0.00\n")
        result = subprocess.run(
            ["bash", str(SOURCE / "check-recent-success.sh"), "fixture.service", str(age),
             str(enabled).lower(), str(self.marker), str(self.uptime), str(cap)],
            env={**os.environ, "FIRST_TIMER_FIXTURE": str(self.fixture_path),
                 "STORAGE_HEALTH_SYSTEMCTL": str(self.ctl), "STORAGE_HEALTH_DATE": str(self.clock),
                 "STORAGE_HEALTH_PENDING_TIMER": str(self.helper)},
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0 if healthy else 1, result.stdout + result.stderr)
        return result

    def test_short_and_arbitrary_downtime(self):
        for marker_age in (600, 2100, 86400, 365 * 86400):
            with self.subTest(marker_age=marker_age):
                self.marker.write_text(f"{NOW - marker_age}\n")
                self.check(True)
        self.check(False, enabled=False)

    def test_missing_marker_uses_same_bound(self):
        self.marker.unlink()
        self.check(True)
        self.fixture['boottime'] = 1320
        self.check(False)

    def test_bad_markers_never_receive_grace(self):
        for text in ("", "bad\n", "175\nextra\n", "0\n", "9999999999999999999\n", f"{NOW+1}\n"):
            with self.subTest(text=text):
                self.marker.write_text(text)
                self.check(False)
        self.marker.unlink()
        self.marker.symlink_to(self.root / 'absent')
        self.check(False)

    def test_failure_precedence_with_fresh_and_stale_success(self):
        for marker_age in (25, 2100):
            self.marker.write_text(f"{NOW-marker_age}\n")
            for result, code, status in (("timeout", 2, 15), ("exit-code", 1, 1), ("exit-code", 1, 0)):
                with self.subTest(result=result, marker_age=marker_age):
                    self.fixture['service'].update(Result=prop('s', result), ExecMainCode=prop('i', code), ExecMainStatus=prop('i', status))
                    self.check(False)
        self.fixture['shell'] = {'Result': '', 'ExecMainCode': 'malformed'}
        self.check(False)

    def test_inactive_disabled_elapsed_running_or_wrong_timer(self):
        for state, substate in (("inactive", "dead"), ("failed", "failed"), ("active", "elapsed"), ("active", "running")):
            with self.subTest(state=state, substate=substate):
                self.fixture = baseline()
                self.fixture['timer_unit'].update(ActiveState=prop('s', state), SubState=prop('s', substate))
                self.check(False)
        for key, val in (("Unit", "other.service"), ("Result", "resources")):
            self.fixture = baseline()
            self.fixture['timer'][key] = prop('s', val)
            self.check(False)

    def test_trigger_or_execution_ends_grace(self):
        for key, val in (("LastTriggerUSec", NOW * 1_000_000), ("LastTriggerUSecMonotonic", 1)):
            self.fixture = baseline()
            self.fixture['timer'][key] = prop('t', val)
            self.check(False)
        self.fixture = baseline()
        self.fixture['service']['ExecMainStartTimestampMonotonic'] = prop('t', 1)
        self.check(False)
        self.fixture = baseline()
        self.fixture['service']['ExecMainCode'] = prop('i', 1)
        self.check(False)
        self.fixture['service_unit']['ActiveState'] = prop('s', 'activating')
        self.check(False)

    def test_randomized_delay_accuracy_and_deadline_boundaries(self):
        # Next-elapse already contains the selected 60-second random delay.
        # Retain exactly the accuracy window, then fail even before the boot cap.
        self.fixture['timer']['NextElapseUSecMonotonic'] = prop('t', 1220_000_000)
        for elapsed, healthy in ((1200, True), (1220, True), (1279.999999, True), (1280, False), (1281, False)):
            self.fixture['monotonic'] = elapsed
            self.fixture['boottime'] = elapsed
            self.check(healthy)

    def test_boot_cap_cannot_be_extended_by_rescheduling(self):
        self.fixture['timer']['NextElapseUSecMonotonic'] = prop('t', 86400_000_000)
        for elapsed, healthy in ((1319.999999, True), (1320, False), (86400, False)):
            self.fixture['boottime'] = elapsed
            self.fixture['monotonic'] = elapsed
            self.check(healthy)

    def test_suspend_uses_separate_clocks(self):
        self.fixture['monotonic'] = 100
        self.fixture['boottime'] = 1319
        self.check(True)
        self.fixture['boottime'] = 1320
        self.check(False)

    def test_calendar_and_mixed_deadlines(self):
        self.fixture['timer'].update(NextElapseUSecMonotonic=prop('t', 0), NextElapseUSecRealtime=prop('t', (NOW+30)*1_000_000))
        self.check(True)
        # Restored Persistent timer trigger from a previous boot is legitimate.
        self.fixture['timer']['LastTriggerUSec'] = prop('t', (NOW-86400)*1_000_000)
        self.check(True)
        self.fixture['timer']['NextElapseUSecRealtime'] = prop('t', (NOW-60)*1_000_000)
        self.check(False)
        self.fixture['timer']['NextElapseUSecMonotonic'] = prop('t', 86400_000_000)
        self.check(False)  # Later monotonic event cannot excuse missed calendar event.

    def test_unavailable_or_malformed_metadata(self):
        self.fixture['unavailable'] = True
        self.check(False)
        base = baseline()
        for section in ('timer_unit', 'timer', 'service_unit', 'service'):
            for name in base[section]:
                for bad in (None, {'type': 's', 'data': ''}, {'type': 't', 'data': -1}, {'type': 't', 'data': True}, {'type': 't', 'data': 2**64-1}):
                    with self.subTest(section=section, name=name, bad=bad):
                        self.fixture = copy.deepcopy(base)
                        self.fixture[section][name] = bad
                        self.check(False)
        self.fixture = baseline()
        self.fixture['timer']['NextElapseUSecMonotonic'] = prop('t', 0)
        self.check(False)

    def test_successful_recovery_then_normal_aging(self):
        self.fixture['timer']['LastTriggerUSecMonotonic'] = prop('t', 1200_000_000)
        self.fixture['service']['ExecMainCode'] = prop('i', 1)
        self.check(False)
        self.marker.write_text(f'{NOW-1}\n')
        self.check(True)
        self.marker.write_text(f'{NOW-1801}\n')
        self.check(False)

    def test_fresh_success_does_not_depend_on_timer(self):
        self.marker.write_text(f'{NOW-1800}\n')
        self.fixture['unavailable'] = True
        self.check(True)


class BusReplies(unittest.TestCase):
    def test_raw_numeric_properties(self):
        values = baseline()['timer']
        names = ("Unit", "Result", "LastTriggerUSec", "LastTriggerUSecMonotonic", "AccuracyUSec", "NextElapseUSecMonotonic", "NextElapseUSecRealtime")
        replies = [json.dumps({'type': 'o', 'data': ['/unit/fixture']}),
                   '\n'.join(json.dumps(values[name]) for name in names)]
        with patch.object(pending, 'busctl', side_effect=replies) as client:
            self.assertEqual(pending.properties('fixture.timer', pending.DESTINATION + '.Timer'), values)
            self.assertEqual(client.call_args.args[0], 'get-property')


    def test_wrong_reply_signature_is_rejected(self):
        with patch.object(pending, 'busctl', return_value=json.dumps({'type': 's', 'data': ['not-an-object']})):
            with self.assertRaises(ValueError):
                pending.properties('fixture.timer', 'Timer')


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--helper':
        sys.exit(fixture_helper())
    unittest.main()
