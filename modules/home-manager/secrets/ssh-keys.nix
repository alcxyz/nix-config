# modules/home-manager/secrets/ssh-keys.nix
{ config, lib, pkgs, ... }:

with lib;

let
  # The configuration options for this module will be available under `secrets.ssh.privateKey`
  cfg = config.secrets.ssh.privateKey;
in
{
  # === 1. DEFINE THE OPTIONS ===
  # This makes our module configurable from other files.
  options.secrets.ssh.privateKey = {
    enable = mkEnableOption "Deploy a specific SSH private key from gopass";

    gopassPath = mkOption {
      type = types.str;
      description = "The path to the secret within gopass (e.g., 'ssh/xyz_id_ed25519').";
    };

    fileName = mkOption {
      type = types.str;
      default = "id_ed25519";
      description = "The name of the file to create in ~/.ssh/";
    };
  };

  # === 2. APPLY THE CONFIGURATION ===
  # This block only runs if `secrets.ssh.privateKey.enable` is set to `true`.
  config = mkIf cfg.enable {
    home.activation.provision-ssh-private-key = {
      after = [ "writeBoundary" ];
      text = ''
        # Ensure the .ssh directory exists with secure permissions (700)
        mkdir -p -m 700 "$HOME/.ssh"

        # Retrieve the secret from the gopass path specified in the config
        ${pkgs.gopass}/bin/gopass show "${cfg.gopassPath}" > "$HOME/.ssh/${cfg.fileName}"

        # Set the required 600 permissions on the private key file
        chmod 600 "$HOME/.ssh/${cfg.fileName}"

        echo "Placed SSH private key from gopass path '${cfg.gopassPath}' at $HOME/.ssh/${cfg.fileName}"
      '';
    };
  };
}
