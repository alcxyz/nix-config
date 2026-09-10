# Qualification fixture; deliberately excluded from ordinary flake checks.
#
# This uses Forgejo Runner's real local executor and a service container without
# registering a runner or contacting Forgejo. Local execution needs an explicit
# container-daemon socket because its command-line default is the host socket;
# daemon mode gets this path from the generated runner configuration.
{pkgs}: let
  buildxDockerfile = pkgs.writeText "Dockerfile.buildx" ''
    FROM scratch
    COPY busybox /bin/busybox
    RUN ["/bin/busybox", "sh", "-c", "i=0; while [ $i -lt 600 ]; do i=$((i + 1)); printf '%s\\n' $i > /qualification-build-worker-progress; /bin/busybox sleep 1; done"]
  '';
  actionEntrypoint = pkgs.writeText "action-entrypoint.sh" ''
    set -eu

    docker version --format '{{.Server.Version}}'
    stat -c 'action_socket=%a:%u:%g' /var/run/docker.sock
    docker run --detach --name socket-child runner-fixture:local \
      /bin/busybox sh -c 'while :; do :; done'

    mkdir -p /tmp/buildx-context
    cp /bin/busybox /tmp/buildx-context/busybox
    cp /Dockerfile.buildx /tmp/buildx-context/Dockerfile
    docker buildx create --name qualification --driver docker-container \
      --driver-opt image=buildkit-fixture:local --use
    docker buildx inspect --bootstrap
    (docker buildx build --builder qualification --progress=plain \
      /tmp/buildx-context >/tmp/buildx.log 2>&1 || {
        cat /tmp/buildx.log
        echo build-failed
      }) &

    echo action-ready
    sleep 600
  '';
  runnerFixture = pkgs.dockerTools.buildLayeredImage {
    name = "runner-fixture";
    tag = "local";
    contents = [
      pkgs.docker
      pkgs.docker-buildx
      pkgs.pkgsStatic.busybox
    ];
    config = {
      Cmd = ["/bin/sleep" "600"];
      Env = ["PATH=/bin:/usr/bin"];
    };
  };
  actionFixture = pkgs.dockerTools.buildLayeredImage {
    name = "action-fixture";
    tag = "local";
    fromImage = runnerFixture;
    maxLayers = 125;
    extraCommands = ''
      cp ${actionEntrypoint} action-entrypoint.sh
      cp ${buildxDockerfile} Dockerfile.buildx
    '';
    config = {
      Entrypoint = ["/bin/sh" "/action-entrypoint.sh"];
      Env = ["PATH=/bin:/usr/bin"];
    };
  };
  buildkitFixture = pkgs.dockerTools.buildLayeredImage {
    name = "buildkit-fixture";
    tag = "local";
    contents = [
      pkgs.buildkit
      pkgs.pkgsStatic.busybox
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
    contents = [pkgs.pkgsStatic.busybox];
    config.Cmd = ["/bin/sleep" "600"];
  };
  workflow = pkgs.writeText "qualification.yml" ''
    name: isolated Docker executor socket qualification
    on: push
    jobs:
      qualify:
        runs-on: fixture
        services:
          qualification-service:
            image: runner-fixture:local
        steps:
          - name: socket-mounted job shell
            run: |
              printf 'job_uid='
              id -u
              stat -c 'job_socket=%a:%u:%g' /var/run/docker.sock
              printf 'job_uid_map='
              cat /proc/self/uid_map
              printf 'job_gid_map='
              cat /proc/self/gid_map
              docker version --format '{{.Server.Version}}'
              echo job-socket-ready
          - name: socket-mounted Docker action
            uses: docker://action-fixture:local
  '';
in
  pkgs.testers.runNixOSTest {
    name = "forgejo-rootless-daemon-executor-paths";
    nodes.machine = {lib, ...}: {
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
          labels = ["fixture:docker://runner-fixture:local"];
          secretsFile = pkgs.writeText "unused-dummy-secrets" "dummy";
          isolatedDocker.enable = true;
        };
        # Exercise only the local executor; never register or contact Forgejo.
        systemd.services.forgejo-actions-runner.wantedBy = lib.mkForce [];
        systemd.services.forgejo-runner-io-pressure-guard.environment = {
          PRESSURE_FILE = "/run/fixture-pressure";
          SAMPLE_SECONDS = lib.mkForce "1";
          HIGH_SAMPLES_REQUIRED = lib.mkForce "2";
          LOW_SAMPLES_REQUIRED = lib.mkForce "2";
        };
        environment.systemPackages = [
          pkgs.docker
          pkgs.forgejo-runner
          pkgs.git
        ];
      };
    };
    testScript = ''
      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.succeed("printf 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0\\n' > /run/fixture-pressure")
      machine.succeed("systemctl start forgejo-runner-docker.service", timeout=150)
      machine.wait_for_unit("forgejo-runner-docker.service")

      docker = "docker -H unix:///run/forgejo-docker/docker.sock"
      print(machine.succeed("id forgejo-builder; id forgejo-runner; stat -c 'host_socket=%a:%u:%g' /run/forgejo-docker/docker.sock"))
      machine.succeed(f"{docker} load < ${runnerFixture}")
      machine.succeed(f"{docker} load < ${actionFixture}")
      machine.succeed(f"{docker} load < ${buildkitFixture}")
      machine.succeed("docker load < ${hostFixture}")

      machine.succeed("install -d -o forgejo-runner -g forgejo-runner -m 0770 /run/forgejo-qualification")
      machine.succeed("install -d -o forgejo-runner -g forgejo-runner -m 0750 /run/forgejo-qualification/.forgejo/workflows")
      machine.succeed("install -o forgejo-runner -g forgejo-runner -m 0640 ${workflow} /run/forgejo-qualification/.forgejo/workflows/qualification.yml")
      machine.succeed("docker run --detach --name host-application --mount type=bind,source=/run/forgejo-qualification,target=/qualification host-fixture:local /bin/sh -c 'i=0; while [ \"$i\" -lt 600 ]; do i=$((i + 1)); printf \"%s\\n\" \"$i\" > /qualification/host-application.progress; sleep 1; done'")
      machine.succeed("docker run --detach --name host-manual-pause host-fixture:local")
      machine.succeed("docker pause host-manual-pause")

      machine.succeed("systemd-run --unit=qualification-runner --uid=forgejo-runner --gid=forgejo-runner --working-directory=/run/forgejo-qualification --setenv=HOME=/var/lib/forgejo/runner --setenv=DOCKER_HOST=unix:///run/forgejo-docker/docker.sock ${pkgs.forgejo-runner}/bin/forgejo-runner exec --no-recurse --container-daemon-socket=unix:///run/forgejo-docker/docker.sock --workflows .forgejo/workflows/qualification.yml --image runner-fixture:local push")
      machine.wait_until_succeeds("journalctl -u qualification-runner.service --no-pager | grep -q action-ready || ! systemctl is-active --quiet qualification-runner.service", timeout=120)
      action_log = machine.succeed("journalctl -u qualification-runner.service --no-pager")
      assert "action-ready" in action_log, action_log

      job_id = machine.succeed(f"{docker} ps --quiet --filter 'name=JOB-qualify$'").strip()
      assert job_id
      socket_mount = machine.succeed(docker + " inspect --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}' " + job_id)
      assert "/run/forgejo-docker/docker.sock /var/run/docker.sock" in socket_mount
      assert "/var/run/docker.sock /var/run/docker.sock" not in socket_mount

      container_ids = machine.succeed(f"{docker} ps --quiet").split()
      assert len(container_ids) >= 5, machine.succeed(f"{docker} ps --all")
      socket_mount_count = 0
      for container_id in container_ids:
          pid = machine.succeed(f"{docker} inspect --format '{{{{.State.Pid}}}}' {container_id}").strip()
          assert "forgejobuilds.slice/forgejo-runner-docker.service" in machine.succeed(f"cat /proc/{pid}/cgroup")
          mounts = machine.succeed(docker + " inspect --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}' " + container_id)
          if "/var/run/docker.sock" in mounts:
              socket_mount_count += 1
              assert "/run/forgejo-docker/docker.sock /var/run/docker.sock" in mounts
              assert "/var/run/docker.sock /var/run/docker.sock" not in mounts
      assert socket_mount_count >= 2

      buildkit_id = machine.succeed(f"{docker} ps --quiet --filter name=buildx_buildkit_qualification").strip()
      assert buildkit_id
      child_id = machine.succeed(f"{docker} ps --quiet --filter name=socket-child").strip()
      child_pid = machine.succeed(f"{docker} inspect --format '{{{{.State.Pid}}}}' {child_id}").strip()
      assert machine.succeed(f"cat /proc/{child_pid}/comm").strip() in ("busybox", "sh")
      machine.wait_until_succeeds("pgrep -f '[q]ualification-build-worker-progress' || journalctl -u qualification-runner.service --no-pager | grep -q build-failed", timeout=60)
      worker_log = machine.succeed("journalctl -u qualification-runner.service --no-pager")
      assert "build-failed" not in worker_log, worker_log
      build_worker_pid = machine.succeed("pgrep -f '[q]ualification-build-worker-progress' | head -n1").strip()
      assert "forgejobuilds.slice/forgejo-runner-docker.service" in machine.succeed(f"cat /proc/{build_worker_pid}/cgroup")
      machine.wait_until_succeeds(f"test -s /proc/{build_worker_pid}/root/qualification-build-worker-progress", timeout=30)
      machine.wait_until_succeeds("test -s /run/forgejo-qualification/host-application.progress", timeout=30)

      child_initial = int(machine.succeed(f"awk '{{print $14 + $15}}' /proc/{child_pid}/stat"))
      worker_initial = int(machine.succeed(f"cat /proc/{build_worker_pid}/root/qualification-build-worker-progress"))
      machine.sleep(2)
      assert int(machine.succeed(f"awk '{{print $14 + $15}}' /proc/{child_pid}/stat")) > child_initial
      assert int(machine.succeed(f"cat /proc/{build_worker_pid}/root/qualification-build-worker-progress")) > worker_initial

      machine.succeed("printf 'full avg10=99.00 avg60=99.00 avg300=99.00 total=1\\n' > /run/fixture-pressure")
      machine.wait_until_succeeds("test $(systemctl show forgejobuilds.slice -p FreezerState --value) = frozen", timeout=30)
      child_frozen = int(machine.succeed(f"awk '{{print $14 + $15}}' /proc/{child_pid}/stat"))
      worker_frozen = int(machine.succeed(f"cat /proc/{build_worker_pid}/root/qualification-build-worker-progress"))
      host_frozen = int(machine.succeed("cat /run/forgejo-qualification/host-application.progress"))
      machine.sleep(3)
      assert int(machine.succeed(f"awk '{{print $14 + $15}}' /proc/{child_pid}/stat")) == child_frozen
      assert int(machine.succeed(f"cat /proc/{build_worker_pid}/root/qualification-build-worker-progress")) == worker_frozen
      assert int(machine.succeed("cat /run/forgejo-qualification/host-application.progress")) > host_frozen

      machine.succeed("printf 'full avg10=0.00 avg60=0.00 avg300=0.00 total=1\\n' > /run/fixture-pressure")
      machine.wait_until_succeeds("test $(systemctl show forgejobuilds.slice -p FreezerState --value) = running", timeout=30)
      machine.wait_until_succeeds(f"test $(awk '{{print $14 + $15}}' /proc/{child_pid}/stat) -gt {child_frozen}", timeout=30)
      machine.wait_until_succeeds(f"test $(cat /proc/{build_worker_pid}/root/qualification-build-worker-progress) -gt {worker_frozen}", timeout=30)
      assert machine.succeed("docker inspect --format '{{.State.Paused}}' host-manual-pause").strip() == "true"

      output = machine.succeed("journalctl -u qualification-runner.service --no-pager")
      print(output)
      assert "job_uid=0" in output
      assert "job_socket=1660:0:0" in output
      assert "job_uid_map=         0        998          1" in output
      assert "job-socket-ready" in output

      # The action deliberately stays attached to a long build. Avoid the
      # runner's graceful volume-removal retries during fixture teardown.
      machine.succeed("systemctl kill --kill-whom=all --signal=KILL qualification-runner.service")
      machine.wait_until_fails("systemctl is-active --quiet qualification-runner.service", timeout=10)
      machine.succeed(f"{docker} rm --force $({docker} ps --all --quiet)", timeout=30)
      machine.succeed("systemctl stop forgejo-runner-docker.service", timeout=120)
      machine.succeed("docker unpause host-manual-pause")
      machine.succeed("docker rm --force host-manual-pause host-application")
    '';
  }
