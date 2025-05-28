# kanata-managed-service.nix
{
  config, # The global NixOS config
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.kanata.managed;
  kanataSystemConfigPath = "/etc/kanata/kanata-managed.kbd";
in
{
  options = {
    services.kanata.managed = {
      enable = mkEnableOption "our managed Kanata keyboard remapper system service";

      configFile = mkOption {
        type = types.nullOr types.path; # types.path is important
        default = null;
        description = lib.mdDoc ''
          Path to the Kanata configuration file (e.g., your kanata.kbd)
          for the managed service.
          If set, this file will be copied to ${kanataSystemConfigPath}
          and used by the Kanata system service.
          This path must be resolvable by Nix at build time (e.g., an absolute path
          to an existing file, or a relative path within your Nix configuration).
        '';
      };

      # Optional: Add more Kanata-specific options if needed
      # logLevel = mkOption {
      #   type = types.enum [ "debug" "info" "warn" "error" "off" ];
      #   default = "info";
      #   description = "Log level for the managed Kanata service.";
      # };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.kanata ];

    environment.etc."kanata/kanata-managed.kbd" = mkIf (cfg.configFile != null) {
      # If cfg.configFile is set (and is a valid path type),
      # Nix will attempt to copy it. If the file doesn't exist at that path,
      # the Nix build will fail here when trying to realize the 'source'.
      source = cfg.configFile;
      mode = "0444";
      # The 'preCheck' attribute was removed as it's not valid here.
    };

    systemd.services."kanata-managed" = {
      description = "Kanata keyboard remapper (Managed System Service)";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      wants = [ "systemd-udev-settle.service" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "simple";
        # This assert ensures that the configFile option was actually provided in the NixOS config.
        # It doesn't check if the file *exists* at that path; 'environment.etc.source' implicitly handles that.
        ExecStart =
          assert (cfg.configFile != null); # Ensures the option is set by the user
          "${pkgs.kanata}/bin/kanata --cfg ${kanataSystemConfigPath}";
        Restart = "always";
        RestartSec = 3;
        User = "root";
        Environment = [ "RUST_BACKTRACE=1" ];
      };
    };

    services.udev.extraRules = ''
      KERNEL=="uinput", MODE="0660", GROUP="input", TAG+="uaccess", OPTIONS+="static_node=uinput"
    '';

    security.pam.loginLimits = [
      {
        domain = "@input";
        item = "memlock";
        type = "-";
        value = "unlimited";
      }
    ];

    users.groups.input = {};
  };
}
