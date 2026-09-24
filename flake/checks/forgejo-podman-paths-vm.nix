# Disposable, unregistered Forgejo executor qualification for a rootless Podman
# Docker-compatible API. Run explicitly; this is not an ordinary flake check.
# Docker buildx's default cgroup parent escapes the delegated service and is
# rejected. Both builders below opt into that service as their cgroup parent.
# Ordinary workflows must select the configured builder explicitly.
{
  pkgs,
  productionModule ? false,
  runnerPackage ? pkgs.forgejo-runner,
}: let
  scope =
    if productionModule
    then "forgejobuilds.slice/forgejo-runner-podman.service"
    else "podmancanary.slice/podman-ci-api.service";
  busybox = pkgs.pkgsStatic.busybox;
  buildDockerfile = marker:
    pkgs.writeText "Dockerfile.podman-${marker}" ''
      FROM scratch
      COPY busybox /bin/busybox
      RUN ["/bin/busybox", "sh", "-c", "i=0; while [ $i -lt 600 ]; do i=$((i + 1)); printf '%s\\n' $i > /${marker}-build-progress; /bin/busybox sleep 1; done"]
    '';
  finiteDockerfile = pkgs.writeText "Dockerfile.podman-finite" ''
    FROM scratch
    COPY busybox /bin/busybox
    RUN ["/bin/busybox", "sh", "-c", "echo finite-build-ok > /finite-build"]
  '';
  actionScript = pkgs.writeText "podman-action.sh" ''
    set -eu
    docker version --format '{{.Server.Version}}'
    docker run --detach --name podman-nested runner-fixture:local /bin/busybox sh -c 'while :; do :; done'
    # An API caller may request a different parent. It must not escape the
    # system service's delegated cgroup or its ancestor resource limits.
    if docker run --detach --name podman-parent-override --cgroup-parent=qualification-override \
      runner-fixture:local /bin/busybox sh -c 'while :; do :; done'; then
      echo relative-override-accepted
    else
      echo relative-override-rejected
    fi
    mkdir -p /tmp/plain-build /tmp/buildx-build
    cp /bin/busybox /tmp/plain-build/busybox
    cp /Dockerfile /tmp/plain-build/Dockerfile
    cp /Dockerfile.finite /tmp/plain-build/Dockerfile.finite
    if docker buildx create --name action-default --driver docker-container \
      --driver-opt image=buildkit-fixture:local \
      --driver-opt cgroup-parent=/${scope} \
      --driver-opt default-load=true \
      --use >/tmp/default-builder.log 2>&1 &&
      timeout 45 docker buildx inspect --bootstrap >>/tmp/default-builder.log 2>&1; then
      if BUILDX_BUILDER=action-default docker build --progress=plain -t finite-fixture:local \
        -f /tmp/plain-build/Dockerfile.finite /tmp/plain-build >/tmp/default-build.log 2>&1 &&
        test "$(docker run --rm finite-fixture:local /bin/busybox cat /finite-build)" = finite-build-ok; then
        echo default-finite-build-succeeded
      else
        cat /tmp/default-build.log
        echo default-finite-build-failed
      fi
    else
      cat /tmp/default-builder.log
      echo default-builder-failed
    fi
    (DOCKER_BUILDKIT=0 docker build /tmp/plain-build >/tmp/legacy-build.log 2>&1 ||
      { cat /tmp/legacy-build.log; echo legacy-build-failed; }) &
    echo action-ready
    # Keep the action available while the VM inspects Docker API workers.
    sleep 600
  '';
  runnerFixture = pkgs.dockerTools.buildLayeredImage {
    name = "runner-fixture";
    tag = "local";
    contents = [
      pkgs.docker
      pkgs.docker-buildx
      busybox
    ];
    config = {
      Cmd = [
        "/bin/sleep"
        "600"
      ];
      Env = ["PATH=/bin:/usr/bin"];
    };
  };
  actionFixture = pkgs.dockerTools.buildLayeredImage {
    name = "action-fixture";
    tag = "local";
    fromImage = runnerFixture;
    maxLayers = 125;
    extraCommands = ''
      cp ${actionScript} action.sh
      cp ${buildDockerfile "legacy"} Dockerfile
      cp ${finiteDockerfile} Dockerfile.finite
    '';
    config = {
      Entrypoint = [
        "/bin/sh"
        "/action.sh"
      ];
      Env = ["PATH=/bin:/usr/bin"];
    };
  };
  buildkitFixture = pkgs.dockerTools.buildLayeredImage {
    name = "buildkit-fixture";
    tag = "local";
    contents = [
      pkgs.buildkit
      busybox
      pkgs.runc
    ];
    extraCommands = "mkdir -m 1777 tmp";
    config = {
      Entrypoint = ["${pkgs.buildkit}/bin/buildkitd"];
      Env = ["PATH=/bin:/usr/bin"];
    };
  };
  hostFixture = pkgs.dockerTools.buildLayeredImage {
    name = "host-fixture";
    tag = "local";
    contents = [busybox];
    config.Cmd = [
      "/bin/sleep"
      "600"
    ];
  };
  workflow = pkgs.writeText "podman-qualification.yml" ''
    name: Podman API qualification
    on: push
    jobs:
      qualify:
        runs-on: fixture
        services:
          qualification-service:
            image: runner-fixture:local
        steps:
          - name: job API socket
            run: |
              docker version --format '{{.Server.Version}}'
              stat -c 'job_socket=%a:%u:%g' /var/run/docker.sock
              echo job-socket-ready
          - name: Docker action API socket
            uses: docker://action-fixture:local
  '';
