#!/usr/bin/env python3
"""Synthetic freeze ownership tests; never contact systemd or Docker."""
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest

GUARD = Path(sys.argv.pop(1)).resolve()


class GuardTests(unittest.TestCase):
    def run_guard(self, values, initial='running', owned=False, pending=False,
                  fail_action='', fail_count='0', fail_state='', action_delay='0',
                  transition_timeout='120'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state'
            state.mkdir()
            if owned:
                (state / 'owned').touch()
            if pending:
                (state / 'pending').touch()
            (root / 'actual').write_text(initial)
            (root / 'pressure').write_text('\n'.join(map(str, values)) + '\n')
            mock = root / 'systemctl'
            mock.write_text('#!' + shutil.which('bash') + '\n' + '''set -eu
if [[ $1 == show ]]; then
  [[ "$*" == "show --property=FreezerState --value forgejobuilds.slice" ]]
  cat "$FIXTURE/actual"; exit
fi
[[ $# == 2 && $2 == forgejobuilds.slice ]]
[[ ${SYSTEMD_BUS_TIMEOUT:-} =~ ^[1-9][0-9]*s$ ]]
[[ ${SYSTEMD_BUS_TIMEOUT%s} -le $TRANSITION_TIMEOUT_SECONDS ]]
printf '%s\\n' "$1" >> "$FIXTURE/actions"
attempt=$(wc -l < "$FIXTURE/actions")
if [[ $1 == "$FAIL_ACTION" && $attempt -le $FAIL_COUNT ]]; then
  [[ -z $FAIL_STATE ]] || printf '%s' "$FAIL_STATE" > "$FIXTURE/actual"
  exit 1
fi
if [[ $1 == freeze && $ACTION_DELAY != 0 ]]; then sleep "$ACTION_DELAY"; fi
case "$1" in
  freeze) printf frozen > "$FIXTURE/actual" ;;
  thaw) printf running > "$FIXTURE/actual" ;;
  *) exit 2 ;;
esac
''')
            mock.chmod(0o755)
            env = {**os.environ, 'FIXTURE': str(root),
                   'STATE_DIR': str(state), 'SYSTEMCTL_BIN': str(mock),
                   'SYSTEMD_NOTIFY_BIN': 'true', 'LOGGER_BIN': 'true',
                   'PRESSURE_VALUES_FILE': str(root / 'pressure'),
                   'SAMPLE_SECONDS': '0', 'HIGH_SAMPLES_REQUIRED': '2',
                   'LOW_SAMPLES_REQUIRED': '2', 'MAX_ITERATIONS': str(len(values)),
                   'FAIL_ACTION': fail_action, 'FAIL_COUNT': fail_count,
                   'FAIL_STATE': fail_state, 'ACTION_DELAY': action_delay,
                   'TRANSITION_TIMEOUT_SECONDS': transition_timeout}
            result = subprocess.run(['bash', str(GUARD)], env=env, capture_output=True)
            actions = (root / 'actions').read_text().splitlines() if (root / 'actions').exists() else []
            return result.returncode, actions, (state / 'owned').exists(), (state / 'pending').exists()

    def test_hysteresis_freezes_and_thaws_aggregate(self):
        self.assertEqual(self.run_guard([2500, 2500, 1000, 0, 0]), (0, ['freeze', 'thaw'], False, False))

    def test_short_pressure_does_not_freeze(self):
        self.assertEqual(self.run_guard([2500, 0, 0]), (0, [], False, False))

    def test_manual_freeze_is_never_thawed(self):
        self.assertEqual(self.run_guard([0, 0], initial='frozen'), (1, [], False, False))

    def test_owned_freeze_survives_restart(self):
        self.assertEqual(self.run_guard([0, 0], initial='frozen', owned=True), (0, ['thaw'], False, False))

    def test_ambiguous_freeze_never_thaws(self):
        self.assertEqual(self.run_guard([0, 0], initial='frozen', pending=True), (1, [], False, True))

    def test_failed_freeze_retains_pending(self):
        self.assertEqual(self.run_guard([2500, 2500], fail_action='freeze', fail_count='1',
                                        fail_state='freezing'), (1, ['freeze'], False, True))

    def test_aborted_freeze_retries_within_original_deadline(self):
        self.assertEqual(self.run_guard([2500, 2500], fail_action='freeze', fail_count='1'),
                         (0, ['freeze', 'freeze'], True, False))

    def test_freeze_retry_exhausts_original_deadline(self):
        result, actions, owned, pending = self.run_guard(
            [2500, 2500], fail_action='freeze', fail_count='99', transition_timeout='2')
        self.assertEqual(result, 1)
        self.assertGreaterEqual(len(actions), 1)
        self.assertTrue(all(action == 'freeze' for action in actions))
        self.assertFalse(owned)
        self.assertTrue(pending)

    def test_freeze_can_exceed_metadata_timeout(self):
        self.assertEqual(self.run_guard([2500, 2500], action_delay='6', transition_timeout='10'),
                         (0, ['freeze'], True, False))

    def test_failed_thaw_retains_ownership(self):
        self.assertEqual(self.run_guard([0, 0], initial='frozen', owned=True, fail_action='thaw',
                                        fail_count='1'),
                         (1, ['thaw'], True, True))

    def test_external_thaw_requires_recovery(self):
        self.assertEqual(self.run_guard([0], owned=True), (1, [], True, False))

    def test_lost_pressure_freezes_before_stopping(self):
        self.assertEqual(self.run_guard([0, 'invalid']), (1, ['freeze'], True, False))

    def test_unreadable_startup_does_not_claim_ownership(self):
        self.assertEqual(self.run_guard(['invalid']), (1, [], False, False))


if __name__ == '__main__':
    unittest.main()
