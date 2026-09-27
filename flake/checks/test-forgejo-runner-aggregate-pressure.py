#!/usr/bin/env python3
"""Synthetic freeze ownership tests; never contact systemd or Docker."""
import os
import fcntl
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import time
import unittest

GUARD = Path(sys.argv.pop(1)).resolve()
LIFECYCLE = (Path(sys.argv.pop(1)) if len(sys.argv) > 1 else
             GUARD.with_name('aggregate-lifecycle-stop.sh')).resolve()
GATE = (Path(sys.argv.pop(1)) if len(sys.argv) > 1 else
        GUARD.with_name('runner-start-gate.sh')).resolve()
GAME_BYPASS_CONTROL = Path(os.environ.get(
    'GAME_BYPASS_CONTROL_FILE', GUARD.with_name('game-bypass-control.sh')))
PRIMARY = 'forgejo-actions-runner.service'
SECOND = 'forgejo-podman-actions-runner.service'


class GuardTests(unittest.TestCase):
    def run_guard(self, values, initial='running', owned=False, pending=False,
                  fail_action='', fail_count='0', fail_state='', action_delay='0',
                  transition_timeout='120', admission=False, drain_owned=False,
                  drain_pending=False, resume_pending=False, runner_state='active',
                  runner_enabled='enabled', runner_load='loaded', runner_result='success',
                  stop_state='inactive', fail_runner_action='', runner_generation='123',
                  drain_generation=None, stop_generation='0', lifecycle_active=True,
                  teardown_required=False, show_fail_count='0', second_runner=None,
                  second_marker='', runner_units=None, persisted_units=None,
                  unknown_state=False, game_states=None, game_times=None,
                  game_start_skipped=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state'
            state.mkdir()
            if owned:
                (state / 'owned').touch()
            if pending:
                (state / 'pending').touch()
            if drain_owned:
                (state / 'drain-owned').write_text(
                    (drain_generation or runner_generation) + '\n')
            if drain_pending:
                (state / 'drain-pending').touch()
            if resume_pending:
                (state / 'resume-pending').touch()
            if game_start_skipped:
                (state / 'game-start-skipped').touch()
            if teardown_required:
                (state / 'teardown-required').touch()
            if persisted_units is not None:
                (state / 'runner-units').write_text('\n'.join(persisted_units) + '\n')
            if unknown_state:
                (state / 'runners' / 'old-runner.service').mkdir(parents=True)
            if second_runner is not None:
                second_state = state / 'runners' / SECOND
                second_state.mkdir(parents=True)
                if second_marker:
                    (second_state / second_marker).write_text(
                        second_runner.get('drain_generation', '456') + '\n')
                for property_name, value in {
                    'active': 'active', 'enabled': 'enabled', 'load': 'loaded',
                    'result': 'success', 'generation': '456'
                }.items():
                    (root / f'podman-runner-{property_name}').write_text(
                        second_runner.get(property_name, value))
            (root / 'actual').write_text(initial)
            (root / 'runner-active').write_text(runner_state)
            (root / 'runner-enabled').write_text(runner_enabled)
            (root / 'runner-load').write_text(runner_load)
            (root / 'runner-result').write_text(runner_result)
            (root / 'runner-generation').write_text(runner_generation)
            (root / 'pressure').write_text('\n'.join(map(str, values)) + '\n')
            (root / 'game-states').write_text('\n'.join(game_states or []) + '\n')
            (root / 'game-times').write_text('\n'.join(map(str, game_times or [])) + '\n')
            (root / 'proc' / '123').mkdir(parents=True)
            (root / 'wine64-preloader').touch()
            (root / 'proc' / '123' / 'exe').symlink_to(root / 'wine64-preloader')
            (root / 'proc' / '123' / 'cmdline').write_bytes(b'C:\\Games\\HeroesOfTheStorm_x64.exe\0ignored-secret\0')
            pgrep = root / 'pgrep'
            pgrep.write_text('#!' + shutil.which('bash') + '\n' + '''set -eu
[[ $1 == -u && $2 == alc && $# == 2 ]]
count=0
[[ ! -e $FIXTURE/scan-count ]] || count=$(cat "$FIXTURE/scan-count")
count=$((count + 1))
printf '%s' "$count" > "$FIXTURE/scan-count"
state=$(sed -n "${count}p" "$FIXTURE/game-states")
now=$(sed -n "${count}p" "$FIXTURE/game-times")
printf '%s.00 0.00\\n' "$now" > "$FIXTURE/uptime"
case "$state" in present) printf '123\\n'; exit 0 ;; absent) exit 1 ;; error) exit 2 ;; *) exit 2 ;; esac
''')
            pgrep.chmod(0o755)
            mock = root / 'systemctl'
            mock.write_text('#!' + shutil.which('bash') + '\n' + '''set -eu
if [[ $1 == is-active && $2 == forgejo-runner-aggregate-lifecycle.service ]]; then
  [[ $LIFECYCLE_ACTIVE == 1 ]] && printf 'active\\n' || { printf 'inactive\\n'; exit 3; }
  exit
fi
if [[ $1 == show ]]; then
  if ((SHOW_FAIL_COUNT > 0)); then
    count=0
    [[ ! -e $FIXTURE/show-attempts ]] || count=$(cat "$FIXTURE/show-attempts")
    count=$((count + 1))
    printf '%s\\n' "$count" > "$FIXTURE/show-attempts"
    ((count > SHOW_FAIL_COUNT)) || exit 1
  fi
  property=${2#--property=}
  [[ $3 == --value ]]
  case "$4" in
    forgejo-actions-runner.service) runner_file="$FIXTURE/runner" ;;
    forgejo-podman-actions-runner.service) runner_file="$FIXTURE/podman-runner" ;;
    *) runner_file='' ;;
  esac
  case "$4:$property" in
    forgejobuilds.slice:FreezerState) cat "$FIXTURE/actual" ;;
    *:ActiveState) cat "${runner_file}-active" ;;
    *:UnitFileState) cat "${runner_file}-enabled" ;;
    *:LoadState) cat "${runner_file}-load" ;;
    *:Result) cat "${runner_file}-result" ;;
    *:ExecMainStartTimestampMonotonic) cat "${runner_file}-generation" ;;
    *) exit 2 ;;
  esac
  exit
fi
if [[ $1 == --no-block ]]; then
  [[ $# == 3 ]]
  case "$3" in
    forgejo-actions-runner.service) runner_file="$FIXTURE/runner"; printf '%s\n' "$2" >> "$FIXTURE/runner-actions" ;;
    forgejo-podman-actions-runner.service) runner_file="$FIXTURE/podman-runner" ;;
    *) exit 2 ;;
  esac
  printf '%s:%s\n' "$2" "$3" >> "$FIXTURE/runner-unit-actions"
  [[ $3 != forgejo-actions-runner.service || $2 != "$FAIL_RUNNER_ACTION" ]] || exit 1
  case "$2" in
    stop)
      if [[ $3 == forgejo-actions-runner.service ]]; then
        printf '%s' "$STOP_STATE" > "${runner_file}-active"
        printf '%s' "$STOP_GENERATION" > "${runner_file}-generation"
      else
        printf '%s' "${SECOND_STOP_STATE:-inactive}" > "${runner_file}-active"
        printf '0' > "${runner_file}-generation"
      fi
      ;;
    start) printf active > "${runner_file}-active" ;;
    *) exit 2 ;;
  esac
  exit
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
                   'TRANSITION_TIMEOUT_SECONDS': transition_timeout,
                   'ADMISSION_CONTROL_ENABLED': '1' if admission else '0',
                   'SEVERE_THRESHOLD_HUNDREDTHS': '6000',
                   'SEVERE_SAMPLES_REQUIRED': '3', 'STOP_STATE': stop_state,
                   'STOP_GENERATION': stop_generation,
                   'FAIL_RUNNER_ACTION': fail_runner_action,
                   'LIFECYCLE_ACTIVE': '1' if lifecycle_active else '0',
                   'SHOW_FAIL_COUNT': show_fail_count,
                   'RUNNER_UNITS': ' '.join(runner_units or [PRIMARY]),
                   'SECOND_STOP_STATE': (second_runner or {}).get('stop_state', 'inactive')}
            if game_states is not None:
                env.update({'GAME_ADMISSION_ENABLED': '1', 'GAME_USER': 'alc',
                            'GAME_ARGV0_BASENAMES': 'HeroesOfTheStorm_x64.exe',
                            'GAME_PROC_ROOT': str(root / 'proc'),
                            'PGREP_BIN': str(pgrep), 'GAME_UPTIME_FILE': str(root / 'uptime'),
                            'GAME_COOLDOWN_SECONDS': '30'})
            result = subprocess.run(['bash', str(GUARD)], env=env, capture_output=True)
            self.events = result.stdout.decode().splitlines()
            self.guard_stderr = result.stderr.decode()
            actions = (root / 'actions').read_text().splitlines() if (root / 'actions').exists() else []
            self.runner_actions = ((root / 'runner-actions').read_text().splitlines()
                                   if (root / 'runner-actions').exists() else [])
            self.runner_unit_actions = ((root / 'runner-unit-actions').read_text().splitlines()
                                        if (root / 'runner-unit-actions').exists() else [])
            self.drain_owned = (state / 'drain-owned').exists()
            self.second_drain_owned = (state / 'runners' / SECOND / 'drain-owned').exists()
            self.second_drain_pending = (state / 'runners' / SECOND / 'drain-pending').exists()
            self.first_drain_generation = ((state / 'drain-owned').read_text().strip()
                                           if self.drain_owned else None)
            self.second_drain_generation = ((state / 'runners' / SECOND / 'drain-owned').read_text().strip()
                                            if self.second_drain_owned else None)
            self.drain_pending = (state / 'drain-pending').exists()
            self.resume_pending = (state / 'resume-pending').exists()
            self.drain_disowned = (state / 'drain-disowned').exists()
            self.game_start_skipped = (state / 'game-start-skipped').exists()
            return result.returncode, actions, (state / 'owned').exists(), (state / 'pending').exists()

    def test_hysteresis_freezes_and_thaws_aggregate(self):
        self.assertEqual(self.run_guard([2500, 2500, 1000, 0, 0]), (0, ['freeze', 'thaw'], False, False))

    def test_transition_events_are_ordered_and_include_duration(self):
        self.run_guard([2500, 2500, 1000, 0, 0])
        self.assertEqual([line.split()[0] for line in self.events],
                         ['event=freeze_requested', 'event=frozen',
                          'event=thaw_requested', 'event=thawed'])
        self.assertIn('sampled_full_avg10_hundredths=2500', self.events[0])
        self.assertRegex(self.events[-1], r'transition_seconds=\d+ frozen_seconds=\d+$')

    def test_restart_does_not_invent_frozen_duration(self):
        self.run_guard([0, 0], initial='frozen', owned=True)
        self.assertIn('frozen_seconds=unknown', self.events[-1])

    def test_failed_transition_does_not_report_completion(self):
        self.run_guard([2500, 2500], fail_action='freeze', fail_count='1',
                       fail_state='freezing')
        self.assertEqual([line.split()[0] for line in self.events], ['event=freeze_requested'])

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

    def test_read_only_metadata_retries_during_daemon_reload(self):
        self.assertEqual(self.run_guard([0], show_fail_count='2'),
                         (0, [], False, False))

    def test_pressure_is_deferred_until_lifecycle_is_armed(self):
        self.assertEqual(self.run_guard([6500, 6500, 6500], lifecycle_active=False),
                         (0, [], False, False))

    def test_teardown_marker_blocks_guard_reentry(self):
        self.assertEqual(self.run_guard([0], teardown_required=True),
                         (1, [], False, False))

    def test_admission_mode_drains_at_moderate_pressure_without_freezing(self):
        self.assertEqual(self.run_guard([2500] * 8, admission=True),
                         (0, [], False, False))
        self.assertEqual(self.runner_actions, ['stop'])
        self.assertTrue(self.drain_owned)
        self.assertEqual([line.split()[0] for line in self.events],
                         ['event=admission_drain_requested', 'event=admission_draining'])

    def test_admission_mode_freezes_only_after_severe_pressure(self):
        self.assertEqual(self.run_guard([6500, 6500, 6500], admission=True),
                         (0, ['freeze'], True, False))
        self.assertEqual(self.runner_actions, ['stop'])
        self.assertTrue(self.drain_owned)

    def test_recovery_thaws_before_restarting_runner(self):
        self.assertEqual(self.run_guard([0, 0], initial='frozen', owned=True,
                                        admission=True, drain_owned=True,
                                        runner_state='inactive'),
                         (0, ['thaw'], False, False))
        self.assertEqual(self.runner_actions, ['start'])
        events = [line.split()[0] for line in self.events]
        self.assertLess(events.index('event=thawed'),
                        events.index('event=admission_resume_requested'))
        self.assertFalse(self.drain_owned)

    def test_draining_job_is_not_stopped_twice_or_started_early(self):
        self.assertEqual(self.run_guard([2500, 2500, 0, 0], admission=True,
                                        stop_state='deactivating'),
                         (0, [], False, False))
        self.assertEqual(self.runner_actions, ['stop'])
        self.assertTrue(self.drain_owned)

    def test_guard_restart_resumes_owned_drain_without_second_stop(self):
        self.assertEqual(self.run_guard([0, 0], admission=True, drain_owned=True,
                                        runner_state='inactive', runner_generation='0',
                                        drain_generation='123'),
                         (0, [], False, False))
        self.assertEqual(self.runner_actions, ['start'])
        self.assertFalse(self.drain_owned)

    def test_skipped_switch_start_does_not_block_owned_resume(self):
        self.assertEqual(self.run_guard([0, 0], admission=True, drain_owned=True,
                                        runner_state='inactive', runner_result='exec-condition',
                                        runner_generation='0', drain_generation='123'),
                         (0, [], False, False))
        self.assertEqual(self.runner_actions, ['start'])

    def test_switch_condition_phase_keeps_owned_drain_without_resuming(self):
        self.assertEqual(self.run_guard([0, 0], admission=True, drain_owned=True,
                                        runner_state='activating', runner_generation='0',
                                        drain_generation='123'),
                         (0, [], False, False))
        self.assertEqual(self.runner_actions, [])
        self.assertTrue(self.drain_owned)

    def test_new_main_generation_during_condition_phase_is_disowned(self):
        self.assertEqual(self.run_guard([0], admission=True, drain_owned=True,
                                        runner_state='activating', runner_generation='456',
                                        drain_generation='123'),
                         (1, [], False, False))
        self.assertTrue(self.drain_disowned)

    def test_guard_restart_does_not_claim_inactive_runner(self):
        self.assertEqual(self.run_guard([2500, 2500, 0, 0], admission=True,
                                        runner_state='inactive'),
                         (0, [], False, False))
        self.assertEqual(self.runner_actions, [])
        self.assertFalse(self.drain_owned)

    def test_disabled_runner_is_neither_drained_nor_restarted(self):
        self.run_guard([2500, 2500, 0, 0], admission=True,
                       runner_enabled='disabled')
        self.assertEqual(self.runner_actions, [])
        self.assertFalse(self.drain_owned)

    def test_failed_runner_with_owned_drain_is_not_restarted(self):
        self.run_guard([0, 0], admission=True, drain_owned=True,
                       runner_state='failed', runner_result='exit-code')
        self.assertEqual(self.runner_actions, [])
        self.assertTrue(self.drain_owned)

    def test_disabled_runner_with_owned_drain_is_not_restarted(self):
        self.run_guard([0, 0, 0, 0], admission=True, drain_owned=True,
                       runner_state='inactive', runner_enabled='disabled')
        self.assertEqual(self.runner_actions, [])
        self.assertTrue(self.drain_owned)
        self.assertEqual(sum('event=admission_resume_blocked' in event
                             for event in self.events), 1)

    def test_ambiguous_drain_fails_without_second_stop(self):
        self.assertEqual(self.run_guard([2500], admission=True, drain_pending=True),
                         (1, [], False, False))
        self.assertEqual(self.runner_actions, [])
        self.assertTrue(self.drain_pending)

    def test_ambiguous_resume_fails_without_duplicate_start(self):
        self.assertEqual(self.run_guard([0], admission=True, resume_pending=True,
                                        runner_state='inactive'),
                         (1, [], False, False))
        self.assertEqual(self.runner_actions, [])
        self.assertTrue(self.resume_pending)

    def test_failed_stop_retains_ambiguous_drain_state(self):
        self.assertEqual(self.run_guard([2500, 2500], admission=True,
                                        fail_runner_action='stop'),
                         (1, [], False, False))
        self.assertEqual(self.runner_actions, ['stop'])
        self.assertTrue(self.drain_pending)
        self.assertFalse(self.drain_owned)

    def test_failed_start_retains_ambiguous_resume_state(self):
        self.assertEqual(self.run_guard([0, 0], admission=True, drain_owned=True,
                                        runner_state='inactive', fail_runner_action='start'),
                         (1, [], False, False))
        self.assertEqual(self.runner_actions, ['start'])
        self.assertTrue(self.resume_pending)
        self.assertFalse(self.drain_owned)

    def test_unreadable_pressure_in_admission_mode_freezes_and_fails_closed(self):
        self.assertEqual(self.run_guard([0, 'invalid'], admission=True),
                         (1, ['freeze'], True, False))

    def test_changed_runner_generation_is_disowned_and_fails_closed(self):
        self.assertEqual(self.run_guard([0], admission=True, drain_owned=True,
                                        runner_generation='456', drain_generation='123'),
                         (1, [], False, False))
        self.assertEqual(self.runner_actions, [])
        self.assertFalse(self.drain_owned)
        self.assertTrue(self.drain_disowned)
        self.assertIn('event=admission_drain_disowned', self.events[0])

    def test_active_runner_without_generation_is_disowned_and_fails_closed(self):
        self.assertEqual(self.run_guard([0], admission=True, drain_owned=True,
                                        runner_state='active', runner_generation='0',
                                        drain_generation='123'),
                         (1, [], False, False))
        self.assertTrue(self.drain_disowned)

    def test_two_runner_drains_have_independent_generations(self):
        self.assertEqual(self.run_guard([2500, 2500], admission=True,
                                        second_runner={'generation': '456'},
                                        runner_units=[PRIMARY, SECOND]),
                         (0, [], False, False))
        self.assertEqual(self.runner_unit_actions,
                         [f'stop:{PRIMARY}', f'stop:{SECOND}'])
        self.assertTrue(self.drain_owned)
        self.assertTrue(self.second_drain_owned)
        self.assertEqual(self.first_drain_generation, '123')
        self.assertEqual(self.second_drain_generation, '456')

    def test_second_runner_generation_change_fails_closed(self):
        self.assertEqual(self.run_guard([0], admission=True,
                                        second_runner={'generation': '789', 'drain_generation': '456'},
                                        second_marker='drain-owned', runner_units=[PRIMARY, SECOND])[0], 1)
        self.assertEqual(self.runner_unit_actions, [])
        self.assertFalse(self.second_drain_owned)

    def test_first_runner_recovers_while_second_runner_still_drains(self):
        self.run_guard([0, 0], admission=True, drain_owned=True,
                       runner_state='inactive', runner_generation='0',
                       drain_generation='123',
                       second_runner={'active': 'deactivating', 'generation': '456'},
                       second_marker='drain-owned', runner_units=[PRIMARY, SECOND])
        self.assertEqual(self.runner_unit_actions, [f'start:{PRIMARY}'])
        self.assertFalse(self.drain_owned)
        self.assertTrue(self.second_drain_owned)

    def test_disabled_second_runner_is_not_claimed_or_started(self):
        self.run_guard([2500, 2500, 0, 0], admission=True,
                       second_runner={'enabled': 'disabled'},
                       runner_units=[PRIMARY, SECOND])
        self.assertEqual(self.runner_unit_actions,
                         [f'stop:{PRIMARY}', f'start:{PRIMARY}'])
        self.assertFalse(self.second_drain_owned)

    def test_manually_stopped_second_runner_is_not_claimed(self):
        self.run_guard([2500, 2500, 0, 0], admission=True,
                       second_runner={'active': 'inactive', 'generation': '0'},
                       runner_units=[PRIMARY, SECOND])
        self.assertEqual(self.runner_unit_actions,
                         [f'stop:{PRIMARY}', f'start:{PRIMARY}'])
        self.assertFalse(self.second_drain_owned)

    def test_game_drains_both_runners_and_waits_through_cooldown(self):
        self.run_guard([0, 0, 0, 0], admission=True,
                       game_states=['present', 'absent', 'absent', 'absent'],
                       game_times=[100, 110, 129, 130],
                       second_runner={}, runner_units=[PRIMARY, SECOND])
        self.assertEqual(self.runner_unit_actions,
                         [f'stop:{PRIMARY}', f'stop:{SECOND}',
                          f'start:{PRIMARY}', f'start:{SECOND}'])
        self.assertFalse(self.drain_owned)
        self.assertFalse(self.second_drain_owned)

    def test_game_start_skip_resumes_only_when_enabled_and_clear(self):
        self.run_guard([0, 0], admission=True, runner_state='inactive',
                       runner_generation='0', game_start_skipped=True,
                       game_states=['absent', 'absent'], game_times=[100, 100])
        self.assertEqual(self.runner_actions, ['start'])
        self.assertFalse(self.game_start_skipped)
        self.run_guard([0, 0], admission=True, runner_state='inactive',
                       runner_enabled='disabled', runner_generation='0',
                       game_start_skipped=True,
                       game_states=['absent', 'absent'], game_times=[100, 100])
        self.assertEqual(self.runner_actions, [])
        self.assertTrue(self.game_start_skipped)

    def test_game_scanner_error_drains_without_guard_failure(self):
        self.assertEqual(self.run_guard([0, 0], admission=True,
                                        game_states=['error', 'error'],
                                        game_times=[100, 100])[0], 0)
        self.assertEqual(self.runner_actions, ['stop'])
        self.assertTrue(self.drain_owned)

    def test_game_does_not_change_pressure_thaw(self):
        self.assertEqual(self.run_guard([0, 0], initial='frozen', owned=True,
                                        admission=True, game_states=['present', 'present'],
                                        game_times=[100, 101])[1], ['thaw'])

    def test_ambiguous_second_drain_blocks_all_transitions(self):
        self.assertEqual(self.run_guard([2500, 2500], admission=True,
                                        second_runner={}, second_marker='drain-pending',
                                        runner_units=[PRIMARY, SECOND]),
                         (1, [], False, False))
        self.assertEqual(self.runner_unit_actions, [])
        self.assertTrue(self.second_drain_pending)

    def test_changed_runner_list_or_unknown_state_fails_closed(self):
        self.assertEqual(self.run_guard([0], runner_units=[PRIMARY],
                                        persisted_units=[PRIMARY, SECOND])[0], 1)
        self.assertEqual(self.run_guard([0], runner_units=[PRIMARY, SECOND],
                                        second_runner={}, unknown_state=True)[0], 1)


class LifecycleTests(unittest.TestCase):
    def run_stop(self, freezer='frozen', guard='failed', owned=False,
                 pending=False, drain_disowned=False, runner='inactive',
                 lock_held=False, kill_stays_deactivating=False,
                 second_runner=None, runner_units=None, persisted_units=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state'
            state.mkdir()
            cgroup = root / 'cgroup' / 'forgejobuilds.slice'
            cgroup.mkdir(parents=True)
            (cgroup / 'cgroup.kill').touch()
            (cgroup / 'cgroup.events').write_text('populated 0\n')
            (root / 'freezer').write_text(freezer)
            (root / 'guard').write_text(guard)
            (root / 'runner').write_text(runner)
            if second_runner is not None:
                (root / 'podman-runner').write_text(second_runner)
            if persisted_units is not None:
                (state / 'runner-units').write_text('\n'.join(persisted_units) + '\n')
            if owned:
                (state / 'owned').touch()
            if pending:
                (state / 'pending').touch()
            if drain_disowned:
                (state / 'drain-disowned').touch()
            mock = root / 'systemctl'
            mock.write_text('#!' + shutil.which('bash') + '\n' + '''set -eu
if [[ $1 == show ]]; then
  case "$2:$4" in
    --property=ControlGroup:forgejobuilds.slice) printf '/forgejobuilds.slice\\n' ;;
    --property=FreezerState:forgejobuilds.slice) cat "$FIXTURE/freezer" ;;
    --property=ActiveState:forgejo-runner-io-pressure-guard.service) cat "$FIXTURE/guard" ;;
    --property=ActiveState:forgejo-actions-runner.service) cat "$FIXTURE/runner" ;;
    --property=ActiveState:forgejo-podman-actions-runner.service) cat "$FIXTURE/podman-runner" ;;
    *) exit 2 ;;
  esac
