"""Check that T3 starts with the session variables and that a command change schedules a restart.

Usage: test-session-env.py WRAPPER UNIT_CHANGE_CHECK IDLE_CHECK SESSION_VARS NAME...

The wrapper runs with an empty environment, as under a user manager that
started before the graphical login, and must export every NAME from the
generated session variables file. Only variable names are compared.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

wrapper, unit_change_check, idle_check, session_vars, *names = sys.argv[1:]
assert names, "no session variable names to check"


def started_names(environment):
    result = subprocess.run(
        [wrapper, sys.executable, "-c", "import os; print('\\n'.join(os.environ))"],
        env=environment, capture_output=True, text=True,
    )
    assert result.returncode == 0, (result.returncode, result.stderr)
    return set(result.stdout.split())


# Before the login: nothing imported, so only the file can provide them.
before_login = started_names({"T3CODE_SESSION_VARS": session_vars})
missing = sorted(set(names) - before_login)
assert not missing, f"missing before login: {missing}"

# After a login imported an older copy: the file is read again anyway.
after_login = started_names({"T3CODE_SESSION_VARS": session_vars, "__HM_SESS_VARS_SOURCED": "1"})
missing = sorted(set(names) - after_login)
assert not missing, f"missing after login: {missing}"

# A missing file never keeps T3 from starting.
result = subprocess.run(
    [wrapper, sys.executable, "-c", "pass"],
    env={"T3CODE_SESSION_VARS": "/nonexistent/hm-session-vars.sh"}, capture_output=True, text=True,
)
assert result.returncode == 0 and "starting without them" in result.stderr, result

old = "/nix/store/profile/bin/t3 serve --port 3773"
new = "/nix/store/env-t3code-session-env/bin/t3code-session-env /nix/store/profile/bin/t3 serve --port 3773"


def check(loaded, managed, active="*", marker_expected=False, existing_marker=None):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        units = root / "units"
        units.mkdir()
        if managed is not None:
            (units / "t3code.service").write_text(f"[Service]\nExecStart={managed}\n")
        marker = root / "state" / "restart"
        if existing_marker is not None:
            marker.parent.mkdir()
            marker.write_text(existing_marker)
        show = f"{{ path=/x ; argv[]={loaded} ; ignore_errors=no ; }}" if loaded else "garbled"
        env = {
            **os.environ,
            "T3CODE_MANAGED_UNITS": str(units),
            "T3CODE_RESTART_MARKER": str(marker),
            # Bash functions take precedence over the wrapper's runtime PATH.
            "BASH_FUNC_systemctl%%": (
                f"() {{ if [[ $* == *is-active* ]]; then [[ $* == *{active}* ]]; return; fi; "
                f"printf '%s\\n' '{show}'; }}"
            ),
        }
        result = subprocess.run([unit_change_check], env=env, capture_output=True, text=True)
        assert result.returncode == 0, (loaded, managed, result.stdout, result.stderr)
        if marker_expected:
            assert marker.exists() and marker.read_text() == "", (loaded, managed, result.stdout)
        elif existing_marker is None:
            assert not marker.exists(), (loaded, managed, result.stdout)
        else:
            assert marker.read_text() == existing_marker, (loaded, managed)


check(old, old)
check(old, new, marker_expected=True)
# A deferred restart naming some units is widened to every running one.
check(old, new, marker_expected=True, existing_marker="t3code-bn.service\n")
# An unrelated deploy keeps an earlier deferred restart pending.
check(new, new, existing_marker="t3code.service\n")
# Stopped instances stay stopped; removed ones are Home Manager's.
check(old, new, active="nothing-is-active")
check(old, None)
# An unreadable command never blocks the activation or forces a restart.
check(None, new)


def idle(running_base_dir):
    """Run the idle check with the configured state directories absent.

    The unit's ExecStart is never consulted: after a systemd reload it shows
    the new configuration, so only the running process names its old state.
    """
    with tempfile.TemporaryDirectory() as proc_root:
        main_pid = "0"
        if running_base_dir:
            main_pid = "4242"
            (Path(proc_root) / main_pid).mkdir()
            (Path(proc_root) / main_pid / "cmdline").write_bytes(
                b"\0".join([b"node", b"bin.mjs", b"serve", b"--base-dir", running_base_dir.encode()]) + b"\0")
        env = {
            **os.environ,
            "T3CODE_SETTLE_SECONDS": "0",
            "T3CODE_PROC_ROOT": proc_root,
            "BASH_FUNC_systemctl%%": (
                "() { if [[ $* == *MainPID* ]]; then echo " + main_pid + "; else "
                "printf '%s\\n' '{ path=/x ; argv[]=/x serve --base-dir /new ; }'; fi; }"
            ),
        }
        env.pop("T3CODE_STATE_DATABASE", None)
        return subprocess.run([idle_check], env=env, capture_output=True, text=True).returncode


# A running instance still uses the state directory it started with, so a
# changed --base-dir cannot hide its live work (here: unreadable, so busy).
with tempfile.TemporaryDirectory() as directory:
    old_base = Path(directory) / "old"
    (old_base / "userdata").mkdir(parents=True)
    (old_base / "userdata" / "statev2.sqlite").write_text("not a database")
    assert idle(None) == 0
    assert idle(str(old_base)) == 75
print(f"T3 session environment: {len(names)} variables, 7 restart cases, 2 idle cases passed")
