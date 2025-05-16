{ options
, config
, lib
, pkgs
, ...
}:
with lib;
with lib.custom; let
  cfg = config.services.customKanata;
in
{
  options.services.customKanata = with types; {
    enable = mkBoolOpt false "Enable kanata";
  };

  config = mkIf cfg.enable {
    # Install Kanata package
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
    users.groups.input = {};
    security.pam.loginLimits = [
      {
        domain = "@input";
        item = "memlock";
        type = "-";
        value = "unlimited";
      }
    ];

    #users.users.${user.name}.extraGroups = [ "input" ];

  };

}