elif [[ $1 == thaw && $2 == forgejobuilds.slice ]]; then
  [[ $(cat "$FIXTURE/cgroup/forgejobuilds.slice/cgroup.kill") == 1 ]]
  printf running > "$FIXTURE/freezer"
  printf 'thaw\\n' >> "$FIXTURE/actions"
elif [[ $1 == kill && $2 == --signal=KILL && $3 == --kill-whom=all ]]; then
  [[ $(cat "$FIXTURE/cgroup/forgejobuilds.slice/cgroup.kill") == 1 ]]
  case "$4" in
    forgejo-actions-runner.service) runner_file="$FIXTURE/runner"; action=kill ;;
    forgejo-podman-actions-runner.service) runner_file="$FIXTURE/podman-runner"; action=kill-podman ;;
    *) exit 2 ;;
  esac
  printf '%s\\n' "$action" >> "$FIXTURE/actions"
  [[ $KILL_STAYS_DEACTIVATING == 1 ]] || printf inactive > "$runner_file"
else
  exit 2
fi
''')
            mock.chmod(0o755)
            env = {**os.environ, 'FIXTURE': str(root), 'STATE_DIR': str(state),
                   'CGROUP_ROOT': str(root / 'cgroup'), 'SYSTEMCTL_BIN': str(mock),
                   'TEARDOWN_TIMEOUT_SECONDS': '2' if lock_held or kill_stays_deactivating else '270',
                   'KILL_STAYS_DEACTIVATING': '1' if kill_stays_deactivating else '0',
                   'RUNNER_UNITS': ' '.join(runner_units or [PRIMARY])}
            with (state / 'lifecycle.lock').open('w') as lock:
                if lock_held:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = subprocess.run(['bash', str(LIFECYCLE)], env=env,
                                        capture_output=True, timeout=6)
            killed = (cgroup / 'cgroup.kill').read_text().strip() == '1'
            actions = ((root / 'actions').read_text().splitlines()
                       if (root / 'actions').exists() else [])
            return (result.returncode, killed, actions,
                    (state / 'owned').exists(), (state / 'teardown-required').exists())

    def test_guard_loss_kills_before_owned_thaw_even_if_drain_disowned(self):
        self.assertEqual(self.run_stop(owned=True, drain_disowned=True),
                         (0, True, ['thaw'], False, True))

    def test_manual_freeze_kills_workers_without_thaw(self):
        self.assertEqual(self.run_stop(), (0, True, [], False, True))

    def test_ambiguous_freeze_is_not_thawed(self):
        self.assertEqual(self.run_stop(owned=True, pending=True),
                         (0, True, [], True, True))

    def test_incomplete_freeze_terminates_workers_without_claiming_thaw(self):
        self.assertEqual(self.run_stop(freezer='freezing', pending=True),
                         (0, True, [], False, True))

    def test_routine_unfrozen_stop_keeps_graceful_path(self):
        self.assertEqual(self.run_stop(freezer='running', guard='active'),
                         (0, False, [], False, False))

    def test_unfrozen_guard_loss_kills_workers(self):
        self.assertEqual(self.run_stop(freezer='running'),
                         (0, True, [], False, True))

    def test_blocking_runner_is_killed_before_owned_thaw(self):
        self.assertEqual(self.run_stop(owned=True, runner='deactivating'),
                         (0, True, ['kill', 'thaw'], False, True))

    def test_lock_wait_consumes_the_same_teardown_deadline(self):
        self.assertEqual(self.run_stop(lock_held=True),
                         (1, False, [], False, False))

    def test_signal_delivery_without_runner_stop_does_not_report_success(self):
        self.assertEqual(self.run_stop(owned=True, runner='deactivating',
                                       kill_stays_deactivating=True),
                         (1, True, ['kill'], True, True))

    def test_teardown_kills_both_runners_before_owned_thaw(self):
        self.assertEqual(self.run_stop(owned=True, runner='deactivating',
                                       second_runner='deactivating',
                                       runner_units=[PRIMARY, SECOND]),
                         (0, True, ['kill', 'kill-podman', 'thaw'], False, True))

    def test_teardown_includes_runner_from_previous_configuration(self):
        self.assertEqual(self.run_stop(owned=True, second_runner='deactivating',
                                       runner_units=[PRIMARY],
                                       persisted_units=[PRIMARY, SECOND]),
                         (0, True, ['kill-podman', 'thaw'], False, True))


class StartGateTests(unittest.TestCase):
    def run_gate(self, marker='', freezer='running', lifecycle=True, guard=True,
                 clear_under_lock=False, runner_unit=PRIMARY, runner_units=None,
                 second_marker='', persisted_units=None, unknown_state=False,
                 game_state=None, game_last_seen=None, game_now=100,
                 game_argv0='/games/HeroesOfTheStorm_x64.exe',
                 game_exe='wine64-preloader', missing_cmdline=False,
                 zombie=False, game_bypass=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state'
            state.mkdir()
            if game_bypass is not None:
                (state / 'game-bypass').write_text(game_bypass + '\n')
            if marker:
                (state / marker).touch()
            if game_last_seen is not None:
                (state / 'game-last-seen').write_text(str(game_last_seen) + '\n')
            if runner_units and SECOND in runner_units:
                (state / 'runners' / SECOND).mkdir(parents=True)
            if second_marker:
                (state / 'runners' / SECOND / second_marker).touch()
            if persisted_units is not None:
                (state / 'runner-units').write_text('\n'.join(persisted_units) + '\n')
            if unknown_state:
                (state / 'runners' / 'old-runner.service').mkdir(parents=True)
            mock = root / 'systemctl'
            mock.write_text('#!' + shutil.which('bash') + '\n' + '''set -eu
