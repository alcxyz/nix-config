{
  config,
  lib,
  pkgs,
  ...
}: let
  runtimeEnabled = config.virtualisation.docker.enable || config.services.k3s.enable;
  audit = pkgs.writeShellApplication {
    name = "container-netns-audit";
    runtimeInputs = [pkgs.gawk];
    text = builtins.readFile ./audit.sh;
  };
  prepare = pkgs.writeShellApplication {
    name = "container-netns-prepare";
    runtimeInputs = [
      audit
      pkgs.coreutils
      pkgs.systemd
      pkgs.util-linux
    ];
    text = builtins.readFile ./prepare.sh;
  };
in {
  config = lib.mkIf runtimeEnabled {
    systemd.services.container-netns-prepare = {
      description = "Establish the shared container network namespace mount";
      wantedBy = ["multi-user.target"];
      before = [
        "docker.service"
        "k3s.service"
      ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe prepare;
      };
    };

    systemd.services.docker = lib.mkIf config.virtualisation.docker.enable {
      requires = ["container-netns-prepare.service"];
      after = ["container-netns-prepare.service"];
    };

    systemd.services.k3s = lib.mkIf config.services.k3s.enable {
      requires = ["container-netns-prepare.service"];
      after = ["container-netns-prepare.service"];
    };

    systemd.services.container-netns-audit = {
      description = "Audit the container network namespace mount topology";
      after = ["container-netns-prepare.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe audit;
      };
    };

    systemd.timers.container-netns-audit = {
      description = "Periodically audit the container network namespace mount topology";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "5m";
        Persistent = false;
        RandomizedDelaySec = "0";
      };
    };

    services.storage-health-monitor.units = lib.mkIf config.services.storage-health-monitor.enable [
      {
        name = "container-netns-audit.service";
        mode = "recent-success";
        maximumAgeSeconds = 900;
        allowPendingFirstTimer = true;
      }
    ];
  };
}
