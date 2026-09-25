import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("freelens-sync.py")
SPEC = importlib.util.spec_from_file_location("freelens_sync", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
freelens_sync = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = freelens_sync
SPEC.loader.exec_module(freelens_sync)


class FreelensSyncTest(unittest.TestCase):
    def test_merge_preserves_user_preferences_and_replaces_managed_paths(self):
        settings = {
            "preferences": {
                "colorTheme": "dark",
                "syncKubeconfigEntries": [
                    {"filePath": "/user/config"},
                    {"filePath": "/old/managed"},
                    {"filePath": "/user/config"},
                ],
            },
            "unrelated": {"kept": True},
        }

        merged, owned = freelens_sync.merge_sync_paths(
            settings,
            ["/old/managed"],
            ["/managed/primary", "/runtime/bivrost", "/managed/primary"],
        )

        self.assertEqual(merged["preferences"]["colorTheme"], "dark")
        self.assertEqual(merged["unrelated"], {"kept": True})
        self.assertEqual(
            merged["preferences"]["syncKubeconfigEntries"],
            [
                {"filePath": "/user/config"},
                {"filePath": "/managed/primary"},
                {"filePath": "/runtime/bivrost"},
            ],
        )
        self.assertEqual(owned, ["/managed/primary", "/runtime/bivrost"])

    def test_preexisting_user_path_is_not_claimed_or_removed(self):
        settings = {
            "preferences": {
                "syncKubeconfigEntries": [
                    {"filePath": "/user/already-managed-looking"},
                ],
            },
        }

        first, owned = freelens_sync.merge_sync_paths(
            settings,
            [],
            ["/user/already-managed-looking", "/nix/inserted"],
        )
        self.assertEqual(owned, ["/nix/inserted"])

        second, next_owned = freelens_sync.merge_sync_paths(first, owned, [])
        self.assertEqual(
            second["preferences"]["syncKubeconfigEntries"],
            [{"filePath": "/user/already-managed-looking"}],
        )
        self.assertEqual(next_owned, [])

    def test_main_writes_settings_and_managed_state_atomically(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            settings = root / "Freelens" / "lens-user-store.json"
            state = root / "state" / "managed.json"

            with mock.patch.object(
                freelens_sync, "freelens_is_running", return_value=False
            ):
                result = freelens_sync.main(
                    [
                        "freelens-kubeconfig-sync",
                        str(settings),
                        str(state),
                        "/config/a",
                        "/config/b",
                    ]
                )

            self.assertEqual(result, 0)
            self.assertEqual(json.loads(state.read_text()), ["/config/a", "/config/b"])
            self.assertEqual(
                json.loads(settings.read_text())["preferences"][
                    "syncKubeconfigEntries"
                ],
                [{"filePath": "/config/a"}, {"filePath": "/config/b"}],
            )
            self.assertEqual(settings.stat().st_mode & 0o777, 0o600)
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)

    def test_running_freelens_leaves_files_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            settings = root / "lens-user-store.json"
            state = root / "managed.json"
            settings.write_text('{"preferences":{"colorTheme":"light"}}\n')

            with mock.patch.object(
                freelens_sync, "freelens_is_running", return_value=True
            ):
                result = freelens_sync.main(
                    ["freelens-kubeconfig-sync", str(settings), str(state), "/config/a"]
                )

            self.assertEqual(result, 0)
            self.assertEqual(
                settings.read_text(), '{"preferences":{"colorTheme":"light"}}\n'
            )
            self.assertFalse(state.exists())

    def test_invalid_user_store_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            settings = root / "lens-user-store.json"
            state = root / "managed.json"
            settings.write_text("not json\n")

            with mock.patch.object(
                freelens_sync, "freelens_is_running", return_value=False
            ):
                result = freelens_sync.main(
                    ["freelens-kubeconfig-sync", str(settings), str(state), "/config/a"]
                )

            self.assertEqual(result, 1)
            self.assertEqual(settings.read_text(), "not json\n")
            self.assertFalse(state.exists())


if __name__ == "__main__":
    unittest.main()
