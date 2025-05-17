{
  options,
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.services.kanata; # Updated option path
in
{
  options.services.kanata = with types; { # Updated option path
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the Kanata keyboard remapper system service."; # Updated description
    };
  };

  config = mkIf cfg.enable {
    # Install Kanata package at the system level
    environment.systemPackages = [ pkgs.kanata ];

    # Enable the Kanata user service
    systemd.user.services.kanata = {
      description = "Kanata keyboard remapper";
      wantedBy = [ "default.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.kanata}/bin/kanata -c %h/.config/kanata/kanata.kbd";
        Restart = "always";
        RestartSec = 3;
        Environment = "DISPLAY=:0";
      };
    };

    # Set up uinput for non-root users
    services.udev.extraRules = ''
      # Allow users in input group to use kanata
      KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
    '';

    # Ensure users who use Kanata are in the input group
    # This part needs to be handled at the user level (Home Manager)
    # users.groups.input = {}; # This option is for declaring system groups, not adding users to groups
    # security.pam.loginLimits = [...]; # This is a system-level setting, keep it here
    security.pam.loginLimits = [
      {
        domain = "@input";
        item = "memlock";
        type = "-";
        value = "unlimited";
      }
    ];

    # The addition of the user to the input group needs to be done in Home Manager (e.g., users/alc/home.nix)
    # The original commented-out line users.users.${user.name}.extraGroups = [ "input" ]; was a Home Manager option.
  };
}