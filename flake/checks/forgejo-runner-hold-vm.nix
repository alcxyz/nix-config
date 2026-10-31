# The runner hold (ADR-0106) with the production units: the Docker runner and
# two Podman runners beside both dedicated engines, the game signal and the
# start gates. It does not register with Forgejo: the runner processes are
# stand-ins that stop on SIGTERM, or wait while the fixture blocks their stop.
{pkgs}: let
  unusedSecrets = pkgs.writeText "forgejo-runner-hold-secrets" "fixture-only";
  registrationToken = pkgs.writeText "forgejo-runner-hold-registration-token" "unused-fixture-token";
  runners = ["forgejo-actions-runner" "forgejo-podman-runner" "forgejo-podman-runner-fast"];
in
  pkgs.testers.runNixOSTest {
    name = "forgejo-runner-hold";
    nodes.machine = {lib, ...}: {
      imports = [../../modules/nixos/services/forgejo-actions-runner];
      options.sops.secrets = lib.mkOption {
        type = lib.types.attrs;
        default = {};
      };
      config = {
        system.stateVersion = "25.11";
        users.groups.game-fixture = {};
        users.users.game-fixture = {
          isSystemUser = true;
          group = "game-fixture";
        };
        virtualisation = {
          memorySize = 3072;
          cores = 2;
          diskSize = 6144;
          docker.enable = true;
        };
        services.gameSignal = {
          enable = true;
          user = "game-fixture";
          wineArgv0Basenames = ["HeroesOfTheStorm_x64.exe"];
          processNames = ["reaper"];
          streamUdpPorts = [47998];
          sampleSeconds = 1;
          cooldownSeconds = 3;
        };
        services.forgejo-actions-runner = {
          enable = true;
          name = "hold-fixture";
          labels = ["fixture:docker://example.invalid/unused:local"];
          secretsFile = unusedSecrets;
          isolatedDocker.enable = true;
          resourcePolicy = {
            memoryHigh = "1800M";
            memoryMax = "2200M";
          };
          runnerHold = {
            game.enable = true;
            sampleSeconds = 1;
          };
          shutdownTimeoutSeconds = 20;
          podmanCanary = {
            enable = true;
            registrationTokenFile = toString registrationToken;
            labels = ["podman-fixture:docker://example.invalid/unused:local"];
            extraRunners.fast.labels = ["fast-fixture:docker://example.invalid/unused:local"];
          };
        };
        # Keep the production units and dependencies while bypassing remote
        # runner registration.
        systemd.services = lib.mkMerge [
          (lib.genAttrs runners (_: {
            preStart = lib.mkForce "";
            script = lib.mkForce ''
              trap 'while test -e /run/fixture-runner-block-stop; do sleep 1; done; exit 0' TERM
              while :; do sleep 1; done
            '';
          }))
          # A stop that outlives its timeout ends failed, as on 2026-10-31.
          {forgejo-podman-runner.serviceConfig.TimeoutStopSec = lib.mkForce "5s";}
        ];
        environment.systemPackages = [pkgs.docker pkgs.procps pkgs.python3];
      };
    };
    testScript = ''
      state = "/run/forgejo-runner-hold/runners"
      runners = ["forgejo-actions-runner.service", "forgejo-podman-runner.service", "forgejo-podman-runner-fast.service"]
      all_active = " && ".join(f"systemctl is-active --quiet {unit}" for unit in runners)
      all_inactive = " && ".join(f"test $(systemctl show -p ActiveState --value {unit}) = inactive" for unit in runners)
      all_held = " && ".join(f"test -e {state}/{unit}/held" for unit in runners)
      none_held = " && ".join(f"test ! -e {state}/{unit}/held" for unit in runners)
      apis_active = "systemctl is-active --quiet forgejo-runner-docker.service forgejo-runner-podman.service"

      def game_on(kind):
          if kind == "wine":
              machine.succeed("cp ${pkgs.bash}/bin/bash /run/wine64-preloader")
              machine.succeed("systemd-run --unit=fixture-game --property=User=game-fixture ${pkgs.bash}/bin/bash -c \"exec -a HeroesOfTheStorm_x64.exe /run/wine64-preloader -c 'while :; do ${pkgs.coreutils}/bin/sleep 1; done'\"")
          elif kind == "steam":
              machine.succeed("cp ${pkgs.bash}/bin/bash /run/reaper")
              machine.succeed("systemd-run --unit=fixture-game --property=User=game-fixture /run/reaper -c 'while :; do ${pkgs.coreutils}/bin/sleep 1; done'")
          else:
              # A stream server's video port, bound by another account.
              machine.succeed("systemd-run --unit=fixture-game --property=DynamicUser=yes ${pkgs.python3}/bin/python3 -c 'import socket, time; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((\"0.0.0.0\", 47998)); time.sleep(3600)'")

      def game_off():
          machine.succeed("systemctl stop fixture-game.service")

      machine.start()
      machine.wait_for_unit("multi-user.target")
      assert not any("Found ordering cycle" in line for line in machine.full_console_log)
      machine.wait_until_succeeds(all_active, timeout=90)
      machine.succeed("systemctl is-active --quiet forgejo-runner-hold.service game-signal.service")
      machine.succeed(apis_active)
      machine.succeed("test ! -e /run/game-signal/active")
      assert machine.succeed("stat -c %a /run/game-signal").strip() == "755"
      assert machine.succeed("stat -c %a /run/forgejo-runner-hold").strip() == "700"

      with subtest("each kind of game holds every runner, and its end starts them again"):
          for kind in ("wine", "steam", "stream"):
              game_on(kind)
              machine.wait_until_succeeds("test -e /run/game-signal/active", timeout=15)
              machine.wait_until_succeeds(all_held, timeout=15)
              machine.wait_until_succeeds(all_inactive, timeout=30)
              # The engines stay up; only admission stops.
              machine.succeed(apis_active)
              for unit in runners:
                  assert machine.succeed(f"systemctl show -p Result --value {unit}").strip() == "success"
              game_off()
              machine.wait_until_succeeds("test ! -e /run/game-signal/active", timeout=20)
              machine.wait_until_succeeds(all_active, timeout=30)
              machine.wait_until_succeeds(none_held, timeout=15)
          machine.succeed("journalctl -u game-signal.service | grep -q 'event=game_started reason=wine:HeroesOfTheStorm_x64.exe'")
          machine.succeed("journalctl -u game-signal.service | grep -q 'event=game_started reason=process:reaper'")
          machine.succeed("journalctl -u game-signal.service | grep -q 'event=game_started reason=stream:47998'")
          machine.succeed("journalctl -u forgejo-runner-hold.service | grep -q 'event=hold reason=game'")
          machine.succeed("journalctl -u forgejo-runner-hold.service | grep -q 'event=release'")

      with subtest("the start gate refuses a start during a game and the hold starts it after"):
          game_on("wine")
          machine.wait_until_succeeds(all_inactive, timeout=30)
          machine.succeed("rm /run/forgejo-runner-hold/runners/forgejo-podman-runner.service/held")
          machine.succeed("systemctl start forgejo-podman-runner.service")
          assert machine.succeed("systemctl show -p ActiveState --value forgejo-podman-runner.service").strip() == "inactive"
          machine.succeed(f"test -e {state}/forgejo-podman-runner.service/held")
          game_off()
          machine.wait_until_succeeds(all_active, timeout=30)
          machine.wait_until_succeeds(none_held, timeout=15)

      with subtest("a stop that timed out is reset and started after the game"):
          machine.succeed("touch /run/fixture-runner-block-stop")
          game_on("wine")
          machine.wait_until_succeeds("test $(systemctl show -p ActiveState --value forgejo-podman-runner.service) = failed", timeout=30)
          assert machine.succeed("systemctl show -p Result --value forgejo-podman-runner.service").strip() == "timeout"
          machine.succeed("rm /run/fixture-runner-block-stop")
          machine.wait_until_succeeds(all_inactive.replace("forgejo-podman-runner.service) = inactive", "forgejo-podman-runner.service) = failed"), timeout=30)
          game_off()
          machine.wait_until_succeeds(all_active, timeout=30)
          machine.wait_until_succeeds(none_held, timeout=15)
          machine.succeed("journalctl -u forgejo-runner-hold.service | grep -q 'event=runner_start_requested runner_unit=forgejo-podman-runner.service active_state=failed result=timeout'")

      with subtest("a runner the operator stopped stays stopped"):
          machine.succeed("systemctl stop forgejo-podman-runner-fast.service")
          machine.succeed("sleep 5")
          assert machine.succeed("systemctl show -p ActiveState --value forgejo-podman-runner-fast.service").strip() == "inactive"
          machine.succeed(f"test ! -e {state}/forgejo-podman-runner-fast.service/held")
          machine.succeed("systemctl start forgejo-podman-runner-fast.service")
          machine.wait_until_succeeds(all_active, timeout=30)

      with subtest("a restarted hold keeps its runners held and releases them"):
          game_on("wine")
          machine.wait_until_succeeds(all_inactive, timeout=30)
          machine.succeed("systemctl restart forgejo-runner-hold.service game-signal.service")
          machine.succeed("sleep 3")
          machine.succeed(all_inactive)
          game_off()
          machine.wait_until_succeeds(all_active, timeout=30)
          machine.wait_until_succeeds(none_held, timeout=15)

      with subtest("losing the hold or the signal stops no runner"):
          machine.succeed("systemctl stop forgejo-runner-hold.service")
          machine.succeed("sleep 3")
          machine.succeed(all_active)
          machine.succeed(apis_active)
          machine.succeed("systemctl start forgejo-runner-hold.service")
          # An unavailable game signal counts as a game.
          machine.succeed("systemctl stop game-signal.service")
          machine.wait_until_succeeds(all_inactive, timeout=30)
          machine.succeed("journalctl -u forgejo-runner-hold.service | grep -q 'event=hold reason=game_signal_unavailable'")
          machine.succeed("systemctl start game-signal.service")
          machine.wait_until_succeeds(all_active, timeout=30)
    '';
  }
