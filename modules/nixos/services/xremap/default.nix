# modules/nixos/services/xremap/xremap-managed.nix
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.xremap.managed;
  xremapSystemConfigPath = "/etc/xremap/xremap.yml";
in
{
  options.services.xremap.managed = {
    enable = mkEnableOption "Managed xremap service for mouse/key remapping";

    package = mkOption {
      type = types.package;
      default = pkgs.xremap;
      description = mdDoc "xremap package to use.";
    };

    # Path must be known at build time, same as your Kanata module.
    configFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = mdDoc ''
        Path to the xremap YAML config. Will be installed to
        ${xremapSystemConfigPath}.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = mdDoc "User to run xremap as (needs uinput access).";
    };

    group = mkOption {
      type = types.str;
      default = "input";
      description = mdDoc "Group for uinput permissions.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ "--watch" ]; # auto-reload on config changes
      description = mdDoc "Extra command-line arguments to xremap.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Install the config file to /etc
    environment.etc."xremap/xremap.yml" = mkIf (cfg.configFile != null) {
      source = cfg.configFile;
      mode = "0444";
    };

    # uinput permissions (similar to your Kanata setup)
    services.udev.extraRules = ''
      KERNEL=="uinput", MODE="0660", GROUP="${cfg.group}", TAG+="uaccess", OPTIONS+="static_node=uinput"
    '';

    users.groups.${cfg.group} = { };

    # Often you’ll run as your user so it can see your Wayland session env vars.
    # If you use a user service, you can set user=config.yourUser.
    systemd.services."xremap-managed" = {
      description = "xremap (Managed System Service)";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      wants = [ "systemd-udev-settle.service" ];
      startLimitIntervalSec = 0;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        Restart = "always";
        RestartSec = 3;
        # xremap needs to create a virtual device via uinput; --watch auto reloads on file changes.
        ExecStart =
          assert (cfg.configFile != null);
          "${cfg.package}/bin/xremap ${xremapSystemConfigPath} ${concatStringsSep " " cfg.extraArgs}";
        # If running as a user, you may need environment for Wayland; see notes below.
        Environment = [
          "RUST_BACKTRACE=1"
          # Set these if running under a user session with Wayland/Niri (user service recommended then):
          # "WAYLAND_DISPLAY=wayland-0"
          # "XDG_RUNTIME_DIR=/run/user/%U"
        ];
        # Allow input device access
        AmbientCapabilities = [ ];
        CapabilityBoundingSet = [ ];
        SupplementaryGroups = [ cfg.group ];
      };
    };
  };
}
