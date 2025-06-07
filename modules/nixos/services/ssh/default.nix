# modules/nixos/services/ssh/default.nix
{
  options,
  config,
  lib,
  pkgs,
  username,
  ...
}:

with lib;

let
  cfg = config.services.ssh;

  publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAxWjN37TvOrWjv1FXde72TscMwP0TbHRhoe0kO8IIU0 alc@AM-VYH2F56CR6";
  iphoneKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhgqS6A8n44Azg65g9u7a2mQ+RwqYo8dBW/4CHfua+0";
  yikzinKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIAhSQvuNQAtvN+ibnJ23+WnqTdENXVyrRJ538sBKUfx ZIN";
in
{
  # Define the custom option for enabling this SSH server configuration
  options.services.ssh = with types; {
    enable = mkOption {
      type = types.bool;
      default = false; # Default to false, enabled by host config or base system module
      description = "Enable the system-wide OpenSSH server with specific key-based authentication.";
    };
  };

  # Apply the configuration if this module is enabled (services.ssh.enable = true)
  config = mkIf cfg.enable {
    # Configure the standard NixOS OpenSSH service
    services.openssh = {
      enable = true; # This actually enables the sshd service
      ports = [ 22 ];

     settings.PermitRootLogin = "prohibit-password"; # Or "no" if preferred

      settings.PasswordAuthentication = false; # Disable password authentication
      openFirewall = true; # Automatically open the firewall for the specified ports
    };

    # Configure authorized SSH keys for system users
    users.users = {
      # Add the public key for the root user
      root.openssh.authorizedKeys.keys = [
        publicKey
      ];

      ${username}.openssh.authorizedKeys.keys = [
        publicKey
        iphoneKey
      ];

      yikzin.openssh.authorizedKeys.keys = [
        #yikzinKey
      ];
    };

  };
}

