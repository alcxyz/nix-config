# modules/system/services/ssh/default.nix
{
  options,
  config,
  lib,
  pkgs,    # pkgs for the current system, passed by nixosSystem
  username, # Passed from specialArgs in flake.nix (e.g., "alc")
  ...
}:

with lib;

let
  # cfg accesses the custom option defined in this module
  cfg = config.services.ssh;

  # publicKey is hardcoded. This is fine for a personal configuration.
  # For a more generic module, this could be an option itself.
  publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAxWjN37TvOrWjv1FXde72TscMwP0TbHRhoe0kO8IIU0 alc@AM-VYH2F56CR6";
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

      # It's good practice to be explicit about PermitRootLogin.
      # "prohibit-password" is the default if PasswordAuthentication is false,
      # but explicitly setting it improves clarity.
      # If you never want root to log in via SSH, even with a key, use "no".
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

      # Add the public key for the main user (passed as 'username' argument)
      # This dynamically uses the 'username' from specialArgs.
      ${username}.openssh.authorizedKeys.keys = [
        publicKey
      ];
    };

    # Comment confirming scope:
    # The SSH client configuration (e.g., ~/.ssh/config) is correctly
    # handled in a Home Manager module, not here.
  };
}

