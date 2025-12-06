{ config, lib, pkgs, inputs, ... }:

with lib;
let
  cfg = config.secrets.ssh;
  secretsFile = "${inputs.nix-secrets}/secrets.yaml";
in {
  options.secrets.ssh = {
    keyPair = {
      enable = mkEnableOption "Deploy SSH key pair from SOPS secrets";
      baseName = mkOption {
        type = types.str;
        description = "Key prefix under secrets.yaml (e.g. 'ssh.xyz_id_ed25519')";
      };
      privateFileName = mkOption {
        type = types.str;
        default = "id_ed25519";
      };
      publicFileName = mkOption {
        type = types.str;
        default = "id_ed25519.pub";
      };
    };
  };

  config = mkIf cfg.keyPair.enable {
    sops.secrets = {
      "${cfg.keyPair.baseName}" = {
        sopsFile = secretsFile;
        path = ".ssh/${cfg.keyPair.privateFileName}";
        owner = config.home.username;
        mode = "0600";
      };
      "${cfg.keyPair.baseName}.pub" = {
        sopsFile = secretsFile;
        path = ".ssh/${cfg.keyPair.publicFileName}";
        owner = config.home.username;
        mode = "0644";
      };
    };
  };
}
