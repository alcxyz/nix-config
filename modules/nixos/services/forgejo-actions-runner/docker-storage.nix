{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  source = cfg.isolatedDocker.storageMountSource;
  enabled = cfg.enable && cfg.isolatedDocker.enable && source != null;
  mountUnit = "var-lib-forgejo\\x2ddocker.mount";
  readyUnit = "forgejo-docker-storage-ready.service";
  check = pkgs.writeShellApplication {
    name = "forgejo-runtime-storage-check";
    runtimeInputs = [pkgs.coreutils pkgs.util-linux];
    text = builtins.readFile ./runtime-storage-check.sh;
  };
in {
  options.services.forgejo-actions-runner.isolatedDocker.storageMountSource = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Expected source of a dedicated mount at /var/lib/forgejo-docker. When set, the daemon depends on that exact mount and its identity check.";
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = builtins.hasAttr "/var/lib/forgejo-docker" config.fileSystems;
        message = "Dedicated Docker storage requires an explicit /var/lib/forgejo-docker filesystem.";
      }
    ];
    systemd.services.forgejo-docker-storage-ready = {
      description = "Verify the dedicated CI Docker filesystem";
      requires = [mountUnit];
      bindsTo = [mountUnit];
      after = [mountUnit];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${check}/bin/forgejo-runtime-storage-check /var/lib/forgejo-docker ${utils.escapeSystemdExecArg source}";
      };
    };
    systemd.services.forgejo-runner-docker = {
      requires = [readyUnit];
      bindsTo = [mountUnit readyUnit];
      after = [readyUnit];
    };
  };
}
