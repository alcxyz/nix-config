{
  options,
  config,
  lib,
  ...
}:
with lib;

{
  options.programs.ssh = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Home Manager configuration for SSH client.";
    };
  };

  config = mkIf config.programs.ssh.enable {
    # Manage the user's SSH client configuration file
    home.file.".ssh/config".text = ''
      Host rpi*
        User root

      Host github
        Hostname github.com
        User git

      Host vps
        Hostname 46.202.150.96
        User root

      Host *
        identityfile ~/.ssh/key # Ensure this path is correct for your user's home directory
    '';

    # Note: The system-wide OpenSSH server is configured in a separate system module.
  };
}