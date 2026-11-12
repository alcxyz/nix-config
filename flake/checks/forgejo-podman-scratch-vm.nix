# RAM scratch for the Podman CI store (#1027): the graphroot in a tmpfs, the
# image store and volumes on disk, with the production API unit and the store
# reset.
{pkgs}:
if pkgs.stdenv.hostPlatform.system != "x86_64-linux"
then pkgs.runCommand "forgejo-podman-scratch-unsupported-platform" {} ''touch "$out"''
else let
  fixtureImage = pkgs.dockerTools.buildLayeredImage {
    name = "scratch-fixture";
    tag = "local";
    contents = [pkgs.pkgsStatic.busybox];
    config.Cmd = ["/bin/busybox" "true"];
  };
  quietPressure = pkgs.writeText "fixture-quiet-pressure" "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n";
  reset = "forgejo-podman-store-reset.service";
in
  pkgs.testers.runNixOSTest {
    name = "forgejo-podman-scratch";
    nodes.machine = {lib, ...}: {
      imports = [../../modules/nixos/services/forgejo-actions-runner];
      options.sops.secrets = lib.mkOption {
        type = lib.types.attrs;
        default = {};
      };
      config = {
        system.stateVersion = "25.11";
        virtualisation = {
          memorySize = 2048;
          cores = 2;
          diskSize = 8192;
          docker.enable = true;
        };
        services.forgejo-actions-runner = {
          enable = true;
          name = "scratch-fixture";
          labels = ["fixture:docker://example.invalid/unused:local"];
          secretsFile = pkgs.writeText "fixture-secrets" "unused";
          isolatedDocker.enable = true;
          podmanStoreReset.enable = true;
          podmanCanary = {
            enable = true;
            registrationTokenFile = toString (pkgs.writeText "fixture-registration-token" "unused");
            labels = ["podman-fixture:docker://example.invalid/unused:local"];
            scratch = {
              enable = true;
              size = "256M";
            };
          };
        };
        systemd.timers.forgejo-podman-store-reset.wantedBy = lib.mkForce [];
        systemd.services.forgejo-podman-store-reset = {
          unitConfig.StartLimitIntervalSec = 0;
          environment.PRESSURE_FILE = toString quietPressure;
        };
        systemd.sockets.forgejo-runner-podman.unitConfig.StartLimitIntervalSec = 0;
        systemd.services.forgejo-runner-docker.unitConfig.StartLimitIntervalSec = 0;
        systemd.services.forgejo-runner-podman.unitConfig.StartLimitIntervalSec = 0;
        systemd.services.forgejo-actions-runner = {
          unitConfig.StartLimitIntervalSec = 0;
          preStart = lib.mkForce "";
          script = lib.mkForce "exec sleep infinity";
        };
        systemd.services.forgejo-podman-runner = {
          unitConfig.StartLimitIntervalSec = 0;
          preStart = lib.mkForce "";
          script = lib.mkForce "exec sleep infinity";
        };
        environment.systemPackages = [pkgs.docker];
        # A deploy that turns scratch off, and the first deploy that turns it
        # on, must leave a running API and its job alone.
        specialisation.noScratch.configuration.services.forgejo-actions-runner.podmanCanary.scratch.enable = lib.mkForce false;
      };
    };
    testScript = {nodes, ...}: let
      canary = nodes.machine.services.forgejo-actions-runner.podmanCanary;
    in ''
      store = "${canary.storageRoot}"
      graph = "${canary.graphRoot}"
      scratch = "${canary.scratch.path}"
      parent = store.rsplit("/", 1)[0]
      volumes = parent + "/volumes"
      api = "forgejo-runner-podman.service"
      reset = "${reset}"
      units = ["forgejo-runner-docker.service", api, "forgejo-actions-runner.service", "forgejo-podman-runner.service"]
      podman = "docker -H unix:///run/forgejo-podman/podman.sock"
      slice = "/sys/fs/cgroup/forgejobuilds.slice"

      def wait_units():
          for unit in units:
              machine.wait_for_unit(unit)

      # Detached runs: an attached `docker run` through the Podman compat API
      # can hang in the test VM after the container exits.
      def run(name, command, opts=""):
          machine.succeed(f"{podman} create --network none --name {name} {opts} scratch-fixture:local {command}")
          machine.succeed(f"{podman} start {name}")
          code = machine.succeed(f"timeout 120 {podman} wait {name}").strip()
          # Container output goes to the journal under the container's name.
          machine.succeed("journalctl --sync")
          out = machine.succeed(f"journalctl -o cat -t {name}")
          return int(code), out

      def shmem():
          return int(machine.succeed(f"awk '$1 == \"shmem\" {{ print $2 }}' {slice}/memory.stat").strip())

      start_all()
      machine.wait_for_unit("multi-user.target")
      wait_units()
      assert graph.startswith(scratch + "/"), graph

      with subtest("the graphroot is a size-limited tmpfs, the image store stays on disk"):
          machine.succeed(f"test \"$(findmnt -rn --mountpoint {scratch} -o FSTYPE)\" = tmpfs")
          options = machine.succeed(f"findmnt -rn --mountpoint {scratch} -o OPTIONS")
          assert "size=262144k" in options and "noswap" in options, options
          cmd = machine.succeed(f"systemctl show -p ExecStart --value {api}")
          assert f"--root={graph}" in cmd and f"--imagestore={store}" in cmd and "--transient-store" in cmd, cmd
          assert f"--volumepath={volumes}" in cmd, cmd
          machine.succeed(f"{podman} load < ${fixtureImage}")
          # Image layers and image metadata are on disk; nothing image-sized is in RAM.
          machine.succeed(f"test -s {store}/overlay-images/images.json")
          machine.succeed(f"find {store}/overlay -name busybox -path '*/diff/*' | grep -q .")
          machine.fail(f"find {graph} -name busybox -path '*/diff/*' | grep -q .")

      with subtest("container writes land in RAM, charged to the CI slice, and volumes on disk"):
          before = shmem()
          code, out = run("small", "/bin/busybox sh -c 'dd if=/dev/zero of=/fill bs=1M count=64 && dd if=/dev/zero of=/data/fill bs=1M count=32'", "-v fixture-volume:/data")
          assert code == 0, out
          grown = shmem() - before
          assert grown >= 60 * 2**20, f"slice shmem grew only {grown} bytes"
          # The container's writes reached neither the image store nor the
          # volumes; the volume is beside the image store, not in the scratch.
          machine.fail(f"find {store} -name fill | grep -q .")
          machine.succeed(f"test -s {volumes}/fixture-volume/_data/fill")
          machine.fail(f"find {graph} -path '*fixture-volume*' | grep -q .")
          machine.succeed(f"{podman} rm small && {podman} volume rm fixture-volume")
          assert shmem() - before < 16 * 2**20

      with subtest("an oversized job gets 'No space left on device', the host no pressure"):
          high = machine.succeed(f"grep -w high {slice}/memory.events").split()[1]
          # Another job's container is created and started before the scratch fills.
          machine.succeed(f"{podman} create --network none --name neighbour scratch-fixture:local /bin/busybox sleep 600")
          machine.succeed(f"{podman} start neighbour")
          code, out = run("big", "/bin/busybox dd if=/dev/zero of=/fill bs=1M count=400")
          assert code != 0 and "No space left on device" in out, out
          # The API's own state is outside the scratch: it still records,
          # lists and removes containers while the scratch is full.
          machine.succeed("test -s /run/forgejo-podman/storage/db.sql")
          machine.fail(f"test -e {graph}/db.sql")
          assert "neighbour" in machine.succeed(f"{podman} ps --format '{{{{.Names}}}}'")
          machine.succeed(f"{podman} rm big")
          machine.succeed(f"{podman} rm -f neighbour")
          assert machine.succeed(f"grep -w high {slice}/memory.events").split()[1] == high
          assert run("after-big", "/bin/busybox true")[0] == 0
          machine.succeed(f"{podman} rm after-big")
          machine.succeed(f"systemctl is-active {api}")

      with subtest("a fresh tmpfs, as after a reboot, keeps the images and runs containers"):
          machine.succeed(f"{podman} create --network none --name leftover scratch-fixture:local")
          machine.succeed(f"systemctl stop forgejo-podman-runner.service {api}")
          machine.succeed(f"systemctl stop {scratch}")
          machine.fail(f"mountpoint -q {scratch}")
          # The API pulls the tmpfs back in; a boot starts both.
          machine.succeed(f"systemctl start {api} forgejo-podman-runner.service")
          machine.succeed(f"test \"$(findmnt -rn --mountpoint {scratch} -o FSTYPE)\" = tmpfs")
          wait_units()
          assert "scratch-fixture" in machine.succeed(f"{podman} images --format '{{{{.Repository}}}}'")
          assert machine.succeed(f"{podman} ps -aq").strip() == ""
          assert run("after-reboot", "/bin/busybox true")[0] == 0
          machine.succeed(f"{podman} rm after-reboot")

      with subtest("an API restart empties what the earlier API left in the scratch"):
          # No trash appeared from the restarts above: the image store never
          # looks like a store from before scratch, and no volume was left.
          machine.fail(f"ls -d {parent}/.storage.trash.* 2>/dev/null")
          assert run("restart-leftover", "/bin/busybox dd if=/dev/zero of=/data/fill bs=1M count=32", "-v leftover-data:/data")[0] == 0
          # Trash that an interrupted store reset left in the tmpfs goes too.
          machine.succeed(f"mkdir -p {scratch}/.storage.trash.1 && fallocate -l 64M {scratch}/.storage.trash.1/blob")
          machine.succeed(f"systemctl restart {api}")
          wait_units()
          assert machine.succeed(f"{podman} ps -aq").strip() == ""
          assert "leftover-data" not in machine.succeed(f"{podman} volume ls -q")
          machine.fail(f"find {graph} -name fill | grep -q .")
          machine.fail(f"test -e {scratch}/.storage.trash.1")
          # The leftover volume went aside on disk, for the reset to delete.
          machine.fail(f"test -e {volumes}/leftover-data")
          machine.succeed(f"test -s {parent}/.storage.trash.*.volumes/leftover-data/_data/fill")
          machine.succeed(f"systemctl start {reset}", timeout=600)
          machine.fail(f"ls -d {parent}/.storage.trash.* 2>/dev/null")
          assert run("after-restart", "/bin/busybox true", "-v fresh-data:/data")[0] == 0
          machine.succeed(f"{podman} rm after-restart && {podman} volume rm fresh-data")

      with subtest("the API refuses to start without the tmpfs"):
          machine.succeed(f"systemctl stop forgejo-podman-runner.service {api}")
          # A runtime drop-in makes the mount fail; the API only wants it, so
          # its own check is what must refuse the start.
          dropin = "/run/systemd/system/run-forgejo\\x2dpodman\\x2dscratch.mount.d"
          machine.succeed(f"systemctl stop {scratch}")
          machine.succeed(f"mkdir -p '{dropin}' && printf '[Mount]\\nType=fixture-no-such-fs\\n' > '{dropin}/fail.conf' && systemctl daemon-reload")
          machine.fail(f"systemctl start {api}")
          machine.fail(f"mountpoint -q {scratch}")
          assert "Podman scratch tmpfs is not mounted" in machine.succeed(f"journalctl -u {api} -o cat")
          machine.succeed(f"rm -r '{dropin}' && systemctl daemon-reload && systemctl reset-failed {scratch}")
          machine.succeed(f"systemctl reset-failed {api} && systemctl start {api} forgejo-podman-runner.service")
          wait_units()

      with subtest("a store from before scratch is moved aside and deleted by the reset"):
          machine.succeed(f"systemctl stop {api}")
          machine.succeed(f"mkdir -p {store}/libpod {store}/volumes/old && fallocate -l 64M {store}/volumes/old/blob")
          machine.succeed(f"systemctl start {api} forgejo-podman-runner.service")
          wait_units()
          machine.succeed(f"ls -d {parent}/.storage.trash.*")
          machine.fail(f"test -e {store}/libpod")
          machine.succeed(f"systemctl start {reset}", timeout=600)
          machine.fail(f"ls -d {parent}/.storage.trash.* 2>/dev/null")

      with subtest("a due reset discards both stores and brings everything back"):
          machine.succeed(f"{podman} load < ${fixtureImage}")
          machine.succeed(f"{podman} create --network none --name leftover scratch-fixture:local")
          machine.succeed(f"{podman} volume create leftover-volume")
          machine.succeed("touch -d '-8 days' /var/lib/forgejo-podman-store-reset/reset-at")
          machine.succeed(f"systemctl start {reset}", timeout=600)
          journal = machine.succeed(f"journalctl -u {reset} -o cat")
          assert "reset due=store_age" in journal, journal
          assert "scratch_percent=" in journal, journal
          wait_units()
          assert machine.succeed(f"{podman} images -q").strip() == ""
          assert machine.succeed(f"{podman} ps -aq").strip() == ""
          assert "leftover-volume" not in machine.succeed(f"{podman} volume ls -q")
          machine.fail(f"ls -d {parent}/.storage.trash.* {scratch}/.storage.trash.* 2>/dev/null")

      with subtest("a scratch filled by a leftover container resets at once and the API starts"):
          machine.succeed(f"{podman} load < ${fixtureImage}")
          # Fill the tmpfs to the last byte, which a fresh API start must survive.
          assert run("leak", "/bin/busybox dd if=/dev/zero of=/fill bs=1M count=400")[0] != 0
          machine.succeed(f"test \"$(df --output=avail -B1 {scratch} | tail -1 | tr -d ' ')\" -lt 4194304")
          machine.succeed("touch -d '-10 minutes' /var/lib/forgejo-podman-store-reset/reset-at")
          machine.succeed(f"systemctl start {reset}", timeout=600)
          journal = machine.succeed(f"journalctl -u {reset} -o cat")
          assert "reset due=scratch_use" in journal, journal
          wait_units()
          assert machine.succeed(f"{podman} ps -aq").strip() == ""
          # Only the scratch was reset: the images stay on disk.
          assert machine.succeed(f"{podman} images -q").strip() != ""
          machine.succeed(f"test \"$(df --output=pcent {scratch} | tail -1 | tr -dc 0-9)\" -lt 10")

      with subtest("deploys that turn scratch off and on leave the running API alone"):
          pid = machine.succeed(f"systemctl show -p MainPID --value {api}").strip()
          machine.succeed("/run/current-system/specialisation/noScratch/bin/switch-to-configuration test", timeout=300)
          assert machine.succeed(f"systemctl show -p MainPID --value {api}").strip() == pid
          machine.succeed(f"mountpoint -q {scratch}")
          machine.succeed(f"{podman} info >/dev/null")
          # The rollback's API restart uses the image store as its graphroot.
          machine.succeed(f"systemctl restart {api} && systemctl start forgejo-podman-runner.service")
          assert f"--root={store}" in machine.succeed(f"systemctl show -p ExecStart --value {api}")
          assert "scratch-fixture" in machine.succeed(f"{podman} images --format '{{{{.Repository}}}}'")
          assert run("rolled-back", "/bin/busybox true")[0] == 0
          machine.succeed(f"{podman} rm rolled-back")
          pid = machine.succeed(f"systemctl show -p MainPID --value {api}").strip()
          machine.succeed("${nodes.machine.system.build.toplevel}/bin/switch-to-configuration test", timeout=300)
          assert machine.succeed(f"systemctl show -p MainPID --value {api}").strip() == pid
          machine.succeed(f"mountpoint -q {scratch}")
          machine.succeed(f"{podman} info >/dev/null")
    '';
  }
