"""Exercise the rendered production guard against synthetic device/sysfs trees."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

fixture = json.loads(Path(sys.argv[1]).read_text())
settings = fixture["settings"]


def run_case(name, *, alias=True, slot=None, identity=None, driver=None, settle=True, uevent=True):
    with tempfile.TemporaryDirectory(prefix="display-guard-") as directory:
        root = Path(directory)
        dev = root / "dev" / "dri"
        dev.mkdir(parents=True)
        card = dev / "card7"  # Deliberately unrelated to any stable card numbering.
        card.touch()
        if alias:
            (dev / settings["deviceName"]).symlink_to(card)
        sysfs = root / "sys" / "class" / "drm" / "card7" / "device"
        sysfs.mkdir(parents=True)
        if uevent:
            (sysfs / "uevent").write_text(
                f"PCI_SLOT_NAME={slot or settings['pciAddress']}\n"
                f"PCI_ID={identity or settings['pciId']}\n"
                f"DRIVER={driver or settings['driver']}\n"
            )
        settled = root / "settled"
        udevadm = root / "udevadm"
        udevadm.write_text(
            f"#!{shutil.which('bash')}\n"
            '[[ "$*" == "settle --timeout=10" ]] || exit 97\n'
            f"touch '{settled}'\n"
            f"exit {0 if settle else 1}\n"
        )
        udevadm.chmod(0o755)
        # Redirect only filesystem roots and the live settle command; execute the
        # actual generated guard's matching and rejection logic unchanged.
        script = fixture["script"].replace(fixture["udevadm"], str(udevadm))
        script = script.replace("/dev/dri/", str(dev) + "/")
        script = script.replace("/sys/class/drm/", str(root / "sys/class/drm") + "/")
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        expected_success = name == "matching device"
        assert (result.returncode == 0) == expected_success, (name, result.stderr)
        assert settled.exists(), f"{name}: guard did not settle udev before inspecting device"


run_case("matching device")
run_case("missing alias", alias=False)
run_case("wrong slot", slot="0000:04:05.6")
run_case("wrong PCI identity", identity="DCBA:4321")
run_case("wrong driver", driver="other_gpu")
run_case("settle failure", settle=False)
run_case("missing uevent", uevent=False)
print("Display device guard: matching device accepted; six failure cases rejected")
