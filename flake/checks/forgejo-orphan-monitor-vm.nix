{pkgs}: let
  dummyMonitor = pkgs.writeShellApplication {
    name = "forgejo-runner-orphan-check";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      token_file=
      docker_host=

      while test "$#" -gt 0; do
        case "$1" in
          --token-file)
            token_file=$2
            shift 2
            ;;
          --docker-host)
            docker_host=$2
            shift 2
            ;;
          --container-label | --forgejo-url | --repo)
            shift 2
            ;;
          *)
            echo "unexpected argument: $1" >&2
            exit 2
            ;;
        esac
      done

      test "$docker_host" = unix:///run/forgejo-docker/docker.sock
      test "$token_file" = "$CREDENTIALS_DIRECTORY/api-token"
      test "$(cat "$token_file")" = synthetic-token

      ${pkgs.python3}/bin/python3 - <<'PY'
      import socket

      with socket.socket(socket.AF_UNIX) as client:
          client.connect("/run/forgejo-docker/docker.sock")
      PY

      touch /run/forgejo-orphan-monitor-fixture/ready
      while ! test -e /run/forgejo-orphan-monitor-fixture/release; do
        sleep 0.1
      done
    '';
  };
in
  pkgs.testers.runNixOSTest {
    name = "forgejo-orphan-monitor-credential-isolation";
    nodes.machine = {lib, ...}: {
      imports = [../../modules/nixos/services/forgejo-actions-runner];
      options.sops.secrets = lib.mkOption {
        type = lib.types.attrs;
        default = {};
      };
      config = {
        system.stateVersion = "25.11";
        virtualisation.docker.enable = true;
        environment.etc."orphan-monitor-token" = {
          text = "synthetic-token";
          mode = "0400";
        };

        services.forgejo-actions-runner = {
          enable = true;
          labels = ["fixture:docker://example.invalid/unused:local"];
          secretsFile = pkgs.writeText "unused-dummy-secrets" "dummy";
          isolatedDocker.enable = true;
          orphanMonitor = {
            enable = true;
            package = dummyMonitor;
            tokenFile = "/etc/orphan-monitor-token";
            repositories = ["example/fixture"];
          };
        };

        # Exercise the monitor without starting a runner, daemon, or network
        # client. The fixture socket has the production ownership and mode.
        systemd.services.forgejo-actions-runner.wantedBy = lib.mkForce [];
        systemd.services.forgejo-runner-docker.wantedBy = lib.mkForce [];
        systemd.services.forgejo-orphan-socket-fixture = {
          wantedBy = ["multi-user.target"];
          before = ["forgejo-runner-orphan-check.service"];
          serviceConfig = {
            Type = "simple";
            Group = "forgejo-runner";
            RuntimeDirectory = "forgejo-docker";
            RuntimeDirectoryMode = "0750";
            ExecStart = "${pkgs.socat}/bin/socat UNIX-LISTEN:/run/forgejo-docker/docker.sock,unlink-early,fork,mode=0660,user=root,group=forgejo-runner EXEC:${pkgs.coreutils}/bin/true";
          };
        };
        systemd.services.forgejo-runner-orphan-check.serviceConfig.RuntimeDirectory = "forgejo-orphan-monitor-fixture";
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("forgejo-orphan-socket-fixture.service")
      machine.succeed(
          "test $(stat -c '%a:%U:%G' /run/forgejo-docker/docker.sock) = 660:root:forgejo-runner"
      )

      machine.succeed("systemctl start --no-block forgejo-runner-orphan-check.service")
      machine.wait_until_succeeds("test -e /run/forgejo-orphan-monitor-fixture/ready")

      pid = machine.succeed(
          "systemctl show forgejo-runner-orphan-check.service --property MainPID --value"
      ).strip()
      monitor_uid = machine.succeed(f"awk '/^Uid:/ {{ print $2 }}' /proc/{pid}/status").strip()
      runner_uid = machine.succeed("id -u forgejo-runner").strip()
      runner_gid = machine.succeed("getent group forgejo-runner | cut -d: -f3").strip()
      groups = machine.succeed(f"awk '/^Groups:/ {{ print $2 }}' /proc/{pid}/status").split()

      assert monitor_uid != runner_uid
      assert runner_gid in groups

      credential = "/run/credentials/forgejo-runner-orphan-check.service/api-token"
      machine.succeed(f"test $(cat /proc/{pid}/root{credential}) = synthetic-token")
      machine.succeed("test $(stat -c '%a:%U:%G' /etc/orphan-monitor-token) = 400:root:root")
      for identity in ["forgejo-runner", "forgejo-builder"]:
          machine.fail(f"su -s /bin/sh {identity} -c 'cat /etc/orphan-monitor-token'")
          machine.fail(
              f"su -s /bin/sh {identity} -c 'cat /proc/{pid}/root{credential}'"
          )
          machine.fail(
              f"su -s /bin/sh {identity} -c 'cat /proc/{pid}/environ'"
          )

      machine.succeed("touch /run/forgejo-orphan-monitor-fixture/release")
      machine.wait_until_succeeds("test $(systemctl show forgejo-runner-orphan-check.service -p ActiveState --value) = inactive")
      machine.succeed("systemctl show forgejo-runner-orphan-check.service -p Result --value | grep -Fx success")
    '';
  }
