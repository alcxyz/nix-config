{
  lib,
  pkgs,
}:
if !pkgs.stdenv.hostPlatform.isLinux
then pkgs.runCommand "forgejo-docker-storage-linux-only" {} ''touch "$out"''
else let
  evaluate = extra:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      specialArgs.inputs = {};
      modules = [
        ../../modules/nixos/services/forgejo-actions-runner
        {config = extra;}
        ({lib, ...}: {
          options.sops.secrets = lib.mkOption {
            type = lib.types.attrs;
            default = {};
          };
          config = {
            system.stateVersion = "25.11";
            services.forgejo-actions-runner = {
              enable = lib.mkDefault true;
              isolatedDocker.enable = lib.mkDefault true;
              labels = ["test:docker://example.invalid/test:latest"];
              secretsFile = pkgs.writeText "dummy-runner-secrets.yaml" "dummy: encrypted-fixture";
            };
          };
        })
      ];
    }).config;
  source = "fixture/runtime/docker";
  storageConfig.services.forgejo-actions-runner.isolatedDocker.storageMountSource = source;
  default = evaluate {};
  disabledRunner = evaluate (lib.recursiveUpdate storageConfig {
    services.forgejo-actions-runner.enable = false;
  });
  disabledDocker = evaluate (lib.recursiveUpdate storageConfig {
    services.forgejo-actions-runner.isolatedDocker.enable = false;
  });
  missingStorage = evaluate storageConfig;
  dedicatedStorage = evaluate (lib.recursiveUpdate storageConfig {
    fileSystems."/var/lib/forgejo-docker" = {
      device = source;
      fsType = "zfs";
    };
  });
  escapedStorage = evaluate {
    fileSystems."/var/lib/forgejo-docker" = {
      device = "/dev/disk/by-label/CI\\x20Storage";
      fsType = "ext4";
    };
    services.forgejo-actions-runner.isolatedDocker.storageMountSource = "/dev/disk/by-label/CI\\x20Storage";
  };
  mountUnit = "var-lib-forgejo\\x2ddocker.mount";
  readyUnit = "forgejo-docker-storage-ready.service";
  ready = dedicatedStorage.systemd.services.forgejo-docker-storage-ready;
  daemon = dedicatedStorage.systemd.services.forgejo-runner-docker;
  missingFilesystem = "Dedicated Docker storage requires an explicit /var/lib/forgejo-docker filesystem.";
  failedAssertion = config: message:
    lib.any (entry: !entry.assertion && entry.message == message) config.assertions;
in
  assert default.services.forgejo-actions-runner.isolatedDocker.storageMountSource == null;
  assert lib.all (config: !(config.systemd.services ? forgejo-docker-storage-ready)) [default disabledRunner disabledDocker];
  assert lib.all (config: !(failedAssertion config missingFilesystem)) [disabledRunner disabledDocker dedicatedStorage];
  assert failedAssertion missingStorage missingFilesystem;
  assert lib.elem mountUnit ready.requires;
  assert lib.elem mountUnit ready.bindsTo;
  assert lib.elem mountUnit ready.after;
  assert ready.serviceConfig.Type == "oneshot";
  assert ready.serviceConfig.RemainAfterExit;
  assert lib.hasSuffix "/bin/forgejo-runtime-storage-check /var/lib/forgejo-docker \"fixture/runtime/docker\"" ready.serviceConfig.ExecStart;
  assert lib.elem readyUnit daemon.requires;
  assert lib.elem readyUnit daemon.after;
  assert lib.elem readyUnit daemon.bindsTo;
  assert lib.elem mountUnit daemon.bindsTo;
  assert lib.hasSuffix ''/var/lib/forgejo-docker "/dev/disk/by-label/CI\\x20Storage"'' escapedStorage.systemd.services.forgejo-docker-storage-ready.serviceConfig.ExecStart;
    pkgs.runCommand "forgejo-docker-storage-contract" {} ''
      touch "$out"
    ''
