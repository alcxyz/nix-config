#!/usr/bin/env python3
"""Exercise reconciliation with a stateful synthetic Wolf API."""
import copy
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SOURCE = Path('modules/nixos/services/wolf-streaming/wolf-coop-manager.py')
spec = importlib.util.spec_from_file_location('coop', SOURCE)
coop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coop)


class FakeApi:
    def __init__(self):
        self.apps = [
            {'id': 'entry', 'title': 'Shared'},
            {'id': 'individual', 'title': 'Individual', 'render_node': '/dev/dri/renderD128',
             'runner': {'name': 'individual', 'env': [], 'ports': []}},
        ]
        self.sessions = [{
            'app_id': 'entry', 'client_id': 'client', 'aes_key': 'synthetic-key',
            'aes_iv': 'synthetic-iv', 'rtsp_fake_ip': '192.0.2.1',
            'video_width': 1920, 'video_height': 1080, 'video_refresh_rate': 60,
            'audio_channel_count': 2,
        }]
        self.lobbies = []
        self.posts = []
        self.fail = None

    def get(self, path):
        name = path.rsplit('/', 1)[1]
        return {name: copy.deepcopy(getattr(self, name))}

    def post(self, path, payload):
        self.posts.append((path, copy.deepcopy(payload)))
        if self.fail == path:
            self.fail = None
            raise coop.WolfApiError('retryable synthetic failure')
        if path.endswith('/create'):
            self.lobbies.append(dict(payload, id='lobby', connected_sessions=[]))
            return {'lobby_id': 'lobby'}
        self.lobbies[0]['connected_sessions'].append(payload['moonlight_session_id'])
        return {}


class ReconciliationTest(unittest.TestCase):
    def setUp(self):
        self.api = FakeApi()
        self.observed = {}
        self.args = SimpleNamespace(
            entry_title=['Shared'], individual_title='Individual', lobby_name='Shared lobby',
            runner_name='shared-runner', runner_state_folder='/tmp/synthetic-runner',
            kdeconnect_executable='', video_producer_buffer_caps='synthetic-caps',
            initial_join_delay=0, existing_join_delay=0,
        )
        sleeper = patch.object(coop.time, 'sleep')
        self.sleep = sleeper.start()
        self.addCleanup(sleeper.stop)

    def reconcile(self):
        coop.reconcile_once(self.api, self.args, self.observed)

    def test_create_join_and_idempotent_connected_session(self):
        self.reconcile()
        self.assertEqual([path.rsplit('/', 1)[1] for path, _ in self.api.posts], ['create', 'join'])
        payload = self.api.posts[0][1]
        self.assertTrue(payload['multi_user'])
        self.assertFalse(payload['stop_when_everyone_leaves'])
        self.assertEqual(payload['video_settings']['width'], 1920)
        self.assertEqual(payload['runner']['name'], 'shared-runner')
        self.assertEqual(self.api.apps[1]['runner']['name'], 'individual')
        self.assertEqual(self.api.posts[1][1], {'lobby_id': 'lobby', 'moonlight_session_id': 'client'})
        self.reconcile()
        self.assertEqual(len(self.api.posts), 2)

    def test_existing_lobby_and_second_client(self):
        self.reconcile()
        self.api.sessions.append(dict(self.api.sessions[0], client_id='second'))
        self.reconcile()
        self.assertEqual(len(self.api.posts), 3)
        self.assertEqual(self.api.posts[-1][1]['moonlight_session_id'], 'second')

    def test_disconnected_generation_waits_for_each_identity_change(self):
        self.reconcile()
        for field in ('aes_key', 'aes_iv', 'rtsp_fake_ip'):
            with self.subTest(field=field):
                self.api.lobbies[0]['connected_sessions'] = []
                count = len(self.api.posts)
                self.reconcile()
                self.assertEqual(len(self.api.posts), count)
                self.api.sessions[0][field] += '-refreshed'
                self.reconcile()
                self.assertEqual(len(self.api.posts), count + 1)
                self.assertEqual(self.observed['client'], coop.stream_fingerprint(self.api.sessions[0]))

    def test_removed_session_clears_observation(self):
        self.reconcile()
        self.api.sessions = []
        self.reconcile()
        self.assertEqual(self.observed, {})

    def test_failed_create_or_join_remains_retryable(self):
        for endpoint in ('create', 'join'):
            with self.subTest(endpoint=endpoint):
                self.api = FakeApi()
                self.observed = {}
                self.api.fail = '/api/v1/lobbies/' + endpoint
                with self.assertRaises(coop.WolfApiError):
                    self.reconcile()
                self.assertEqual(self.observed, {})
                self.reconcile()
                self.assertEqual(self.api.lobbies[0]['connected_sessions'], ['client'])
                self.assertEqual(len(self.api.lobbies), 1)
                self.assertIn('client', self.observed)


if __name__ == '__main__':
    unittest.main()