if [[ $1 == is-active && $2 == --quiet ]]; then
  case "$3" in
    forgejo-runner-aggregate-lifecycle.service) [[ $LIFECYCLE_ACTIVE == 1 ]] ;;
    forgejo-runner-io-pressure-guard.service) [[ $GUARD_ACTIVE == 1 ]] ;;
    *) exit 2 ;;
  esac
elif [[ $1 == show && $2 == --property=FreezerState && $3 == --value && $4 == forgejobuilds.slice ]]; then
  printf '%s\\n' "$FREEZER_STATE"
else
  exit 2
fi
''')
            mock.chmod(0o755)
            (root / 'proc' / '123').mkdir(parents=True)
            (root / game_exe).touch()
            if not zombie:
                (root / 'proc' / '123' / 'exe').symlink_to(root / game_exe)
            else:
                (root / 'proc' / '123' / 'stat').write_text('123 (defunct) Z 1 0 0\n')
            if not missing_cmdline:
                (root / 'proc' / '123' / 'cmdline').write_bytes(
                    game_argv0.encode() + b'\0hidden\0')
            (root / 'uptime').write_text(f'{game_now}.00 0.00\n')
            pgrep = root / 'pgrep'
            pgrep.write_text('#!' + shutil.which('bash') + '\n' + '''set -eu