in
  pkgs.testers.runNixOSTest {
    name =
      "forgejo-rootless-podman-executor-paths"
      + (
        if productionModule
        then "-module"
        else ""
      );
    nodes.machine = {lib, ...}:
      if productionModule
      then {
        imports = [../../modules/nixos/services/forgejo-actions-runner];
        options.sops.secrets = lib.mkOption {
          type = lib.types.attrs;
          default = {};
        };
        config = {
          system.stateVersion = "25.11";
          virtualisation = {
            memorySize = 3072;
            cores = 2;
            diskSize = 6144;
            docker.enable = true;
          };
          services.forgejo-actions-runner = {
            enable = true;
            labels = ["docker-fixture:docker://example.invalid/unused:local"];
            secretsFile = pkgs.writeText "unused-dummy-secrets" "dummy";
            isolatedDocker.enable = true;
            ioPressureGuard.admissionControl.enable = true;
            resourcePolicy = {
              memoryHigh = "1200M";
              memoryMax = "1536M";
            };
            podmanCanary = {
              enable = true;
              package = runnerPackage;
              registrationTokenFile = "/run/unused-registration";
              labels = ["podman-fixture:docker://example.invalid/unused:local"];
            };
          };
          systemd.services.forgejo-actions-runner = {
            preStart = lib.mkForce "";
            script = lib.mkForce "exec ${pkgs.coreutils}/bin/sleep infinity";
          };
          systemd.services.forgejo-podman-runner = {
            preStart = lib.mkForce "";
            script = lib.mkForce "exec ${pkgs.coreutils}/bin/sleep infinity";
          };
          systemd.services.fixture-pressure-init = {
            serviceConfig.Type = "oneshot";
            script = "echo 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0' > /run/fixture-pressure";
          };
          systemd.services.forgejo-runner-io-pressure-guard = {
            requires = ["fixture-pressure-init.service"];
            after = ["fixture-pressure-init.service"];
            environment.PRESSURE_FILE = "/run/fixture-pressure";
          };
          environment.systemPackages = [pkgs.docker pkgs.docker-buildx pkgs.forgejo-runner pkgs.git pkgs.podman];
        };
      }
      else {
        system.stateVersion = "25.11";
        virtualisation = {
          memorySize = 3072;
          cores = 2;
          diskSize = 6144;
          docker.enable = true;
          podman.enable = true;
        };
        users.groups.podman-ci = {};
        users.users.podman-ci-builder = {
          isSystemUser = true;
          group = "podman-ci";
          home = "/var/lib/podman-ci";
          autoSubUidGidRange = true;
        };
        users.users.podman-ci-runner = {
          isSystemUser = true;
          group = "podman-ci";
          home = "/var/lib/podman-ci-runner";
        };
        systemd.tmpfiles.rules = ["d /var/lib/podman-ci-runner 0750 podman-ci-runner podman-ci -"];
        systemd.slices.podmancanary.sliceConfig = {
          CPUQuota = "100%";
          MemoryHigh = "1200M";
          MemoryMax = "1536M";
        };
        systemd.sockets.podman-ci-api = {
          wantedBy = [];
          socketConfig = {
            ListenStream = "/run/podman-ci.sock";
            SocketUser = "podman-ci-builder";
            SocketGroup = "podman-ci";
            SocketMode = "0660";
          };
        };
        systemd.services.podman-ci-api = {
          description = "Disposable delegated rootless Podman CI API";
          wantedBy = [];
          path = [
            pkgs.podman
            pkgs.slirp4netns
            pkgs.fuse-overlayfs
            "/run/wrappers"
          ];
          environment = {
            HOME = "/var/lib/podman-ci";
            XDG_RUNTIME_DIR = "/run/podman-ci";
            # Netavark launches aardvark-dns directly when systemd-run is absent
            # from PATH. A user scope would escape this system service's slice.
            PATH = lib.mkForce (
              lib.makeBinPath [
                pkgs.podman
                pkgs.slirp4netns
                pkgs.fuse-overlayfs
                pkgs.passt
                pkgs.coreutils
                pkgs.util-linux
              ]
              + ":/run/wrappers/bin"
            );
          };
          serviceConfig = {
            Type = "exec";
            User = "podman-ci-builder";
            Group = "podman-ci";
            StateDirectory = "podman-ci";
            StateDirectoryMode = "0700";
            RuntimeDirectory = "podman-ci";
            RuntimeDirectoryMode = "0770";
            UMask = "0007";
            Slice = "podmancanary.slice";
            Delegate = true;
            KillMode = "control-group";
            OOMPolicy = "continue";
            TimeoutStopSec = "30s";
            ExecStart = "${pkgs.podman}/bin/podman --remote=false --cgroup-manager=cgroupfs --storage-driver=overlay --root=/var/lib/podman-ci/storage --runroot=/run/podman-ci/storage system service --time=0";
          };
        };
        environment.systemPackages = [
          pkgs.docker
          pkgs.docker-buildx
          pkgs.forgejo-runner
          pkgs.git
          pkgs.podman
        ];
      };
    testScript =
      builtins.replaceStrings
      (
        if productionModule
        then ["podmancanary.slice" "podman-ci-api" "/run/podman-ci.sock" "podman-ci-builder" "podman-ci-runner" "podman-ci"]
        else []
      )
      (
        if productionModule
        then ["forgejobuilds.slice" "forgejo-runner-podman" "/run/forgejo-podman/podman.sock" "forgejo-podman-builder" "forgejo-podman-runner" "forgejo-podman"]
        else []
      ) ''
        import time

        start_all()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("systemctl start podman-ci-api.socket", timeout=30)
        machine.wait_until_succeeds("test -S /run/podman-ci.sock", timeout=30)
        socket_metadata = machine.succeed("stat -c '%a:%U:%G' /run/podman-ci.sock").strip()
        assert socket_metadata in ("660:podman-ci-builder:podman-ci", "770:podman-ci-builder:podman-ci"), socket_metadata
        machine.succeed("runuser -u podman-ci-runner -- docker -H unix:///run/podman-ci.sock version", timeout=30)
        machine.wait_for_unit("podman-ci-api.service")
        assert machine.succeed("systemctl show podmancanary.slice --property=CPUQuotaPerSecUSec --value").strip() == "1s"
        assert machine.succeed("cat /sys/fs/cgroup/podmancanary.slice/memory.max").strip() == str(1536 * 1024 * 1024)
        assert machine.succeed("cat /sys/fs/cgroup/podmancanary.slice/memory.high").strip() == str(1200 * 1024 * 1024)
        api = "docker -H unix:///run/podman-ci.sock"
        machine.succeed(f"{api} version", timeout=30)
        assert machine.succeed(api + " info --format '{{.Driver}}'").strip() == "overlay"
        assert machine.succeed("systemctl show podman-ci-api.service --property=User --value").strip() == "podman-ci-builder"
        machine.succeed(f"{api} load < ${runnerFixture}", timeout=120)
        machine.succeed(f"{api} load < ${actionFixture}", timeout=120)
        machine.succeed(f"{api} load < ${buildkitFixture}", timeout=120)
        machine.succeed("docker load < ${hostFixture}")

        machine.succeed("install -d -o podman-ci-runner -g podman-ci -m 0770 /run/podman-qualification")
        machine.succeed("install -d -o podman-ci-runner -g podman-ci -m 0750 /run/podman-qualification/.forgejo/workflows")
        machine.succeed("install -o podman-ci-runner -g podman-ci -m 0640 ${workflow} /run/podman-qualification/.forgejo/workflows/qualification.yml")
        machine.succeed("docker run --detach --name host-application host-fixture:local /bin/busybox sh -c 'while :; do :; done'")
        machine.succeed("docker run --detach --name host-manual-pause host-fixture:local")
        machine.succeed("docker pause host-manual-pause")

        machine.succeed("systemd-run --unit=podman-qualification-runner --uid=podman-ci-runner --gid=podman-ci --working-directory=/run/podman-qualification --setenv=HOME=/var/lib/podman-ci-runner --setenv=DOCKER_HOST=unix:///run/podman-ci.sock ${runnerPackage}/bin/forgejo-runner exec --no-recurse --container-daemon-socket=unix:///run/podman-ci.sock --workflows .forgejo/workflows/qualification.yml --image runner-fixture:local push")
        machine.wait_until_succeeds("journalctl -u podman-qualification-runner.service --no-pager | grep -q action-ready || ! systemctl is-active --quiet podman-qualification-runner.service", timeout=120)
        runner_log = machine.succeed("journalctl -u podman-qualification-runner.service --no-pager")
        assert "action-ready" in runner_log, runner_log
        assert "job-socket-ready" in runner_log, runner_log

        ids = machine.succeed(f"{api} ps --quiet").split()
        assert len(ids) >= 4, machine.succeed(f"{api} ps --all")
        api_pids = []
        socket_mounts = 0
        for container_id in ids:
            pid = machine.succeed(f"{api} inspect --format '{{{{.State.Pid}}}}' {container_id}").strip()
            cgroup = machine.succeed(f"cat /proc/{pid}/cgroup")
            assert "podmancanary.slice/podman-ci-api.service" in cgroup, (container_id, cgroup)
            api_pids.append(pid)
            mounts = machine.succeed(api + " inspect --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}' " + container_id)
            if "/var/run/docker.sock" in mounts:
                socket_mounts += 1
                assert "/run/podman-ci.sock /var/run/docker.sock" in mounts, mounts
        assert socket_mounts >= 2
        for name in ["podman-nested"]:
            pid = machine.succeed(f"{api} inspect --format '{{{{.State.Pid}}}}' {name}").strip()
            assert "podmancanary.slice/podman-ci-api.service" in machine.succeed(f"cat /proc/{pid}/cgroup")
        if "relative-override-accepted" in runner_log:
            pid = machine.succeed(f"{api} inspect --format '{{{{.State.Pid}}}}' podman-parent-override").strip()
            assert "podmancanary.slice/podman-ci-api.service" in machine.succeed(f"cat /proc/{pid}/cgroup")
        else:
            assert "relative-override-rejected" in runner_log, runner_log
        absolute_override = machine.execute(f"{api} run --detach --name podman-absolute-override --cgroup-parent=/ runner-fixture:local /bin/busybox sleep 600")
        print("ABSOLUTE_CGROUP_PARENT", absolute_override)
        if absolute_override[0] == 0:
            absolute_pid = machine.succeed(f"{api} inspect --format '{{{{.State.Pid}}}}' podman-absolute-override").strip()
            assert "podmancanary.slice/podman-ci-api.service" in machine.succeed(f"cat /proc/{absolute_pid}/cgroup")

        machine.wait_until_succeeds("pgrep -f '[l]egacy-build-progress' || journalctl -u podman-qualification-runner.service --no-pager | grep -q legacy-build-failed", timeout=60)
        legacy_log = machine.succeed("journalctl -u podman-qualification-runner.service --no-pager")
        print("DEFAULT_BUILD", "finite success" if "default-finite-build-succeeded" in legacy_log else "failed or builder unsupported")
        legacy_worker = "legacy-build-failed" not in legacy_log
        if legacy_worker:
            worker_pid = machine.succeed("pgrep -f '[l]egacy-build-progress' | head -n1").strip()
            assert "podmancanary.slice/podman-ci-api.service" in machine.succeed(f"cat /proc/{worker_pid}/cgroup")
            assert machine.succeed(f"cat /proc/{worker_pid}/comm").strip() in ("busybox", "sh")
            machine.wait_until_succeeds(f"test -s /proc/{worker_pid}/root/legacy-build-progress", timeout=20)
        else:
            print("LEGACY_BUILD_UNSUPPORTED", legacy_log)

        # This is the real Docker buildx plugin with its docker-container driver.
        # Record compatibility separately from the required plain build path.
        buildx = machine.execute(f"{api} buildx create --name podman-qualification --driver docker-container --driver-opt image=buildkit-fixture:local --driver-opt cgroup-parent=/podmancanary.slice/podman-ci-api.service --use")
        print("BUILDX_CREATE", buildx)
        buildx_worker = False
        if buildx[0] == 0:
            boot = machine.execute(f"{api} buildx inspect --bootstrap", timeout=90)
            print("BUILDX_BOOTSTRAP", boot)
            if boot[0] == 0:
                buildkit_id = machine.succeed(f"{api} ps --quiet --filter name=buildx_buildkit_podman-qualification").strip()
                assert buildkit_id, machine.succeed(f"{api} ps --all")
                buildkit_pid = machine.succeed(f"{api} inspect --format '{{{{.State.Pid}}}}' {buildkit_id}").strip()
                assert "podmancanary.slice/podman-ci-api.service" in machine.succeed(f"cat /proc/{buildkit_pid}/cgroup")
                api_pids.append(buildkit_pid)
                machine.succeed("install -d /run/podman-buildx; cp ${busybox}/bin/busybox /run/podman-buildx/busybox; cp ${buildDockerfile "buildx"} /run/podman-buildx/Dockerfile")
                machine.succeed("systemd-run --unit=podman-buildx-build --setenv=DOCKER_HOST=unix:///run/podman-ci.sock ${pkgs.docker}/bin/docker buildx build --builder podman-qualification --progress=plain /run/podman-buildx")
                machine.wait_until_succeeds("pgrep -f '[b]uildx-build-progress' || ! systemctl is-active --quiet podman-buildx-build.service", timeout=90)
                buildx_log = machine.succeed("journalctl -u podman-buildx-build.service --no-pager")
                if machine.execute("pgrep -f '[b]uildx-build-progress'")[0] == 0:
                    buildx_pid = machine.succeed("pgrep -f '[b]uildx-build-progress' | head -n1").strip()
                    assert "podmancanary.slice/podman-ci-api.service" in machine.succeed(f"cat /proc/{buildx_pid}/cgroup")
                    machine.wait_until_succeeds(f"test -s /proc/{buildx_pid}/root/buildx-build-progress", timeout=20)
                    api_pids.append(buildx_pid)
                    buildx_worker = True
                    print("BUILDX_WORKER_CONTAINED", buildx_pid)
                else:
                    print("BUILDX_UNSUPPORTED build failed before RUN", buildx_log)
            else:
                print("BUILDX_UNSUPPORTED bootstrap failed")
        else:
            print("BUILDX_UNSUPPORTED create failed")

        builder_pids = machine.succeed("pgrep -u podman-ci-builder").split()
        assert builder_pids
        for pid in builder_pids:
            status, cgroup = machine.execute(f"cat /proc/{pid}/cgroup")
            if status == 0:
                assert "podmancanary.slice/podman-ci-api.service" in cgroup, (pid, cgroup)

        host_pid = machine.succeed("docker inspect --format '{{.State.Pid}}' host-application").strip()
        assert "podmancanary.slice" not in machine.succeed(f"cat /proc/{host_pid}/cgroup")
        assert machine.succeed("docker inspect --format '{{.State.Paused}}' host-manual-pause").strip() == "true"

        if legacy_worker and buildx_worker:
            machine.succeed("systemctl freeze podmancanary.slice", timeout=30)
            machine.wait_until_succeeds("test $(systemctl show podmancanary.slice -p FreezerState --value) = frozen", timeout=30)
            legacy_before = int(machine.succeed(f"cat /proc/{worker_pid}/root/legacy-build-progress"))
            buildx_before = int(machine.succeed(f"cat /proc/{buildx_pid}/root/buildx-build-progress"))
            host_before = int(machine.succeed(f"awk '{{print $14 + $15}}' /proc/{host_pid}/stat"))
            machine.sleep(3)
            assert int(machine.succeed(f"cat /proc/{worker_pid}/root/legacy-build-progress")) == legacy_before
            assert int(machine.succeed(f"cat /proc/{buildx_pid}/root/buildx-build-progress")) == buildx_before
            assert int(machine.succeed(f"awk '{{print $14 + $15}}' /proc/{host_pid}/stat")) > host_before
            machine.succeed("systemctl thaw podmancanary.slice", timeout=30)
            machine.wait_until_succeeds(f"test $(cat /proc/{worker_pid}/root/legacy-build-progress) -gt {legacy_before}", timeout=30)
            machine.wait_until_succeeds(f"test $(cat /proc/{buildx_pid}/root/buildx-build-progress) -gt {buildx_before}", timeout=30)

        # Cancel the real executor while its action is still running. Native
        # job/service/action containers must be removed without stopping the API.
        # User-created nested containers/builders remain a separate teardown path.
        native_ids = machine.succeed(f"{api} ps --all --quiet --filter name=FORGEJO-ACTIONS-TASK").split()
        assert len(native_ids) >= 3
        machine.succeed("systemctl kill --kill-whom=main --signal=INT podman-qualification-runner.service")
        machine.wait_until_succeeds("test $(systemctl show podman-qualification-runner.service -p ActiveState --value) = inactive || test $(systemctl show podman-qualification-runner.service -p ActiveState --value) = failed", timeout=60)
        for container_id in native_ids:
            machine.wait_until_fails(f"{api} inspect {container_id} >/dev/null 2>&1", timeout=30)
        machine.succeed(f"{api} version", timeout=15)
        machine.succeed("docker info >/dev/null", timeout=15)
        stop_started = time.monotonic()
        machine.succeed("systemctl stop podman-ci-api.socket", timeout=30)
        machine.succeed("systemctl stop podman-ci-api.service", timeout=60)
        if legacy_worker:
            machine.wait_until_fails("test -e /proc/" + worker_pid, timeout=30)
        for pid in api_pids:
            machine.wait_until_fails("test -e /proc/" + pid, timeout=30)
        machine.wait_until_fails("pgrep -u podman-ci-builder", timeout=30)
        machine.wait_until_succeeds("test ! -d /sys/fs/cgroup/podmancanary.slice/podman-ci-api.service || test \"$(awk '$1 == \"populated\" {print $2}' /sys/fs/cgroup/podmancanary.slice/podman-ci-api.service/cgroup.events)\" = 0", timeout=30)
        print("CANARY_STOP_SECONDS", time.monotonic() - stop_started)
        assert machine.succeed("docker inspect --format '{{.State.Running}}' host-application").strip() == "true"
        machine.succeed("docker unpause host-manual-pause")
        machine.succeed("docker rm --force host-manual-pause host-application")
        assert "default-finite-build-succeeded" in legacy_log, "default Docker build with local builder did not finish"
        assert legacy_worker, "Podman did not run a plain Docker API build worker"
        assert buildx_worker, "real Docker buildx docker-container RUN worker was not proven"
      '';
  }
