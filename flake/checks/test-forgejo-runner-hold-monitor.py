#!/usr/bin/env python3
"""Synthetic runner hold monitor tests; never contact systemd or Healthchecks."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MONITOR = Path(sys.argv.pop(1)).resolve()
PRIMARY = 'forgejo-actions-runner.service'
POOL = 'forgejo-podman-runner.service'
STANDBY = 'forgejo-podman-runner-fast.service'
GUARD = 'forgejo-runner-io-pressure-guard.service'
PING_BASE = 'https://hc.example.invalid/ping/fixture-key'

FAKE_SYSTEMCTL = r'''#!/usr/bin/env python3
import os, sys
from pathlib import Path
units = Path(os.environ['FAKE_UNITS'])
args = sys.argv[1:]
assert args[0] == 'show', args
log = Path(os.environ['FAKE_LOG'])
with log.open('a') as handle:
    handle.write(' '.join(args) + '\n')
unit = args[-1]
props = {}
path = units / unit
if path.exists():
    for line in path.read_text().splitlines():
        key, _, value = line.partition('=')
        props[key] = value
else:
    props = {'LoadState': 'not-found', 'UnitFileState': '', 'ActiveState': 'inactive',
             'SubState': 'dead', 'Result': 'success'}
wanted = [arg.split('=', 1)[1] for arg in args if arg.startswith('--property=')]
if '--value' in args:
    for key in wanted:
        print(props.get(key, ''))
else:
    for key in wanted:
        print(f'{key}={props.get(key, "")}')
'''

FAKE_CURL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
config = sys.stdin.read()
entry = {'argv': sys.argv[1:]}
for line in config.splitlines():
    key, _, value = line.partition(' = ')
    value = value.strip('"')
    if key == 'url':
        entry['url'] = value
    elif key == 'data-binary':
        entry['body'] = Path(value.lstrip('@')).read_text()
with open(os.environ['FAKE_PINGS'], 'a') as handle:
    handle.write(json.dumps(entry) + '\n')
'''


def unit_state(active='active', sub=None, result='success', load='loaded',
               enabled='enabled'):
    sub = sub or {'active': 'running', 'inactive': 'dead', 'failed': 'failed',
                  'deactivating': 'stop-sigterm'}.get(active, 'dead')
    return {'LoadState': load, 'UnitFileState': enabled, 'ActiveState': active,
            'SubState': sub, 'Result': result}


class HoldMonitorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / 'guard'
        (self.state / 'runners' / POOL).mkdir(parents=True)
        (self.state / 'runners' / STANDBY).mkdir(parents=True)
        self.monitor_state = self.root / 'monitor'
        self.units = self.root / 'units'
        self.units.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name, text in (('systemctl', FAKE_SYSTEMCTL), ('curl', FAKE_CURL)):
            path = self.bin / name
            # The build sandbox has no /usr/bin/env.
            path.write_text(text.replace('#!/usr/bin/env python3', f'#!{sys.executable}', 1))
            path.chmod(0o755)
        self.ping_base = self.root / 'ping-base'
        self.ping_base.write_text(PING_BASE + '\n')
        self.pings = self.root / 'pings'
        self.log = self.root / 'systemctl.log'
        self.uptime = 10000
        self.set_unit(GUARD, unit_state())
        for unit in (PRIMARY, POOL):
            self.set_unit(unit, unit_state())
        # A standby that its controller has not admitted is inactive by design.
        self.set_unit(STANDBY, unit_state('inactive', result='exec-condition'))
        (self.state / 'runners' / STANDBY / 'standby-held').touch()

    def tearDown(self):
        self.tmp.cleanup()

    def set_unit(self, unit, props):
        (self.units / unit).write_text(
            ''.join(f'{key}={value}\n' for key, value in props.items()))

    def run_monitor(self, game='0', advance=0):
        self.uptime += advance
        uptime_file = self.root / 'uptime'
        uptime_file.write_text(f'{self.uptime}.42 1.00\n')
        if self.pings.exists():
            self.pings.unlink()
        env = dict(os.environ,
                   STATE_DIR=str(self.state),
                   MONITOR_STATE_DIR=str(self.monitor_state),
                   SYSTEMCTL_BIN=str(self.bin / 'systemctl'),
                   CURL_BIN=str(self.bin / 'curl'),
                   UPTIME_FILE=str(uptime_file),
                   RUNNER_UNITS=f'{PRIMARY} {POOL} {STANDBY}',
                   STANDBY_UNITS=STANDBY,
                   MAX_HOLD_SECONDS='1800',
                   GAME_ADMISSION_ENABLED=game,
                   GAME_HOLD_SECONDS='90',
                   PING_BASE_FILE=str(self.ping_base),
                   SLUG='ci-runners-fixture',
                   FAKE_UNITS=str(self.units),
                   FAKE_PINGS=str(self.pings),
                   FAKE_LOG=str(self.log))
        result = subprocess.run([str(MONITOR)], env=env, capture_output=True,
                                text=True, timeout=60)
        pings = []
        if self.pings.exists():
            pings = [json.loads(line) for line in self.pings.read_text().splitlines()]
        for ping in pings:
            # The private ping base reaches curl on stdin only.
            self.assertFalse(any('fixture-key' in arg for arg in ping['argv']), ping)
            self.assertIn('--config', ping['argv'])
        return result, pings

    def final_ping(self, pings):
        final = [ping for ping in pings if not ping['url'].endswith('/start?create=1')]
        self.assertEqual(len(final), 1, pings)
        return final[0]

    def assert_success(self, result, pings):
        self.assertEqual(result.returncode, 0, result.stderr)
        ping = self.final_ping(pings)
        self.assertEqual(ping['url'], f'{PING_BASE}/ci-runners-fixture?create=1')
        return ping

    def assert_failure(self, result, pings):
        self.assertNotEqual(result.returncode, 0)
        ping = self.final_ping(pings)
        self.assertEqual(ping['url'], f'{PING_BASE}/ci-runners-fixture/fail?create=1')
        return ping

    def assert_read_only(self):
        # Only systemd queries, never start, stop or reset.
        for line in self.log.read_text().splitlines():
            self.assertTrue(line.startswith('show '), line)

    def test_healthy_pings_success(self):
        result, pings = self.run_monitor()
        ping = self.assert_success(result, pings)
        self.assertIn(f'{PRIMARY}: admitting', ping['body'])
        self.assertIn(f'{STANDBY}: standby, not admitted', ping['body'])
        self.assertTrue(any(p['url'].endswith('/start?create=1') for p in pings))
        self.assert_read_only()

    def test_drain_beyond_bound_names_cause(self):
        (self.state / 'drain-owned').write_text('123\n')
        (self.state / 'runners' / POOL / 'drain-owned').write_text('456\n')
        self.set_unit(PRIMARY, unit_state('inactive'))
        self.set_unit(POOL, unit_state('inactive'))
        result, pings = self.run_monitor()
        self.assert_success(result, pings)
        result, pings = self.run_monitor(advance=1900)
        ping = self.assert_failure(result, pings)
        self.assertIn(f'{PRIMARY}: held for 32m (bound 30m)', ping['body'])
        self.assertIn(f'{POOL}: held for 32m', ping['body'])
        self.assertIn('markers=drain-owned', ping['body'])
        self.assertIn('guard=active', ping['body'])
        self.assert_read_only()
        # Recovery clears the hold.
        self.set_unit(PRIMARY, unit_state())
        self.set_unit(POOL, unit_state())
        result, pings = self.run_monitor(advance=300)
        self.assert_success(result, pings)

    def test_hold_under_bound_pings_success(self):
        (self.state / 'drain-owned').write_text('123\n')
        self.set_unit(PRIMARY, unit_state('deactivating'))
        self.run_monitor()
        result, pings = self.run_monitor(advance=1700)
        ping = self.assert_success(result, pings)
        self.assertIn(f'{PRIMARY}: held for 29m, under bound', ping['body'])

    def test_cleanup_fence_is_a_cause(self):
        (self.state / 'cleanup-in-flight').write_text('fixture\n')
        (self.state / 'runners' / POOL / 'resume-queued').write_text('100\n')
        self.set_unit(POOL, unit_state('inactive', result='exec-condition'))
        self.run_monitor()
        result, pings = self.run_monitor(advance=1800)
        ping = self.assert_failure(result, pings)
        self.assertIn(f'{POOL}: held for 30m', ping['body'])
        self.assertIn('markers=cleanup-in-flight,resume-queued', ping['body'])
        self.assertNotIn(f'{PRIMARY}: held', ping['body'])

    def test_manual_stop_and_mask_are_held(self):
        self.set_unit(PRIMARY, unit_state('inactive'))
        self.set_unit(POOL, unit_state('inactive', load='masked', enabled='masked'))
        self.run_monitor()
        result, pings = self.run_monitor(advance=1800)
        ping = self.assert_failure(result, pings)
        self.assertIn(f'{PRIMARY}: held for 30m', ping['body'])
        self.assertIn('markers=none', ping['body'])
        self.assertIn('load_state=masked', ping['body'])

    def test_game_hold_excluded_and_restarts_count(self):
        (self.state / 'drain-owned').write_text('123\n')
        self.set_unit(PRIMARY, unit_state('inactive'))
        (self.state / 'game-last-seen').write_text(f'{self.uptime - 5}\n')
        result, pings = self.run_monitor(game='1')
        self.assert_success(result, pings)
        (self.state / 'game-last-seen').write_text(f'{self.uptime + 3595}\n')
        result, pings = self.run_monitor(game='1', advance=3600)
        ping = self.assert_success(result, pings)
        self.assertIn(f'{PRIMARY}: held for a detected game', ping['body'])
        # Once the game record ages out the count starts again.
        result, pings = self.run_monitor(game='1', advance=600)
        ping = self.assert_success(result, pings)
        self.assertIn(f'{PRIMARY}: held for 0m, under bound', ping['body'])
        result, pings = self.run_monitor(game='1', advance=1800)
        self.assert_failure(result, pings)

    def test_game_does_not_excuse_masked_unit(self):
        self.set_unit(PRIMARY, unit_state('inactive', load='masked', enabled='masked'))
        (self.state / 'game-last-seen').write_text(f'{self.uptime + 1800}\n')
        self.run_monitor(game='1')
        result, pings = self.run_monitor(game='1', advance=1800)
        self.assert_failure(result, pings)

    def test_admitted_standby_that_is_down_is_held(self):
        (self.state / 'runners' / STANDBY / 'standby-admitted').touch()
        self.run_monitor()
        result, pings = self.run_monitor(advance=1800)
        ping = self.assert_failure(result, pings)
        self.assertIn(f'{STANDBY}: held for 30m', ping['body'])

    def test_unreadable_ping_base_fails_unit(self):
        self.ping_base.unlink()
        result, pings = self.run_monitor()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(pings, [])

    def test_empty_ping_base_fails_unit(self):
        self.ping_base.write_text('\n')
        result, _ = self.run_monitor()
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