[[ $1 == -u && $2 == alc && $# == 2 ]]
case "$GAME_STATE" in present) printf '123\\n'; exit 0 ;; absent) exit 1 ;; error) exit 2 ;; esac
exit 2
''')
            pgrep.chmod(0o755)
            env = {**os.environ, 'STATE_DIR': str(state), 'SYSTEMCTL_BIN': str(mock),
                   'GATE_TIMEOUT_SECONDS': '2', 'FREEZER_STATE': freezer,
                   'LIFECYCLE_ACTIVE': '1' if lifecycle else '0',
                   'GUARD_ACTIVE': '1' if guard else '0',
                   'RUNNER_UNIT': runner_unit,
                   'RUNNER_UNITS': ' '.join(runner_units or [PRIMARY])}
            if game_state is not None:
                env.update({'GAME_ADMISSION_ENABLED': '1', 'GAME_USER': 'alc',
                            'GAME_ARGV0_BASENAMES': 'HeroesOfTheStorm_x64.exe',
                            'GAME_PROC_ROOT': str(root / 'proc'),
                            'PGREP_BIN': str(pgrep), 'GAME_UPTIME_FILE': str(root / 'uptime'),
                            'GAME_COOLDOWN_SECONDS': '30', 'GAME_STATE': game_state,
                            'GAME_NOW': str(game_now)})
            if clear_under_lock:
                with (state / 'lifecycle.lock').open('w') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    process = subprocess.Popen(['bash', str(GATE)], env=env,
                                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    time.sleep(0.1)
                    (state / marker).unlink()
                process.communicate(timeout=6)
                return process.returncode, (state / marker).exists()
            result = subprocess.run(['bash', str(GATE)], env=env,
                                    capture_output=True, timeout=6)
            candidate_state = state if runner_unit == PRIMARY else state / 'runners' / SECOND
            self.game_start_skipped = (candidate_state / 'game-start-skipped').exists()
            return result.returncode, bool(marker and (state / marker).exists())

    def test_clear_healthy_start_is_admitted(self):
        self.assertEqual(self.run_gate(), (0, False))

    def test_game_blocks_first_start_for_both_runners(self):
        self.assertEqual(self.run_gate(game_state='present'), (1, False))
        self.assertTrue(self.game_start_skipped)
        self.assertEqual(self.run_gate(game_state='present', runner_unit=SECOND,
                                       runner_units=[PRIMARY, SECOND],
                                       persisted_units=[PRIMARY, SECOND]), (1, False))
        self.assertTrue(self.game_start_skipped)

    def test_gate_blocks_cooldown_and_scan_error(self):
        self.assertEqual(self.run_gate(game_state='absent', game_last_seen=80,
                                       game_now=100), (1, False))
        self.assertTrue(self.game_start_skipped)
        self.assertEqual(self.run_gate(game_state='error'), (1, False))
        self.assertTrue(self.game_start_skipped)
        self.assertEqual(self.run_gate(game_state='absent', game_last_seen=60,
                                       game_now=100), (0, False))
        self.assertFalse(self.game_start_skipped)

    def test_game_bypass_manual_timed_expired_and_malformed(self):
        for value in ('manual', '130'):
            self.assertEqual(self.run_gate(game_state='present', game_bypass=value,
                                           game_now=100), (0, False))
        self.assertEqual(self.run_gate(game_state='present', game_bypass='100',
                                       game_now=100), (1, False))
        self.assertEqual(self.run_gate(game_state='present', game_bypass='bad',
                                       game_now=100), (1, False))
        self.assertTrue(self.game_start_skipped)

    def test_exact_wine_argv0_filters_other_helpers_and_zombies(self):
        for argv0, exe, zombie in [
            ('C:\\Games\\Battle.net.exe', 'wine64-preloader', False),
            ('/games/HeroesOfTheStorm_x64.exe', 'uploader', False),
            ('/games/HeroesOfTheStorm_x64.exe', 'wine64-preloader', True),
        ]:
            with self.subTest(argv0=argv0, exe=exe, zombie=zombie):
                self.assertEqual(self.run_gate(game_state='present', game_argv0=argv0,
                                               game_exe=exe, zombie=zombie), (0, False))
                self.assertFalse(self.game_start_skipped)

    def test_unreadable_wine_argv0_blocks_admission(self):
        self.assertEqual(self.run_gate(game_state='present', missing_cmdline=True),
                         (1, False))
        self.assertTrue(self.game_start_skipped)

    def test_switch_start_during_owned_drain_is_skipped_without_mutation(self):
        self.assertEqual(self.run_gate(marker='drain-owned'), (1, True))

    def test_ambiguous_resume_is_skipped(self):
        self.assertEqual(self.run_gate(marker='resume-pending'), (1, True))

    def test_guard_can_clear_resume_intent_before_start_gate_observes_it(self):
        self.assertEqual(self.run_gate(marker='resume-pending', clear_under_lock=True),
                         (0, False))

    def test_owned_freeze_is_skipped(self):
        self.assertEqual(self.run_gate(marker='owned'), (1, True))

    def test_manual_freeze_is_skipped(self):
        self.assertEqual(self.run_gate(freezer='frozen'), (1, False))

    def test_unarmed_lifecycle_is_skipped_within_deadline(self):
        self.assertEqual(self.run_gate(lifecycle=False), (1, False))

    def test_other_owned_drain_does_not_strand_first_runner(self):
        self.assertEqual(self.run_gate(runner_units=[PRIMARY, SECOND],
                                       persisted_units=[PRIMARY, SECOND],
                                       second_marker='drain-owned'), (0, False))

    def test_second_runner_skips_its_owned_drain(self):
        self.assertEqual(self.run_gate(runner_unit=SECOND,
                                       runner_units=[PRIMARY, SECOND],
                                       persisted_units=[PRIMARY, SECOND],
                                       second_marker='drain-owned'), (1, False))

    def test_ambiguous_second_drain_blocks_both_runner_starts(self):
        self.assertEqual(self.run_gate(runner_units=[PRIMARY, SECOND],
                                       persisted_units=[PRIMARY, SECOND],
                                       second_marker='drain-pending'), (1, False))

    def test_changed_list_and_unknown_state_block_starts(self):
        self.assertEqual(self.run_gate(runner_units=[PRIMARY],
                                       persisted_units=[PRIMARY, SECOND]), (1, False))
        self.assertEqual(self.run_gate(unknown_state=True), (1, False))


class GameBypassControlTests(unittest.TestCase):
    def test_manual_timed_expiry_and_off(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state'
            state.mkdir(mode=0o700)
            uptime = Path(directory) / 'uptime'
            uptime.write_text('100.00 0.00\n')
            env = {**os.environ, 'GAME_BYPASS_STATE_DIR': str(state),
                   'GAME_UPTIME_FILE': str(uptime)}

            def control(*args):
                return subprocess.run(['bash', str(GAME_BYPASS_CONTROL), *args],
                                      env=env, capture_output=True, text=True)

            self.assertEqual(control('on').returncode, 0)
            self.assertEqual(control('status').stdout.strip(), 'manual')
            self.assertEqual(control('on', '--for', '2h').returncode, 0)
            self.assertEqual((state / 'game-bypass').read_text(), '7300\n')
            self.assertEqual(control('status').stdout.strip(), 'timed 7200 seconds remaining')
            uptime.write_text('7300.00 0.00\n')
            self.assertEqual(control('status').stdout.strip(), 'expired')
            self.assertEqual(control('off').returncode, 0)
            self.assertEqual(control('status').stdout.strip(), 'off')
            (state / 'game-bypass').write_text('bad\n')
            self.assertNotEqual(control('status').returncode, 0)
            self.assertEqual(control('status').stdout.strip(), 'invalid')


if __name__ == '__main__':
    unittest.main()
