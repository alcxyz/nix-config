#!/usr/bin/env python3
"""Standby controller tests with mock systemctl and curl; no network."""
import fcntl
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

CONTROLLER = Path(sys.argv.pop(1)).resolve()
UNIT = 'forgejo-podman-runner-fast.service'


class StandbyControllerTests(unittest.TestCase):
    def run_controller(self, answers, active='inactive', result='exec-condition',
                       admitted=False, markers=(), runner_dir=True, stop_fails=False,
                       hold_lock=False, env=None, other_drain=False, down_dependency='',
                       unit_file_state='enabled', load_state='loaded', terminate=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state'
            runner_state = state / 'runners' / UNIT
            state.mkdir()
            if runner_dir:
                runner_state.mkdir(parents=True)
            if admitted:
                (runner_state / 'standby-admitted').touch()
            for marker in markers:
                (runner_state / marker).touch()
            if other_drain:
                (state / 'runners' / 'forgejo-podman-runner.service').mkdir(parents=True)
                (state / 'runners' / 'forgejo-podman-runner.service' / 'drain-owned').write_text('123\n')
            (root / 'answers').write_text(''.join(answer + '\n' for answer in answers))
            (root / 'active').write_text(active + '\n')
            (root / 'result').write_text(result + '\n')
            (root / 'unit-file-state').write_text(unit_file_state + '\n')
            (root / 'load-state').write_text(load_state + '\n')
            curl = root / 'curl'
            curl.write_text('#!' + shutil.which('bash') + '''
set -eu
printf '%s\\n' "$*" >> "$MOCK_ROOT/curl-calls"
answers=$MOCK_ROOT/answers
answer=$(head -n 1 "$answers")
tail -n +2 "$answers" > "$answers.next"
mv "$answers.next" "$answers"
[[ ${!#} == http://192.0.2.10:9478/ ]] || exit 9
case "$answer" in
  unreachable) exit 7 ;;
  *) printf '%s\\n' "$answer" ;;
esac
''')
            systemctl = root / 'systemctl'
            systemctl.write_text('#!' + shutil.which('bash') + '''
set -eu
printf '%s\\n' "$*" >> "$MOCK_ROOT/calls"
if [[ $1 == is-active && $2 == --quiet ]]; then
  [[ $3 != "$MOCK_DOWN_DEPENDENCY" ]]
elif [[ $1 == show && $2 == --property=ActiveState && $3 == --value && $4 == ''' + UNIT + ''' ]]; then
  cat "$MOCK_ROOT/active"
elif [[ $1 == show && $2 == --property=Result && $3 == --value && $4 == ''' + UNIT + ''' ]]; then
  cat "$MOCK_ROOT/result"
elif [[ $1 == show && $2 == --property=UnitFileState && $3 == --value && $4 == ''' + UNIT + ''' ]]; then
  cat "$MOCK_ROOT/unit-file-state"
elif [[ $1 == show && $2 == --property=LoadState && $3 == --value && $4 == ''' + UNIT + ''' ]]; then
  cat "$MOCK_ROOT/load-state"
elif [[ $1 == --no-block && $2 == --job-mode=ignore-requirements && $3 == start && $4 == ''' + UNIT + ''' ]]; then
  # The start gate refuses again without a hold marker.
  :
elif [[ $1 == --no-block && $2 == stop && $3 == ''' + UNIT + ''' ]]; then
  [[ $MOCK_STOP_FAILS == 0 ]] || exit 1
  printf 'deactivating\\n' > "$MOCK_ROOT/active"
else
  exit 2
fi
''')
            curl.chmod(0o755)
            systemctl.chmod(0o755)
            environment = {
                'PATH': '/run/current-system/sw/bin:/usr/bin:/bin',
                'MOCK_ROOT': str(root), 'MOCK_STOP_FAILS': '1' if stop_fails else '0',
                'MOCK_DOWN_DEPENDENCY': down_dependency,
                'STATE_DIR': str(state), 'SYSTEMCTL_BIN': str(systemctl),
                'CURL_BIN': str(curl), 'RUNNER_UNIT': UNIT,
                'STATUS_URL': 'http://192.0.2.10:9478/', 'POLL_SECONDS': '0',
                'START_AFTER_POLLS': '2', 'STOP_AFTER_POLLS': '3',
                'START_RETRY_POLLS': '2', 'LOCK_SECONDS': '1',
                'MAX_ITERATIONS': '0' if terminate else str(len(answers)),
            }
            if terminate:
                environment['POLL_SECONDS'] = '30'
            environment['PATH'] = ':'.join(
                str(Path(shutil.which(tool)).parent)
                for tool in ('bash', 'flock', 'timeout', 'head')) + ':' + environment['PATH']
            environment.update(env or {})
            lock = None
            if hold_lock:
                lock = (state / 'lifecycle.lock').open('w')
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                if terminate:
                    child = subprocess.Popen(['bash', str(CONTROLLER)], env=environment,
                                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                             text=True)
                    deadline = time.monotonic() + 10
                    while not (root / 'curl-calls').exists() and time.monotonic() < deadline:
                        time.sleep(0.05)
                    time.sleep(0.3)
                    child.terminate()
                    stdout, stderr = child.communicate(timeout=10)
                    process = subprocess.CompletedProcess(child.args, child.returncode,
                                                          stdout, stderr)
                else:
                    process = subprocess.run(['bash', str(CONTROLLER)], env=environment,
                                             capture_output=True, text=True, timeout=30)
            finally:
                if lock is not None:
                    lock.close()
            calls = (root / 'calls').read_text().splitlines() if (root / 'calls').exists() else []
            self.events = [line.split()[0] for line in process.stdout.splitlines()]
            curl_calls = root / 'curl-calls'
            self.curl_calls = curl_calls.read_text().splitlines() if curl_calls.exists() else []
            self.admitted = (runner_state / 'standby-admitted').exists()
            self.held = (runner_state / 'standby-held').exists()
            # A start must never pull in a stopped dependency.
            self.starts = calls.count(f'--no-block --job-mode=ignore-requirements start {UNIT}')
            self.assertFalse(any(' start ' in f' {call} ' and 'ignore-requirements' not in call
                                 for call in calls))
            self.stops = calls.count(f'--no-block stop {UNIT}')
            return process.returncode

    def test_primary_up_keeps_standby_idle(self):
        self.assertEqual(self.run_controller(['active'] * 5), 0)
        self.assertFalse(self.admitted)
        self.assertEqual((self.starts, self.stops), (0, 0))
        self.assertEqual(self.events, ['event=primary_up'])

    def test_short_outage_does_not_admit(self):
        self.assertEqual(self.run_controller(['unreachable', 'active', 'unreachable', 'active']), 0)
        self.assertFalse(self.admitted)
        self.assertEqual(self.starts, 0)

    def test_sustained_outage_admits_and_starts_once_per_retry_interval(self):
        self.assertEqual(self.run_controller(['unreachable'] * 5), 0)
        self.assertTrue(self.admitted)
        # Admitted at poll 2 with a start, then retried at poll 4.
        self.assertEqual(self.starts, 2)
        self.assertIn('event=standby_admitted', self.events)

    def test_any_answer_but_active_counts_as_down(self):
        for answer in ('inactive', 'deactivating', 'unknown', ''):
            with self.subTest(answer=answer):
                self.run_controller([answer] * 2)
                self.assertTrue(self.admitted)
                self.assertEqual(self.starts, 1)

    def test_guard_holds_are_left_to_the_guard(self):
        for marker in ('drain-owned', 'drain-pending', 'resume-pending', 'resume-queued',
                       'drain-disowned', 'game-start-skipped', 'disk-start-skipped'):
            with self.subTest(marker=marker):
                self.run_controller(['unreachable'] * 4, admitted=True, markers=[marker])
                self.assertTrue(self.admitted)
                self.assertEqual(self.starts, 0)

    def test_drain_of_another_runner_holds_the_standby(self):
        self.run_controller(['unreachable'] * 4, admitted=True, other_drain=True)
        self.assertTrue(self.admitted)
        self.assertEqual(self.starts, 0)

    def test_stopped_dependency_is_not_restarted_through_the_runner(self):
        for unit in ('forgejo-runner-io-pressure-guard.service',
                     'forgejo-runner-aggregate-lifecycle.service',
                     'forgejo-runner-podman.service'):
            with self.subTest(unit=unit):
                self.run_controller(['unreachable'] * 4, admitted=True, down_dependency=unit)
                self.assertEqual(self.starts, 0)

    def test_disabled_or_masked_runner_is_left_alone(self):
        for kwargs in ({'unit_file_state': 'disabled'}, {'unit_file_state': 'masked'},
                       {'load_state': 'masked'}):
            with self.subTest(**kwargs):
                self.run_controller(['unreachable'] * 4, admitted=True, **kwargs)
                self.assertEqual(self.starts, 0)
        self.run_controller(['unreachable'] * 2, admitted=True, unit_file_state='enabled-runtime')
        self.assertEqual(self.starts, 1)

    def test_running_or_failed_runner_is_not_started(self):
        self.run_controller(['unreachable'] * 3, admitted=True, active='active', result='success')
        self.assertEqual(self.starts, 0)
        self.run_controller(['unreachable'] * 3, admitted=True, active='failed', result='exit-code')
        self.assertEqual(self.starts, 0)
        self.assertEqual(self.events.count('event=standby_start_blocked'), 1)
        self.run_controller(['unreachable'] * 3, admitted=True, active='inactive', result='timeout')
        self.assertEqual(self.starts, 0)

    def test_released_runner_restarts_after_clean_stop(self):
        self.run_controller(['unreachable'] * 2, admitted=True, result='success')
        self.assertEqual(self.starts, 1)

    def test_recovered_primary_releases_and_stops_gracefully(self):
        self.run_controller(['active'] * 3, admitted=True, active='active', result='success')
        self.assertFalse(self.admitted)
        self.assertTrue(self.held)
        self.assertEqual(self.stops, 1)
        self.assertIn('event=standby_released', self.events)

    def test_release_of_stopped_runner_sends_no_stop(self):
        self.run_controller(['active'] * 3, admitted=True)
        self.assertFalse(self.admitted)
        self.assertEqual(self.stops, 0)

    def test_short_recovery_keeps_standby_running(self):
        self.run_controller(['active', 'active', 'unreachable', 'active', 'active'],
                            admitted=True, active='active', result='success')
        self.assertTrue(self.admitted)
        self.assertEqual(self.stops, 0)

    def test_failed_stop_is_retried_without_admission(self):
        self.run_controller(['active'] * 5, admitted=True, active='active',
                            result='success', stop_fails=True)
        self.assertFalse(self.admitted)
        self.assertEqual(self.stops, 3)
        self.assertIn('event=standby_release_unconfirmed', self.events)

    def test_missing_guard_state_is_left_alone(self):
        self.run_controller(['unreachable'] * 3, runner_dir=False)
        self.assertFalse(self.admitted)
        self.assertEqual(self.starts, 0)

    def test_lock_timeout_withholds_admission(self):
        self.run_controller(['unreachable'] * 2, hold_lock=True)
        self.assertFalse(self.admitted)
        self.assertEqual(self.starts, 0)
        self.assertIn('event=standby_lock_timeout', self.events)

    def test_stopping_the_controller_releases_the_runner(self):
        self.assertEqual(self.run_controller(['unreachable'] * 3, admitted=True, active='active',
                                             result='success', terminate=True), 0)
        self.assertFalse(self.admitted)
        self.assertTrue(self.held)
        self.assertEqual(self.stops, 1)
        self.assertIn('event=standby_released', self.events)

    def test_stopping_with_a_busy_lock_still_withdraws_and_stops(self):
        self.assertEqual(self.run_controller(['unreachable'] * 3, admitted=True, active='active',
                                             result='success', terminate=True,
                                             hold_lock=True), 0)
        self.assertFalse(self.admitted)
        self.assertTrue(self.held)
        self.assertEqual(self.stops, 1)

    def test_polls_leave_through_the_configured_interface(self):
        self.run_controller(['active'], env={'STATUS_INTERFACE': 'wt0'})
        self.assertIn('--interface if!wt0', self.curl_calls[0])
        self.run_controller(['active'])
        self.assertNotIn('--interface', self.curl_calls[0])

    def test_invalid_settings_fail(self):
        for name, value in (('POLL_SECONDS', 'x'), ('START_AFTER_POLLS', '0'),
                            ('RUNNER_UNIT', 'bad unit'), ('DEPENDENCY_UNITS', 'bad unit'),
                            ('STATUS_INTERFACE', 'wt0 x')):
            with self.subTest(name=name):
                self.assertEqual(self.run_controller(['active'], env={name: value}), 1)


if __name__ == '__main__':
    unittest.main()
