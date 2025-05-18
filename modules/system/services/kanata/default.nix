{
  options,
  config,
  lib,
  pkgs,
  username, # Added username for consistency, though not strictly used here yet
  ...
}:
with lib;

let
  # cfg now refers to the standard NixOS option config.services.kanata (specifically its .enable attribute)
  cfg = config.services.kanata;
in
{
  # Removed options.services.kanata block to avoid re-declaration
  # The option services.kanata.enable is defined by the main NixOS Kanata module.

  config = mkIf cfg.enable { # This mkIf now correctly refers to the standard services.kanata.enable
    environment.systemPackages = [ pkgs.kanata ];

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

    services.udev.extraRules = ''
      KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
    '';

    security.pam.loginLimits = [
      {
        domain = "@input";
        item = "memlock";
        type = "-";
        value = "unlimited";
      }
    ];
  };
}
