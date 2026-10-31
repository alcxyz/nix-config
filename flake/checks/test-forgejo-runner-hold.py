#!/usr/bin/env python3
"""Synthetic runner hold, start gate and game signal tests.

They never contact systemd, an engine or Healthchecks: systemctl, curl, pgrep,
ss and sleep are fakes, and sleep advances a fake clock.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HOLD = Path(sys.argv.pop(1)).resolve()
GATE = Path(sys.argv.pop(1)).resolve()
SIGNAL = Path(sys.argv.pop(1)).resolve()
DISK_HELPER = Path(os.environ.get('DISK_HELPER_FILE', HOLD.with_name('disk-space-admission.sh')))
GAME_SCAN = Path(os.environ.get('GAME_SCAN_FILE', SIGNAL.with_name('game-scan.sh')))
PRIMARY = 'forgejo-actions-runner.service'
POOL = 'forgejo-podman-runner.service'
FAST = 'forgejo-podman-runner-fast.service'
RUNNERS = [PRIMARY, POOL, FAST]
GAME_UNIT = 'game-signal.service'
RESET_UNIT = 'forgejo-podman-store-reset.service'
GIB = 1024 ** 3

# Units live in one JSON file. A stop leaves a unit inactive, or in the state
# the fixture names (a stop that times out ends failed); a start makes it
# active unless the fixture refuses it.
FAKE_SYSTEMCTL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
path = Path(os.environ['FAKE_STATE'])
state = json.loads(path.read_text())
args = [arg for arg in sys.argv[1:] if arg not in ('--no-block', '--quiet')]
with open(os.environ['FAKE_LOG'], 'a') as handle:
    handle.write(' '.join(args) + '\n')
units = state['units']
def unit(name):
    return units.setdefault(name, {'LoadState': 'loaded', 'UnitFileState': 'enabled',
                                   'ActiveState': 'inactive', 'Result': 'success'})
if args[0] == 'show':
    name = args[-1]
    for arg in args:
        if arg.startswith('--property='):
            key = arg.split('=', 1)[1]
            value = unit(name).get(key, '')
            print(value if '--value' in args else f'{key}={value}')
elif args[0] == 'is-active':
    sys.exit(0 if unit(args[-1])['ActiveState'] == 'active' else 3)
elif args[0] == 'stop':
    unit(args[1]).update(ActiveState=state.get('stop_to', {}).get(args[1], 'inactive'), SubState='')
    if unit(args[1])['ActiveState'] == 'failed':
        unit(args[1])['Result'] = 'timeout'
elif args[0] == 'start':
    if args[1] in state.get('fail_start', []):
        unit(args[1]).update(ActiveState='failed', SubState='failed', Result='exit-code')
    elif args[1] not in state.get('refuse', []):
        unit(args[1]).update(ActiveState='active', SubState='running', Result='success')
    else:
        # The start gate refuses and leaves its marker.
        marker = Path(os.environ['STATE_DIR']) / 'runners' / args[1] / 'held'
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.touch()
elif args[0] == 'reset-failed':
    if unit(args[1])['ActiveState'] == 'failed':
        unit(args[1]).update(ActiveState='inactive', SubState='dead', Result='success')
else:
    sys.exit(2)
path.write_text(json.dumps(state))
'''

# Each sleep is one sample: it advances the clock by the sample interval and
# runs the fixture's step for the next sample, if any.
FAKE_SLEEP = r'''#!/usr/bin/env python3
import os, subprocess
from pathlib import Path
root = Path(os.environ['FAKE_ROOT'])
counter = root / 'samples'
sample = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(sample))
clock = root / 'uptime'
now = float(clock.read_text().split()[0]) + float(os.environ.get('FAKE_STEP', '5'))
clock.write_text(f'{now:.2f} 0.00\n')
step = root / 'steps' / str(sample)
if step.exists():
    subprocess.run(['bash', str(step)], check=True)
'''

# Records each ping: the arguments and the configuration read from stdin.
FAKE_CURL = r'''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
config = sys.stdin.read()
body_file = re.search(r'data-binary = "@([^"]+)"', config).group(1)
url = re.search(r'url = "([^"]+)"', config).group(1)
with open(os.environ['FAKE_PINGS'], 'a') as handle:
    handle.write(json.dumps({'argv': sys.argv[1:], 'url': url,
                             'body': Path(body_file).read_text()}) + '\n')
'''


def runner(active='active', load='loaded', enabled='enabled', result='success', sub=''):
    sub = sub or {'active': 'running', 'inactive': 'dead', 'failed': 'failed',
                  'activating': 'auto-restart', 'deactivating': 'stop-sigterm'}.get(active, '')
    return {'LoadState': load, 'UnitFileState': enabled, 'ActiveState': active, 'SubState': sub, 'Result': result}


class Fixture:
    def __init__(self, test):
        self.tmp = tempfile.TemporaryDirectory()
        test.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / 'hold'
        self.game_file = self.root / 'game-signal' / 'active'
        self.game_file.parent.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name, text in (('systemctl', FAKE_SYSTEMCTL), ('sleep', FAKE_SLEEP), ('curl', FAKE_CURL)):
            path = self.bin / name
            path.write_text(text.replace('#!/usr/bin/env python3', f'#!{sys.executable}', 1))
            path.chmod(0o755)
        (self.root / 'steps').mkdir()
        (self.root / 'uptime').write_text('1000.00 0.00\n')
        self.ping_base = self.root / 'ping-base'
        self.ping_base.write_text('https://hc.invalid/private-ping-key\n')
        self.units = {unit: runner() for unit in RUNNERS}
        self.units[GAME_UNIT] = runner()
        self.units[RESET_UNIT] = runner('inactive')
        self.extra = {}
        self.write()

    def write(self, **extra):
        self.extra.update(extra)
        (self.root / 'units.json').write_text(json.dumps(dict(self.extra, units=self.units)))

    def read(self):
        return json.loads((self.root / 'units.json').read_text())['units']

    def step(self, sample, script):
        (self.root / 'steps' / str(sample)).write_text(script)

    def held(self, unit):
        return (self.state / 'runners' / unit / 'held').exists()

    def mark(self, unit):
        path = self.state / 'runners' / unit
        path.mkdir(parents=True, exist_ok=True)
        (path / 'held').touch()

    def calls(self, kind=None):
        log = self.root / 'systemctl.log'
        if not log.exists():
            return []
        return [line for line in log.read_text().splitlines()
                if kind is None or line.split()[0] == kind]

    def pings(self):
        path = self.root / 'pings'
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def env(self, **extra):
        env = dict(os.environ,
                   PATH=f'{self.bin}:{os.environ["PATH"]}',
                   FAKE_ROOT=str(self.root),
                   FAKE_STATE=str(self.root / 'units.json'),
                   FAKE_LOG=str(self.root / 'systemctl.log'),
                   FAKE_PINGS=str(self.root / 'pings'),
                   STATE_DIR=str(self.state),
                   SYSTEMCTL_BIN=str(self.bin / 'systemctl'),
                   CURL_BIN=str(self.bin / 'curl'),
                   SYSTEMD_NOTIFY_BIN='true',
                   UPTIME_FILE=str(self.root / 'uptime'),
                   SAMPLE_SECONDS='5',
                   RUNNER_UNITS=' '.join(RUNNERS),
                   GAME_ENABLED='1',
                   GAME_FILE=str(self.game_file),
                   GAME_UNIT=GAME_UNIT,
                   RESET_UNIT=RESET_UNIT,
                   RESET_RESTART_FILE=str(self.root / 'reset-restart'),
                   DISK_HELPER_FILE=str(DISK_HELPER),
                   DISK_SPACE_ENABLED='0',
                   DISK_DRAIN_BYTES=str(30 * GIB),
                   DISK_DRAIN_PERCENT='15',
                   DISK_RECOVERY_BYTES=str(40 * GIB),
                   DISK_RECOVERY_PERCENT='20',
                   ALERT_ENABLED='0',
                   ALERT_INTERVAL_SECONDS='300',
                   MAX_INACTIVE_SECONDS='1800',
                   PING_BASE_FILE=str(self.ping_base),
                   SLUG='ci-runners-fixture')
        env.update(extra)
        return env

    def run_hold(self, iterations, **extra):
        return subprocess.run(['bash', str(HOLD)], env=self.env(MAX_ITERATIONS=str(iterations), **extra),
                              capture_output=True, text=True, timeout=120)

    def run_gate(self, unit=POOL, **extra):
        return subprocess.run(['bash', str(GATE)], env=self.env(RUNNER_UNIT=unit, **extra),
                              capture_output=True, text=True, timeout=60)


class RunnerHoldTests(unittest.TestCase):
    def test_a_game_stops_running_runners_and_marks_only_those(self):
        fixture = Fixture(self)
        fixture.units[FAST] = runner('inactive')
        fixture.write()
        fixture.game_file.write_text('wine:Game.exe\n')
        result = fixture.run_hold(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('event=hold reason=game', result.stdout)
        self.assertEqual(fixture.calls('stop'), [f'stop {PRIMARY}', f'stop {POOL}'])
        self.assertTrue(fixture.held(PRIMARY) and fixture.held(POOL))
        # A runner someone else stopped is no runner of the hold.
        self.assertFalse(fixture.held(FAST))
        self.assertEqual(fixture.calls('start'), [])

    def test_the_end_of_a_game_starts_only_held_runners(self):
        fixture = Fixture(self)
        fixture.units[FAST] = runner('inactive')
        fixture.write()
        fixture.game_file.write_text('wine:Game.exe\n')
        fixture.step(2, f'rm {fixture.game_file}')
        result = fixture.run_hold(5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('event=release', result.stdout)
        self.assertEqual(fixture.calls('start'), [f'start {PRIMARY}', f'start {POOL}'])
        units = fixture.read()
        self.assertEqual([units[unit]['ActiveState'] for unit in RUNNERS], ['active', 'active', 'inactive'])
        self.assertFalse(fixture.held(PRIMARY) or fixture.held(POOL))
        self.assertIn(f'event=runner_start_requested runner_unit={POOL}', result.stdout)
        self.assertIn(f'event=runner_resumed runner_unit={POOL}', result.stdout)

    def test_a_stop_that_timed_out_is_reset_and_started(self):
        # 2026-10-31: a runner whose stop outlived TimeoutStopSec ended failed
        # and was never resumed.
        fixture = Fixture(self)
        fixture.write(stop_to={POOL: 'failed'})
        fixture.game_file.write_text('wine:Game.exe\n')
        fixture.step(2, f'rm {fixture.game_file}')
        result = fixture.run_hold(4)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = fixture.calls()
        self.assertIn(f'reset-failed {POOL}', calls)
        self.assertLess(calls.index(f'reset-failed {POOL}'), calls.index(f'start {POOL}'))
        self.assertEqual(fixture.read()[POOL]['ActiveState'], 'active')
        self.assertIn(f'event=runner_start_requested runner_unit={POOL} active_state=failed result=timeout',
                      result.stdout)

    def test_draining_runners_are_left_to_finish(self):
        fixture = Fixture(self)
        fixture.write(stop_to={POOL: 'deactivating'})
        fixture.game_file.write_text('wine:Game.exe\n')
        fixture.step(2, f'rm {fixture.game_file}')
        result = fixture.run_hold(4)
        self.assertEqual(result.returncode, 0, result.stderr)
        # A deactivating runner gets no second stop and no start.
        self.assertEqual(fixture.calls('stop').count(f'stop {POOL}'), 1)
        self.assertNotIn(f'start {POOL}', fixture.calls('start'))
        self.assertTrue(fixture.held(POOL))

    def test_a_disabled_or_masked_runner_drops_its_marker(self):
        for load, enabled in (('loaded', 'disabled'), ('masked', 'masked')):
            with self.subTest(enabled=enabled):
                fixture = Fixture(self)
                fixture.units[POOL] = runner('inactive', load=load, enabled=enabled)
                fixture.write()
                fixture.mark(POOL)
                result = fixture.run_hold(1)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(fixture.calls('start'), [])
                self.assertFalse(fixture.held(POOL))
                self.assertIn(f'event=runner_release_skipped runner_unit={POOL}', result.stdout)

    def test_a_marker_from_the_gate_or_a_restart_is_released(self):
        fixture = Fixture(self)
        fixture.units[POOL] = runner('inactive', result='exec-condition')
        fixture.write()
        fixture.mark(POOL)
        result = fixture.run_hold(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fixture.calls('start'), [f'start {POOL}'])
        self.assertFalse(fixture.held(POOL))

    def test_a_refused_start_is_retried_with_growing_spacing(self):
        fixture = Fixture(self)
        fixture.units[POOL] = runner('inactive')
        fixture.write(refuse=[POOL])
        fixture.mark(POOL)
        # Samples every 5 s for 60 s: starts at 0, 5, 15, 35 s.
        result = fixture.run_hold(13)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fixture.calls('start'), [f'start {POOL}'] * 4)
        self.assertTrue(fixture.held(POOL))

    def test_an_unavailable_game_signal_holds(self):
        fixture = Fixture(self)
        fixture.units[GAME_UNIT] = runner('failed')
        fixture.write()
        result = fixture.run_hold(1)
        self.assertIn('event=hold reason=game_signal_unavailable', result.stdout)
        self.assertEqual(len(fixture.calls('stop')), 3)
        # Without game holds the signal is not consulted.
        fixture = Fixture(self)
        fixture.units[GAME_UNIT] = runner('failed')
        fixture.write()
        result = fixture.run_hold(1, GAME_ENABLED='0')
        self.assertEqual(fixture.calls('stop'), [])

    def test_the_disk_floor_holds_until_space_recovers(self):
        fixture = Fixture(self)
        size = 200 * GIB
        values = [f'{size} {free * GIB}' for free in (100, 20, 35, 35, 100, 100)]
        (fixture.root / 'disk').write_text('\n'.join(values) + '\n')
        result = fixture.run_hold(6, GAME_ENABLED='0', DISK_SPACE_ENABLED='1',
                                  DISK_SPACE_VALUES_FILE=str(fixture.root / 'disk'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('event=hold reason=disk_space', result.stdout)
        # Between the floors the hold stays; recovery releases it.
        self.assertEqual(result.stdout.count('event=hold'), 1)
        self.assertIn('event=release', result.stdout)
        self.assertEqual(len(fixture.calls('stop')), 3)
        self.assertEqual(len(fixture.calls('start')), 3)

    def test_a_disk_hold_survives_a_restart_between_the_floors(self):
        fixture = Fixture(self)
        (fixture.root / 'disk').write_text(f'{200 * GIB} {35 * GIB}\n')
        fixture.state.mkdir(mode=0o700)
        (fixture.state / 'disk-held').touch()
        result = fixture.run_hold(1, GAME_ENABLED='0', DISK_SPACE_ENABLED='1',
                                  DISK_SPACE_VALUES_FILE=str(fixture.root / 'disk'))
        self.assertIn('event=hold reason=disk_space', result.stdout)
        (fixture.root / 'disk').write_text(f'{200 * GIB} {100 * GIB}\n')
        result = fixture.run_hold(1, GAME_ENABLED='0', DISK_SPACE_ENABLED='1',
                                  DISK_SPACE_VALUES_FILE=str(fixture.root / 'disk'))
        self.assertNotIn('event=hold', result.stdout)
        self.assertFalse((fixture.state / 'disk-held').exists())

    def test_space_between_the_floors_alone_holds_nothing(self):
        fixture = Fixture(self)
        (fixture.root / 'disk').write_text(f'{200 * GIB} {35 * GIB}\n')
        result = fixture.run_hold(1, GAME_ENABLED='0', DISK_SPACE_ENABLED='1',
                                  DISK_SPACE_VALUES_FILE=str(fixture.root / 'disk'))
        self.assertNotIn('event=hold', result.stdout)
        self.assertEqual(fixture.calls('stop'), [])

    def test_invalid_settings_are_rejected(self):
        for extra in ({'RUNNER_UNITS': ''}, {'RUNNER_UNITS': 'bad;unit'}, {'GAME_ENABLED': '2'},
                      {'SAMPLE_SECONDS': 'x'}, {'ALERT_ENABLED': '1', 'SLUG': 'Bad Slug'}):
            with self.subTest(extra=extra):
                fixture = Fixture(self)
                self.assertEqual(fixture.run_hold(1, **extra).returncode, 1)
                self.assertEqual(fixture.calls('stop') + fixture.calls('start'), [])


class AlertTests(unittest.TestCase):
    def test_a_runner_left_off_fails_the_ping_after_the_bound(self):
        fixture = Fixture(self)
        fixture.units[FAST] = runner('failed', result='exit-code')
        fixture.write()
        # One check every 300 s of fake time, for 40 minutes.
        result = fixture.run_hold(9, ALERT_ENABLED='1', FAKE_STEP='300')
        self.assertEqual(result.returncode, 0, result.stderr)
        pings = fixture.pings()
        self.assertEqual(len(pings), 9)
        self.assertTrue(all(ping['url'].endswith('/ci-runners-fixture?create=1') for ping in pings[:6]))
        self.assertTrue(pings[-1]['url'].endswith('/ci-runners-fixture/fail?create=1'))
        self.assertIn(f'{FAST}: failed (exit-code) for 30m, no hold reason or marker', pings[6]['body'])
        self.assertIn(f'event=runner_left_off runner_unit={FAST}', result.stdout)
        # The private ping base reaches curl only through its stdin.
        for ping in pings:
            self.assertNotIn('private-ping-key', ' '.join(ping['argv']))
            self.assertIn('private-ping-key', ping['url'])

    def test_held_and_reset_runners_are_intended(self):
        fixture = Fixture(self)
        fixture.units[POOL] = runner('deactivating')
        fixture.units[FAST] = runner('inactive')
        fixture.units[RESET_UNIT] = runner('activating')
        fixture.write()
        fixture.mark(POOL)
        (fixture.root / 'reset-restart').write_text(f'{FAST}\n')
        result = fixture.run_hold(9, ALERT_ENABLED='1', FAKE_STEP='300')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all('/fail' not in ping['url'] for ping in fixture.pings()))
        # A game hold is intended too.
        fixture = Fixture(self)
        fixture.game_file.write_text('stream:47998\n')
        result = fixture.run_hold(9, ALERT_ENABLED='1', FAKE_STEP='300')
        self.assertTrue(all('/fail' not in ping['url'] for ping in fixture.pings()))

    def test_a_marked_runner_that_keeps_failing_is_reported(self):
        fixture = Fixture(self)
        fixture.units[POOL] = runner('failed', result='exit-code')
        # Its start fails again each time.
        fixture.write(fail_start=[POOL])
        fixture.mark(POOL)
        result = fixture.run_hold(9, ALERT_ENABLED='1', FAKE_STEP='300')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(len(fixture.calls('start')), 1)
        self.assertTrue(fixture.pings()[-1]['url'].endswith('/fail?create=1'))

    def test_a_crash_looping_runner_is_reported(self):
        # Restart=on-failure keeps a runner whose start fails in activating;
        # systemd owns its restarts, so its marker goes.
        fixture = Fixture(self)
        fixture.units[POOL] = runner('activating')
        fixture.write()
        fixture.mark(POOL)
        result = fixture.run_hold(9, ALERT_ENABLED='1', FAKE_STEP='300')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(fixture.held(POOL))
        self.assertTrue(fixture.pings()[-1]['url'].endswith('/fail?create=1'))

    def test_a_marked_runner_whose_start_never_happens_is_reported(self):
        # A start that fails before the runner runs, such as a failing
        # engine it requires, leaves it inactive with its marker.
        fixture = Fixture(self)
        fixture.units[POOL] = runner('inactive', result='success')
        fixture.write(refuse=[POOL])
        fixture.mark(POOL)
        result = fixture.run_hold(9, ALERT_ENABLED='1', FAKE_STEP='300')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(fixture.held(POOL))
        self.assertTrue(fixture.pings()[-1]['url'].endswith('/fail?create=1'))
        self.assertIn('its start after the hold has not succeeded', fixture.pings()[-1]['body'])

    def test_a_start_in_its_gate_keeps_its_marker(self):
        fixture = Fixture(self)
        fixture.units[POOL] = runner('activating', sub='condition')
        fixture.write()
        fixture.mark(POOL)
        fixture.run_hold(2)
        self.assertTrue(fixture.held(POOL))
        self.assertEqual(fixture.calls('start'), [])

    def test_a_marked_runner_still_draining_is_intended(self):
        fixture = Fixture(self)
        fixture.units[POOL] = runner('deactivating')
        fixture.write()
        fixture.mark(POOL)
        result = fixture.run_hold(9, ALERT_ENABLED='1', FAKE_STEP='300')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all('/fail' not in ping['url'] for ping in fixture.pings()))

    def test_no_ping_without_alerting(self):
        fixture = Fixture(self)
        fixture.units[FAST] = runner('failed')
        fixture.write()
        result = fixture.run_hold(9, FAKE_STEP='300')
        self.assertEqual(fixture.pings(), [])
        self.assertIn('event=runner_left_off', result.stdout)


class GateTests(unittest.TestCase):
    def test_a_clear_host_admits_the_start(self):
        fixture = Fixture(self)
        result = fixture.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(fixture.held(POOL))
        self.assertEqual(oct(fixture.state.stat().st_mode & 0o777), '0o700')

    def test_hold_reasons_refuse_and_mark(self):
        cases = {
            'game': lambda f: f.game_file.write_text('wine:Game.exe\n'),
            'game_signal_unavailable': lambda f: (f.units.update({GAME_UNIT: runner('inactive')}), f.write()),
        }
        for reason, arrange in cases.items():
            with self.subTest(reason=reason):
                fixture = Fixture(self)
                arrange(fixture)
                result = fixture.run_gate()
                self.assertEqual(result.returncode, 1)
                self.assertIn(f'runner start held: {reason}', result.stdout)
                self.assertTrue(fixture.held(POOL))
                self.assertFalse(fixture.held(PRIMARY))

    def test_a_gate_below_the_floor_starts_the_disk_hold(self):
        fixture = Fixture(self)
        (fixture.root / 'disk').write_text(f'{200 * GIB} {20 * GIB}\n')
        self.assertEqual(fixture.run_gate(DISK_SPACE_ENABLED='1', DISK_SPACE_VALUES_FILE=str(fixture.root / 'disk')).returncode, 1)
        self.assertTrue((fixture.state / 'disk-held').exists())

    def test_the_disk_floor_refuses_and_space_between_the_floors_admits(self):
        for free, code in ((20, 1), (35, 0), (100, 0)):
            with self.subTest(free=free):
                fixture = Fixture(self)
                (fixture.root / 'disk').write_text(f'{200 * GIB} {free * GIB}\n')
                result = fixture.run_gate(DISK_SPACE_ENABLED='1', DISK_SPACE_VALUES_FILE=str(fixture.root / 'disk'))
                self.assertEqual(result.returncode, code)
                self.assertEqual(fixture.held(POOL), code == 1)
        # Between the floors a disk hold in force continues.
        fixture = Fixture(self)
        fixture.state.mkdir(mode=0o700)
        (fixture.state / 'disk-held').touch()
        (fixture.root / 'disk').write_text(f'{200 * GIB} {35 * GIB}\n')
        result = fixture.run_gate(DISK_SPACE_ENABLED='1', DISK_SPACE_VALUES_FILE=str(fixture.root / 'disk'))
        self.assertEqual(result.returncode, 1)
        self.assertTrue(fixture.held(POOL))
        fixture = Fixture(self)
        (fixture.root / 'disk').write_text('garbage\n')
        result = fixture.run_gate(DISK_SPACE_ENABLED='1', DISK_SPACE_VALUES_FILE=str(fixture.root / 'disk'))
        self.assertEqual(result.returncode, 1)

    def test_a_held_lock_skips_without_a_marker(self):
        fixture = Fixture(self)
        fixture.state.mkdir(mode=0o700)
        lock = fixture.state / 'start.lock'
        holder = subprocess.Popen(['flock', '-x', str(lock), 'sleep', '10'])
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        subprocess.run(['sh', '-c', f'until ! flock -n {lock} true; do :; done'], timeout=10)
        result = fixture.run_gate(GATE_TIMEOUT_SECONDS='1')
        self.assertEqual(result.returncode, 1)
        self.assertFalse(fixture.held(POOL))

    def test_invalid_input_skips(self):
        for extra in ({'unit': 'bad;unit'}, {'GAME_ENABLED': 'x'}, {'GATE_TIMEOUT_SECONDS': '0'}):
            with self.subTest(extra=extra):
                fixture = Fixture(self)
                self.assertEqual(fixture.run_gate(**extra).returncode, 1)


class GameSignalTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture(self)
        root = self.fixture.root
        self.signal = root / 'signal' / 'active'
        self.proc = root / 'proc'
        (self.proc / '123').mkdir(parents=True)
        preloader = root / 'wine64-preloader'
        preloader.touch()
        (self.proc / '123' / 'exe').symlink_to(preloader)
        (self.proc / '123' / 'cmdline').write_bytes(b'C:\\Games\\Game.exe\0--token=ignored\0')
        # pgrep answers from files: the PIDs of the user, and the names that run.
        self.pgrep = root / 'bin' / 'pgrep'
        self.pgrep.write_text('#!' + shutil.which('bash') + '\n' + f'''set -eu
if [[ $# == 2 ]]; then
  [[ -s {root}/pids ]] || exit "$(cat {root}/pids-status 2>/dev/null || echo 1)"
  cat {root}/pids
  exit 0
fi
[[ $3 == -x ]] && grep -qx "$4" {root}/names 2>/dev/null
''')
        self.pgrep.chmod(0o755)
        (root / 'names').write_text('')
        (root / 'pids').write_text('')
        self.ss = root / 'bin' / 'ss'
        self.ss.write_text('#!/bin/sh\ncat ' + str(root / 'sockets') + ' 2>/dev/null || true\n')
        self.ss.chmod(0o755)

    def run_signal(self, iterations, **extra):
        env = self.fixture.env(
            MAX_ITERATIONS=str(iterations),
            SIGNAL_FILE=str(self.signal),
            COOLDOWN_SECONDS='60',
            UNCERTAIN_SAMPLES='3',
            GAME_SCAN_FILE=str(GAME_SCAN),
            GAME_PROC_ROOT=str(self.proc),
            PGREP_BIN=str(self.pgrep),
            SS_BIN=str(self.ss),
            GAME_USER='player',
            GAME_WINE_ARGV0_BASENAMES='Game.exe',
            GAME_PROCESS_NAMES='reaper',
            GAME_STREAM_UDP_PORTS='47998')
        env.update(extra)
        return subprocess.run(['bash', str(SIGNAL)], env=env, capture_output=True, text=True, timeout=120)

    def test_each_kind_of_game_publishes_the_signal(self):
        cases = {
            'wine:Game.exe': lambda root: (root / 'pids').write_text('123\n'),
            'process:reaper': lambda root: (root / 'names').write_text('reaper\n'),
            'stream:47998': lambda root: (root / 'sockets').write_text('UNCONN 0 0 0.0.0.0:47998 0.0.0.0:*\n'),
        }
        for reason, arrange in cases.items():
            with self.subTest(reason=reason):
                self.setUp()
                arrange(self.fixture.root)
                result = self.run_signal(1)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.signal.read_text(), reason + '\n')
                self.assertEqual(oct(self.signal.stat().st_mode & 0o777), '0o644')
                self.assertIn(f'event=game_started reason={reason}', result.stdout)

    def test_a_stream_counts_without_a_user(self):
        (self.fixture.root / 'sockets').write_text('UNCONN 0 0 0.0.0.0:47998 0.0.0.0:*\n')
        self.run_signal(1, GAME_USER='')
        self.assertTrue(self.signal.exists())

    def test_other_wine_programs_and_arguments_are_no_game(self):
        (self.proc / '123' / 'cmdline').write_bytes(b'C:\\Battle.net\\Battle.net.exe\0Game.exe\0')
        (self.fixture.root / 'pids').write_text('123\n')
        self.run_signal(1)
        self.assertFalse(self.signal.exists())

    def test_the_signal_stays_for_the_cooldown(self):
        root = self.fixture.root
        (root / 'pids').write_text('123\n')
        self.fixture.step(1, f': > {root}/pids')
        # Seen at 1000 s, gone from 1005 s; the cooldown ends at 1060 s.
        result = self.run_signal(12)
        self.assertTrue(self.signal.exists())
        self.assertNotIn('game_ended', result.stdout)
        self.fixture.step(12, ':')
        (root / 'samples').unlink()
        (root / 'uptime').write_text('1060.00 0.00\n')
        result = self.run_signal(1)
        # A restart keeps an existing signal for a cooldown from its start.
        self.assertTrue(self.signal.exists())
        result = self.run_signal(13)
        self.assertFalse(self.signal.exists())
        self.assertIn('event=game_ended', result.stdout)

    def test_uncertain_scans_count_only_in_a_row(self):
        root = self.fixture.root
        (root / 'pids').write_text('77\n')
        # A PID whose executable link cannot be read and that has not exited.
        (self.proc / '77').mkdir()
        (self.proc / '77' / 'stat').write_text('77 (game) R 1\n')
        self.fixture.step(1, f': > {root}/pids')
        self.fixture.step(2, f'echo 77 > {root}/pids')
        self.fixture.step(3, f': > {root}/pids')
        self.run_signal(4)
        self.assertFalse(self.signal.exists())
        (root / 'samples').unlink()
        for sample in (1, 2, 3):
            (root / 'steps' / str(sample)).unlink()
        (root / 'pids').write_text('77\n')
        result = self.run_signal(3)
        self.assertTrue(self.signal.exists())
        self.assertIn('reason=uncertain:scan_error samples=3', result.stdout)

    def test_a_process_that_exits_mid_scan_is_no_uncertainty(self):
        root = self.fixture.root
        (root / 'pids').write_text('88\n')
        (self.proc / '88').mkdir()
        (self.proc / '88' / 'stat').write_text('88 (old) Z 1\n')
        self.run_signal(5)
        self.assertFalse(self.signal.exists())


if __name__ == '__main__':
    unittest.main()
