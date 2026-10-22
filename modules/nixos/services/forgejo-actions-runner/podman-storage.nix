{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  source = cfg.podmanCanary.storageMountSource;
  enabled = cfg.enable && cfg.podmanCanary.enable && source != null;
  mountUnit = "var-lib-forgejo\\x2dpodman.mount";
  readyUnit = "forgejo-podman-storage-ready.service";
  check = pkgs.writeShellApplication {
    name = "forgejo-podman-storage-check";
    runtimeInputs = [pkgs.coreutils pkgs.util-linux];
    text = builtins.readFile ./podman-storage-check.sh;
  };
in {
  options.services.forgejo-actions-runner.podmanCanary.storageMountSource = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Expected source of a dedicated mount at /var/lib/forgejo-podman. When set, the API and socket depend on that exact mount and its identity check.";
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = builtins.hasAttr "/var/lib/forgejo-podman" config.fileSystems;
        message = "Dedicated Podman storage requires an explicit /var/lib/forgejo-podman filesystem.";
      }
    ];
    systemd.services.forgejo-podman-storage-ready = {
      description = "Verify the dedicated CI Podman filesystem";
      requires = [mountUnit];
      bindsTo = [mountUnit];
      after = [mountUnit];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${check}/bin/forgejo-podman-storage-check /var/lib/forgejo-podman ${utils.escapeSystemdExecArg source}";
      };
    };
    systemd.services.forgejo-runner-podman = {
      requires = [readyUnit];
      bindsTo = [mountUnit readyUnit];
      after = [readyUnit];
    };
    systemd.sockets.forgejo-runner-podman = {
      requires = [readyUnit];
      bindsTo = [mountUnit readyUnit];
      after = [readyUnit];
    };
  };
}
