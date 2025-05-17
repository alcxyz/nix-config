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
  # Extract public key definition
  publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAxWjN37TvOrWjv1FXde72TscMwP0TbHRhoe0kO8IIU0 alc@AM-VYH2F56CR6"; # Enter your ssh public key
in
{
  options.services.ssh = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the system-wide OpenSSH server.";
    };
  };

  config = mkIf cfg.enable {
    services.openssh = {
      enable = true;
      ports = [ 22 ];
      #PermitRootLogin = "prohibit-password"; # Consider setting this based on your security needs
      settings.PasswordAuthentication = false;
      openFirewall = true;
    };

    # Configure authorized keys for system users
    users.users = {
      root.openssh.authorizedKeys.keys = [
        publicKey
      ];
      # Assuming the main user is available via the passed username argument
      ${username}.openssh.authorizedKeys.keys = [
        publicKey
      ];
    };

    # The SSH client configuration (~/.ssh/config) is handled in the Home Manager module.
  };
}