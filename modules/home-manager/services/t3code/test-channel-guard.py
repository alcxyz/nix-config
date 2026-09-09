"""Check channel changes against the generated guard without accessing a live service."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check(script, accepted_channel, accepted_version, expected, inside_service=False):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "version").write_text(accepted_version + "\n")
        if accepted_channel is not None:
            (root / "channel").write_text(accepted_channel + "\n")
        env = {
            **os.environ,
            "T3CODE_VERSION_STATE": str(root / "version"),
            "T3CODE_CHANNEL_STATE": str(root / "channel"),
            "T3CODE_RESTART_MARKER": str(root / "restart"),
            "T3CODE_ALLOW_DOWNGRADE": "0",
            # Bash functions take precedence over the wrapper's runtime PATH.
            # Report an inactive service so the guard never reads thread state.
            "BASH_FUNC_systemctl%%": "() { return 1; }",
        }
        if inside_service:
            (root / "unit").write_text("ExecStart=/nix/store/new-t3code/bin/t3 serve\n")
            (root / "cgroup").write_text("0::/user.slice/t3code.service\n")
            env.update({
                "T3CODE_MANAGED_UNIT": str(root / "unit"),
                "T3CODE_CGROUP_FILE": str(root / "cgroup"),
                "BASH_FUNC_systemctl%%": (
                    "() { if [[ $* == *is-active* ]]; then return 0; fi; "
                    "printf '%s\\n' '{ path=/nix/store/old-t3code/bin/t3 ; }'; }"
                ),
            })
        result = subprocess.run([script], env=env, capture_output=True, text=True)
        assert result.returncode == expected, (
            script, accepted_channel, accepted_version, result.returncode,
            result.stdout, result.stderr,
        )
        assert not (root / "restart").exists()


upstream, fork = sys.argv[1:]
check(upstream, None, "9999.0.0", 76)  # Legacy state belongs to upstream.
check(upstream, "upstream", "9999.0.0", 76)
check(fork, "fork", "9999.0.0", 76)
check(upstream, "fork", "9999.0.0", 0)
check(fork, "upstream", "9999.0.0", 0)
check(upstream, "upstream", "0.0.1", 0)
check(fork, "fork", "0.0.1", 0)
check(upstream, "invalid", "0.0.1", 76)
check(upstream, "fork", "9999.0.0", 75, inside_service=True)
check(fork, "upstream", "9999.0.0", 75, inside_service=True)
print("T3 channel guard: 10 cases passed")
