# RAM scratch for the Podman CI store (#1027): the graphroot in a tmpfs, the
# volumes in an ext4 filesystem on zram, the image store on disk, with the
# production API unit and the store reset (ADR-0108).
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
  busybox = pkgs.pkgsStatic.busybox;
  # BuildKit as docker buildx's docker-container driver runs it, with
  # containerd's overlay snapshotter.
  buildkitFixture = pkgs.dockerTools.buildLayeredImage {
    name = "buildkit-fixture";
    tag = "local";
    contents = [pkgs.buildkit busybox pkgs.runc];
    extraCommands = "mkdir -m 1777 tmp";
    config = {
      Entrypoint = ["${pkgs.buildkit}/bin/buildkitd"];
      Env = ["PATH=/bin:/usr/bin"];
    };
  };
  # An offline build context whose Dockerfile installs a Debian package with
  # dpkg. dpkg extracts the package's new directory /etc/fixture.d as
  # /etc/fixture.d.dpkg-new and renames it into /etc, which an earlier layer
  # holds: on an overlay that cannot store its xattrs, as BuildKit's is with
  # its state on tmpfs, that rename fails with EXDEV.
  dpkgClosure = pkgs.closureInfo {rootPaths = [pkgs.dpkg busybox];};
  dpkgContext = pkgs.runCommand "forgejo-podman-dpkg-build-context" {nativeBuildInputs = [pkgs.dpkg];} ''
    mkdir -p $out/rootfs/{bin,etc,tmp,var/log,nix/store} $out/rootfs/var/lib/dpkg/{info,updates,triggers}
    touch $out/rootfs/var/lib/dpkg/{status,available}
    while read -r path; do cp -a "$path" $out/rootfs/nix/store/; done < ${dpkgClosure}/store-paths
    for tool in sh rm tar diff find cat test; do ln -s ${busybox}/bin/busybox $out/rootfs/bin/$tool; done
    ln -s ${pkgs.dpkg}/bin/dpkg $out/rootfs/bin/dpkg
    ln -s ${pkgs.dpkg}/bin/dpkg-deb $out/rootfs/bin/dpkg-deb
    mkdir -p package/DEBIAN package/etc/fixture.d
    echo installed > package/etc/fixture.d/fixture.conf
    printf '%s\n' 'Package: volume-fixture' 'Version: 1.0' 'Architecture: all' \
      'Maintainer: Fixture <fixture@example.invalid>' 'Description: offline dpkg fixture' > package/DEBIAN/control
    dpkg-deb --root-owner-group --build package $out/volume-fixture.deb
    cat > $out/Dockerfile <<'EOF'
    FROM scratch
    COPY rootfs/ /
    COPY volume-fixture.deb /volume-fixture.deb
    RUN ["/bin/dpkg", "--force-bad-path", "-i", "/volume-fixture.deb"]
    RUN ["/bin/sh", "-c", "test \"$(cat /etc/fixture.d/fixture.conf)\" = installed"]
    EOF
  '';
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
        # The runner hosts' kernel, so that what the check shows of ext4 and
        # zram holds for them.
        boot.kernelPackages = pkgs.linuxPackages_latest;
        virtualisation = {
          memorySize = 3072;
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
              volumes = {
                enable = true;
                size = "512M";
              };
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
        # Reports the runner pause as forgejo-runner does (nix-packages
        # ADR-0017): one running job while /run/fixture-job exists.
        systemd.services.forgejo-podman-runner = {
          unitConfig.StartLimitIntervalSec = 0;
          preStart = lib.mkForce "";
          serviceConfig.NotifyAccess = lib.mkForce "all";
          script = lib.mkForce ''
            pause=/run/nixfleet-runners/paused/forgejo-podman-runner.service
            last=
            while :; do
              if [ ! -e "$pause" ]; then
                status=running
              elif [ -e /run/fixture-job ]; then
                status="paused tasks=1"
              else
                status="paused tasks=0"
              fi
              if [ "$status" != "$last" ]; then
                systemd-notify --status="$status" && last=$status
              fi
              sleep 0.5
            done
          '';
        };
        environment.systemPackages = [pkgs.docker];
        # A deploy that turns scratch off, and the first deploy that turns it
        # on, must leave a running API and its job alone.
        specialisation.noScratch.configuration.services.forgejo-actions-runner.podmanCanary.scratch = {
          enable = lib.mkForce false;
          volumes.enable = lib.mkForce false;
        };
      };
    };
    testScript = {nodes, ...}: let
      canary = nodes.machine.services.forgejo-actions-runner.podmanCanary;
    in ''
      store = "${canary.storageRoot}"
      graph = "${canary.graphRoot}"
      scratch = "${canary.scratch.path}"
      parent = store.rsplit("/", 1)[0]
      disk_volumes = parent + "/volumes"
      vmount = "${canary.scratch.volumes.path}"
      started = "${canary.scratch.volumes.startedFile}"
      volumes = "${canary.volumePath}"
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

      def zram():
          source = machine.succeed(f"findmnt -rn --mountpoint {vmount} -o FSTYPE,SOURCE").split()
          assert source[0] == "ext4" and source[1].startswith("/dev/zram"), source
          return source[1].removeprefix("/dev/")

      # Memory the volume filesystem's zram device uses, from its mm_stat,
      # once the page cache is written to it.
      def zram_used():
          machine.succeed(f"sync -f {vmount}")
          return int(machine.succeed(f"cat /sys/block/{zram()}/mm_stat").split()[2])

      # The started file names the running API's start, which made the
      # volume filesystem.
      def made_by_running_api():
          machine.succeed(f"test \"$(cat {started})\" = \"$(systemctl show -p InvocationID --value {api})\"")

      buildx = "env DOCKER_HOST=unix:///run/forgejo-podman/podman.sock docker buildx"

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
          assert f"--volumepath={volumes}" in cmd and volumes.startswith(vmount + "/"), cmd
          # The volumes are on a fresh ext4 on zram, sized as configured,
          # mounted with discard; no volume directory is on disk.
          zram()
          options = machine.succeed(f"findmnt -rn --mountpoint {vmount} -o OPTIONS")
          assert options.startswith("rw,") and "discard" in options and "errors=remount-ro" in options, options
          assert machine.succeed(f"cat /sys/block/{zram()}/disksize").strip() == str(512 * 2**20)
          machine.succeed(f"test \"$(stat -c %U:%a {volumes})\" = forgejo-podman-builder:700")
          machine.fail(f"test -e {disk_volumes}")
          made_by_running_api()
          machine.succeed(f"{podman} load < ${fixtureImage}")
          # Image layers and image metadata are on disk; nothing image-sized is in RAM.
          machine.succeed(f"test -s {store}/overlay-images/images.json")
          machine.succeed(f"find {store}/overlay -name busybox -path '*/diff/*' | grep -q .")
          machine.fail(f"find {graph} -name busybox -path '*/diff/*' | grep -q .")

      with subtest("container writes land in the tmpfs, charged to the CI slice, and volumes in zram"):
          before = shmem()
          code, out = run("small", "/bin/busybox sh -c 'dd if=/dev/zero of=/fill bs=1M count=64 && dd if=/dev/zero of=/data/fill bs=1M count=32'", "-v fixture-volume:/data")
          assert code == 0, out
          grown = shmem() - before
          assert grown >= 60 * 2**20, f"slice shmem grew only {grown} bytes"
          # The container's writes reached neither the image store nor the
          # volumes; the volume is in zram, not in the scratch.
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

      with subtest("an API restart empties what the earlier API left in the scratch and the volumes"):
          # No trash appeared from the restarts above: the image store never
          # looks like a store from before scratch.
          machine.fail(f"ls -d {parent}/.storage.trash.* 2>/dev/null")
          before = zram_used()
          assert run("restart-leftover", "/bin/busybox dd if=/dev/urandom of=/data/fill bs=1M count=32", "-v leftover-data:/data")[0] == 0
          assert zram_used() - before >= 30 * 2**20
          # Trash that an interrupted store reset left in the tmpfs goes too.
          machine.succeed(f"mkdir -p {scratch}/.storage.trash.1 && fallocate -l 64M {scratch}/.storage.trash.1/blob")
          # Volumes left on disk from before they moved to RAM.
          machine.succeed(f"mkdir -p {disk_volumes}/old-volume/_data && fallocate -l 64M {disk_volumes}/old-volume/_data/blob")
          device = zram()
          machine.succeed(f"systemctl restart {api}")
          wait_units()
          assert machine.succeed(f"{podman} ps -aq").strip() == ""
          assert "leftover-data" not in machine.succeed(f"{podman} volume ls -q")
          machine.fail(f"find {graph} -name fill | grep -q .")
          machine.fail(f"test -e {scratch}/.storage.trash.1")
          # The volume filesystem is new, on the same device, and its memory
          # is free again.
          assert zram() == device
          machine.fail(f"test -e {volumes}/leftover-data")
          assert zram_used() < 16 * 2**20, zram_used()
          # The volumes from disk went aside for the reset to delete, and no
          # volume directory is on disk any more.
          machine.fail(f"test -e {disk_volumes}")
          machine.succeed(f"test -s {parent}/.storage.trash.*.volumes/old-volume/_data/blob")
          machine.succeed(f"systemctl start {reset}", timeout=600)
          machine.fail(f"ls -d {parent}/.storage.trash.* 2>/dev/null")
          assert run("after-restart", "/bin/busybox true", "-v fresh-data:/data")[0] == 0
          machine.succeed(f"{podman} rm after-restart && {podman} volume rm fresh-data")

      with subtest("BuildKit builds that run dpkg fail with their state on tmpfs and work in the volumes"):
          machine.succeed(f"{podman} load < ${buildkitFixture}")
          cgroup = "/forgejobuilds.slice/forgejo-runner-podman.service"

          def builder(name):
              machine.succeed(f"{buildx} create --name {name} --driver docker-container --driver-opt image=buildkit-fixture:local --driver-opt cgroup-parent={cgroup}")
              machine.succeed(f"timeout 150 {buildx} inspect --bootstrap {name}", timeout=180)

          def build(name):
              return machine.execute(f"timeout 600 {buildx} build --builder {name} --progress=plain ${dpkgContext} 2>&1", timeout=660)

          # The cause, reproduced: BuildKit's state in a tmpfs volume.
          machine.succeed(f"{podman} volume create --opt type=tmpfs --opt device=tmpfs buildx_buildkit_on-tmpfs0_state")
          builder("on-tmpfs")
          code, out = build("on-tmpfs")
          assert code != 0 and "Invalid cross-device link" in out, out
          print("TMPFS_STATE", [line for line in out.splitlines() if "cross-device" in line][:2])
          machine.succeed(f"{buildx} rm on-tmpfs")
          # The state in the volume filesystem: ext4, so dpkg works, while
          # the graphroot stays on the tmpfs.
          builder("on-zram")
          state = machine.succeed(f"{podman} volume inspect --format '{{{{.Mountpoint}}}}' buildx_buildkit_on-zram0_state").strip()
          assert state.startswith(volumes + "/"), state
          code, out = build("on-zram")
          assert code == 0, out
          print("ZRAM_STATE", [line for line in out.splitlines() if "dpkg" in line or "DONE" in line][-6:])
          machine.succeed(f"{buildx} rm on-zram")
          assert "buildx_buildkit_on-zram0_state" not in machine.succeed(f"{podman} volume ls -q")

      with subtest("a full volume filesystem fails the writer with 'No space left on device' and frees its memory"):
          before = zram_used()
          code, out = run("volume-fill", "/bin/busybox dd if=/dev/urandom of=/data/fill bs=1M count=600", "-v fill-data:/data")
          assert code != 0 and "No space left on device" in out, out
          # Incompressible data: the device holds about its whole size, and
          # no more.
          used = zram_used()
          print("ZRAM_FULL", before, used)
          assert used - before >= 400 * 2**20, (before, used)
          assert used <= 520 * 2**20, used
          # ext4 refused the write itself; the device never failed under it.
          options = machine.succeed(f"findmnt -rn --mountpoint {vmount} -o OPTIONS")
          assert options.startswith("rw,"), options
          machine.fail("journalctl -k -o cat | grep -E 'EXT4-fs (error|warning)|I/O error'")
          machine.succeed(f"{podman} info >/dev/null")
          # The job's cleanup removes its volume; discard returns the memory.
          machine.succeed(f"{podman} rm volume-fill && {podman} volume rm fill-data")
          machine.wait_until_succeeds(f"sync -f {vmount} && test $(awk '{{ print $3 }}' /sys/block/{zram()}/mm_stat) -lt {before + 32 * 2**20}", timeout=60)
          # The next job's volume works.
          assert run("after-fill", "/bin/busybox dd if=/dev/urandom of=/data/fill bs=1M count=64", "-v next-data:/data")[0] == 0
          machine.succeed(f"{podman} rm after-fill && {podman} volume rm next-data")

      with subtest("a real ext4 error stops all writes while mountinfo says rw, and the reset makes the filesystem again"):
          device = zram()
          errors = f"/sys/fs/ext4/{device}/errors_count"
          machine.succeed(f"test \"$(cat {errors})\" = 0")
          # ext4's own error path, as an I/O error on its metadata takes it,
          # under errors=remount-ro.
          machine.succeed(f"echo fixture-error > /sys/fs/ext4/{device}/trigger_fs_error")
          machine.succeed(f"journalctl -k -o cat | grep -q 'EXT4-fs error (device {device})'")
          kernel = machine.succeed("uname -r").strip()
          line = machine.succeed(f"awk -v m={vmount} '$5 == m' /proc/self/mountinfo").strip()
          print("EXT4_ERROR", kernel, line, "errors_count", machine.succeed(f"cat {errors}").strip())
          # The mount's own flag, all the reset read before, stays rw.
          assert line.split()[5].startswith("rw,"), line
          assert int(machine.succeed(f"cat {errors}")) >= 1
          # Yet nothing can be written: no volume, no file.
          out = machine.fail(f"touch {vmount}/probe 2>&1")
          assert "Read-only file system" in out, out
          out = machine.fail(f"{podman} volume create error-data 2>&1")
          print("EXT4_ERROR_VOLUME_CREATE", out.strip())
          # The reset sees it and makes the filesystem again, quiet runners
          # or not.
          machine.succeed(f"systemctl start {reset}", timeout=600)
          last = machine.succeed(f"journalctl -u {reset} -o cat | grep -E '^(skipped|stopping|reset) ' | tail -2")
          print("EXT4_ERROR_RESET", last)
          assert "volume_state=fs_error" in last and "reset due=volumes_unusable" in last, last
          wait_units()
          assert zram() == device
          machine.succeed(f"test \"$(cat {errors})\" = 0")
          made_by_running_api()
          assert run("after-error", "/bin/busybox dd if=/dev/urandom of=/data/fill bs=1M count=16", "-v after-error-data:/data")[0] == 0
          machine.succeed(f"{podman} rm after-error && {podman} volume rm after-error-data")

      with subtest("a leftover volume that used up the inodes, at few bytes, resets the scratch"):
          device = zram()
          # Empty files take an inode and no block, so they run out of
          # inodes first.
          code, out = run("inode-fill", "/bin/busybox sh -c 'i=0; while : 2>/dev/null >/data/f$i; do i=$((i+1)); done; echo made $i'", "-v inode-data:/data")
          print("INODE_FILL", code, out.strip().splitlines()[-1:])
          machine.succeed(f"{podman} rm inode-fill")
          usage = machine.succeed(f"df --output=pcent,ipcent {vmount} | tail -1").split()
          print("INODE_USE", usage)
          assert int(usage[0].rstrip("%")) < 10 and usage[1] == "100%", usage
          # Every new volume fails, as on a full filesystem.
          out = machine.fail(f"{podman} volume create inode-next 2>&1")
          assert "no space left on device" in out.lower(), out
          # The reset sees the inodes, not just the bytes, and makes the
          # filesystem again.
          machine.succeed(f"systemctl start {reset}", timeout=600)
          last = machine.succeed(f"journalctl -u {reset} -o cat | grep -E '^(skipped|stopping|reset) ' | tail -2")
          print("INODE_RESET", last)
          assert "volume_inode_percent=100" in last and "reset due=scratch_use" in last, last
          wait_units()
          assert zram() == device
          made_by_running_api()
          assert "inode-data" not in machine.succeed(f"{podman} volume ls -q")
          usage = machine.succeed(f"df --output=ipcent {vmount} | tail -1").strip()
          assert int(usage.rstrip("%")) < 5, usage
          assert run("after-inodes", "/bin/busybox true", "-v after-inodes-data:/data")[0] == 0
          machine.succeed(f"{podman} rm after-inodes && {podman} volume rm after-inodes-data")

      with subtest("a job running on a full volume filesystem: the pool is paused, and the reset waits for it"):
          pause = "/run/nixfleet-runners/paused/forgejo-podman-runner.service"
          job = "FORGEJO-ACTIONS-TASK-1_WORKFLOW-fixture_JOB-build"
          # Volumes a cancelled job left behind fill the filesystem.
          code, out = run("volume-leak", "/bin/busybox dd if=/dev/urandom of=/data/fill bs=1M count=600", "-v leaked-data:/data")
          assert code != 0 and "No space left on device" in out, out
          machine.succeed(f"{podman} rm volume-leak")
          usage = machine.succeed(f"df --output=pcent {vmount} | tail -1").strip()
          assert int(usage.rstrip("%")) >= 90, usage
          # A pool job still runs; its runner reports it once paused.
          machine.succeed(f"{podman} create --network none --name {job} scratch-fixture:local /bin/busybox sleep 600")
          machine.succeed(f"{podman} start {job} && touch /run/fixture-job")
          dropin = "/run/systemd/system/forgejo-podman-store-reset.service.d"
          machine.succeed(f"mkdir -p {dropin} && printf '[Service]\\nEnvironment=PAUSE_WAIT_SECONDS=5\\n' > {dropin}/wait.conf && systemctl daemon-reload")
          # A job that outlasts the wait: the reset unpauses the pool and
          # leaves everything running.
          machine.succeed(f"systemctl start {reset}", timeout=600)
          last = machine.succeed(f"journalctl -u {reset} -o cat | grep -E '^(skipped|pausing|reset) ' | tail -2")
          print("FULL_JOB_TIMEOUT", last)
          assert "pausing units=forgejo-podman-runner.service" in last, last
          assert "skipped reason=pool_not_drained unit=forgejo-podman-runner.service" in last, last
          machine.fail(f"test -e {pause}")
          machine.succeed("systemctl is-active forgejo-podman-runner.service")
          assert job in machine.succeed(f"{podman} ps --format '{{{{.Names}}}}'")
          machine.succeed(f"rm -r {dropin} && systemctl daemon-reload")
          # Within the wait: the job ends while the pool is paused.
          machine.succeed(f"systemctl start --no-block {reset}")
          machine.wait_until_succeeds(f"test -e {pause}", timeout=60)
          machine.wait_until_succeeds("systemctl show -p StatusText --value forgejo-podman-runner.service | grep -qx 'paused tasks=1'", timeout=30)
          machine.succeed("systemctl is-active forgejo-podman-runner.service")
          # The job's cleanup removes its container before its runner
          # reports it done.
          machine.succeed(f"{podman} rm -f {job} && rm /run/fixture-job")
          machine.wait_until_succeeds(f"journalctl -u {reset} -o cat | grep -E '^(skipped|reset) ' | tail -1 | grep -q '^reset '", timeout=300)
          journal = machine.succeed(f"journalctl -u {reset} -o cat | grep -E '^(pausing|drained|reset) ' | tail -3")
          print("FULL_JOB_RESET", journal)
          assert "drained unit=forgejo-podman-runner.service" in journal and "reset due=scratch_use" in journal, journal
          machine.fail(f"test -e {pause}")
          wait_units()
          made_by_running_api()
          assert "leaked-data" not in machine.succeed(f"{podman} volume ls -q")
          usage = machine.succeed(f"df --output=pcent {vmount} | tail -1").strip()
          assert int(usage.rstrip("%")) < 10, usage
          assert run("after-full-job", "/bin/busybox true", "-v after-full-data:/data")[0] == 0
          machine.succeed(f"{podman} rm after-full-job && {podman} volume rm after-full-data")

      with subtest("writes the zram device cannot store: data errors are not counted, metadata errors are"):
          # zram fails a write when it cannot allocate memory for it; its
          # mem_limit fails it the same way, so the check can cause it.
          device = zram()
          errors = f"/sys/fs/ext4/{device}/errors_count"
          used = zram_used()
          machine.succeed(f"echo {used + 8 * 2**20} > /sys/block/{device}/mem_limit")
          # File data: its writer gets the error, ext4 only warns.
          code, out = machine.execute(f"dd if=/dev/urandom of={vmount}/writeback-probe bs=1M count=64 conv=fsync 2>&1")
          data_errors = machine.succeed(f"cat {errors}").strip()
          print("WRITEBACK_DATA", code, out.strip().splitlines()[-1:], "errors_count", data_errors)
          assert code != 0, out
          machine.succeed(f"journalctl -k -o cat | grep -q 'EXT4-fs warning (device {device}): ext4_end_bio.*I/O error'")
          # ext4's metadata: the failed writes are noticed at the next
          # metadata change, which takes ext4's error path.
          machine.execute(f"sync -f {vmount}")
          code, out = machine.execute(f"touch {vmount}/after-writeback-probe 2>&1")
          line = machine.succeed(f"awk -v m={vmount} '$5 == m' /proc/self/mountinfo").strip()
          metadata_errors = machine.succeed(f"cat {errors}").strip()
          print("WRITEBACK_METADATA", "errors_count", metadata_errors, out.strip(), line)
          print("WRITEBACK_KERNEL", machine.succeed(f"journalctl -k -o cat | grep -E 'device {device}\\)|dev {device},' | grep -v 'logical block [0-9]*$' | tail -6"))
          assert code != 0 and "Read-only file system" in out, out
          assert int(metadata_errors) >= 1, metadata_errors
          machine.succeed(f"echo 0 > /sys/block/{device}/mem_limit")
          machine.succeed(f"systemctl start {reset}", timeout=600)
          last = machine.succeed(f"journalctl -u {reset} -o cat | grep -E '^(skipped|stopping|reset) ' | tail -2")
          print("WRITEBACK_RESET", last)
          assert "volume_state=fs_error" in last and "reset due=volumes_unusable" in last, last
          wait_units()
          assert zram() == device
          machine.succeed(f"test \"$(cat {errors})\" = 0")
          made_by_running_api()
          assert run("after-writeback", "/bin/busybox dd if=/dev/urandom of=/data/fill bs=1M count=64", "-v after-writeback-data:/data")[0] == 0
          machine.succeed(f"{podman} rm after-writeback && {podman} volume rm after-writeback-data")

      with subtest("an API start refuses while a host process holds the volume filesystem, and names it"):
          device = zram()
          # A shell left in the filesystem: its working directory keeps the
          # unmount busy.
          machine.succeed(f"systemd-run --unit=fixture-cwd --property=Type=exec --property=WorkingDirectory={vmount} ${pkgs.coreutils}/bin/sleep infinity")
          holder = machine.succeed("systemctl show -p MainPID --value fixture-cwd").strip()
          machine.succeed(f"systemctl stop forgejo-podman-runner.service {api}")
          machine.fail(f"systemctl start {api}")
          refusal = machine.succeed(f"journalctl -u {api} -o cat | grep 'is busy' | tail -1")
          print("CWD_REFUSAL", refusal)
          assert f"{vmount} is busy, held by processes: " in refusal and f" {holder} (sleep)" in refusal, refusal
          # The filesystem stays as it was, and no API start is recorded.
          assert zram() == device
          machine.fail(f"test -e {started}")
          machine.succeed("systemctl stop fixture-cwd")
          machine.succeed(f"systemctl reset-failed {api} && systemctl start {api} forgejo-podman-runner.service")
          wait_units()
          assert zram() == device
          made_by_running_api()

      with subtest("an API start refuses while another mount namespace holds the volume filesystem"):
          device = zram()
          # A process that made its own mount namespace while the API ran
          # keeps a copy of the mount that the host's unmount does not
          # reach, and so keeps the device open.
          machine.succeed("systemd-run --unit=fixture-holder --property=Type=exec ${pkgs.util-linux}/bin/unshare --mount --propagation private ${pkgs.coreutils}/bin/sleep infinity")
          holder = machine.succeed("systemctl show -p MainPID --value fixture-holder").strip()
          devices = machine.succeed("ls /sys/block | grep zram")
          machine.wait_until_succeeds(f"grep -q ' /dev/{device} ' /proc/{holder}/mountinfo")
          machine.succeed(f"systemctl stop forgejo-podman-runner.service {api}")
          for attempt in range(2):
              machine.fail(f"systemctl start {api}")
              journal = machine.succeed(f"journalctl -u {api} -o cat")
              assert f"/dev/{device} is still open, held by another mount namespace (processes: {holder} (sleep)" in journal, journal
              # Closed: nothing at the mount point, no other device, nothing
              # on disk, and no API start recorded.
              machine.fail(f"mountpoint -q {vmount}")
              machine.fail(f"test -e {disk_volumes}")
              machine.fail(f"test -e {started}")
              assert machine.succeed("ls /sys/block | grep zram") == devices
              machine.succeed(f"systemctl reset-failed {api}")
          print("HOLDER_REFUSAL", machine.succeed(f"journalctl -u {api} -o cat | grep 'still open' | tail -1"))
          # Once the holder is gone, the next start resets the device.
          machine.succeed("systemctl stop fixture-holder")
          machine.succeed(f"systemctl start {api} forgejo-podman-runner.service")
          wait_units()
          assert zram() == device
          made_by_running_api()
          assert run("after-holder", "/bin/busybox true", "-v holder-data:/data")[0] == 0
          machine.succeed(f"{podman} rm after-holder && {podman} volume rm holder-data")

      with subtest("the API refuses to start unless the volumes are ext4 on its own zram device"):
          machine.succeed(f"systemctl stop forgejo-podman-runner.service {api}")
          # Something else mounted there.
          machine.succeed(f"umount {vmount} && mount -t tmpfs fixture-tmpfs {vmount}")
          machine.fail(f"systemctl start {api}")
          assert "holds fixture-tmpfs, not this unit's zram device" in machine.succeed(f"journalctl -u {api} -o cat")
          machine.succeed(f"umount {vmount} && systemctl reset-failed {api}")
          # A link that would put the volumes on disk.
          machine.succeed(f"rmdir {vmount} && ln -s {parent} {vmount}")
          machine.fail(f"systemctl start {api}")
          assert f"{vmount} is a symbolic link" in machine.succeed(f"journalctl -u {api} -o cat")
          machine.fail(f"test -e {disk_volumes}")
          machine.succeed(f"rm {vmount} && systemctl reset-failed {api}")
          machine.succeed(f"systemctl start {api} forgejo-podman-runner.service")
          wait_units()
          zram()
          assert run("after-refusal", "/bin/busybox true", "-v refusal-data:/data")[0] == 0
          machine.succeed(f"{podman} rm after-refusal && {podman} volume rm refusal-data")

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

      with subtest("containers a finished job left behind reset the scratch at the next quiet check"):
          # A cancelled job's service keeps running; its build container stopped.
          machine.succeed(f"{podman} create --network none --name orphan-service scratch-fixture:local /bin/busybox sleep 600")
          machine.succeed(f"{podman} start orphan-service")
          machine.succeed(f"{podman} create --network none --name orphan-build scratch-fixture:local")
          machine.succeed(f"systemctl start {reset}", timeout=600)
          journal = machine.succeed(f"journalctl -u {reset} -o cat")
          assert "reset due=leftover_containers" in journal, journal
          wait_units()
          assert machine.succeed(f"{podman} ps -aq").strip() == ""
          # Only the scratch was reset: the images stay on disk.
          assert machine.succeed(f"{podman} images -q").strip() != ""
          # With nothing left behind, the next check changes nothing.
          machine.succeed(f"systemctl start {reset}", timeout=600)
          last = machine.succeed(f"journalctl -u {reset} -o cat | grep -E '^(skipped|reset) ' | tail -1")
          assert "reason=not_due" in last and "leftover_containers=0" in last, last

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
          # As on a host that never had them: no volume filesystem in RAM.
          machine.succeed(f"umount {vmount}")
          machine.succeed("${nodes.machine.system.build.toplevel}/bin/switch-to-configuration test", timeout=300)
          assert machine.succeed(f"systemctl show -p MainPID --value {api}").strip() == pid
          machine.succeed(f"mountpoint -q {scratch}")
          machine.succeed(f"{podman} info >/dev/null")
          # The reset now knows the volume filesystem, which the running API,
          # started before the deploy, does not use: it leaves the API and
          # the runners alone.
          machine.succeed(f"systemctl start {reset}", timeout=600)
          last = machine.succeed(f"journalctl -u {reset} -o cat | grep -E '^(skipped|reset) ' | tail -1")
          assert "reason=not_due" in last and "volumes=not_in_use" in last and "volume_state" not in last, last
          assert machine.succeed(f"systemctl show -p MainPID --value {api}").strip() == pid
          machine.fail("ls /run/nixfleet-runners/paused/* 2>/dev/null")
          # The owner's restart moves the volumes into RAM.
          machine.succeed(f"systemctl restart {api} && systemctl start forgejo-podman-runner.service")
          wait_units()
          zram()
          made_by_running_api()
          # The rolled-back store held containers, so this start moved it
          # aside as a store from before scratch, images included.
          machine.succeed(f"{podman} load < ${fixtureImage}")
          assert run("after-deploy", "/bin/busybox true", "-v deploy-data:/data")[0] == 0
          machine.succeed(f"{podman} rm after-deploy && {podman} volume rm deploy-data")
    '';
  }
