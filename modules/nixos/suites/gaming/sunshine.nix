# nix-config/modules/nixos/suites/gaming/sunshine.nix
{ config, lib, pkgs, username, ... }:
let
  cfg = config.suites.gaming.sunshine;
in {
  options.suites.gaming.sunshine.enable = lib.mkEnableOption "Native Sunshine";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.sunshine ];

    security.wrappers.sunshine = {
      owner = "root";
      group = "root";
      capabilities = "cap_sys_admin+p";
      source = "${pkgs.sunshine}/bin/sunshine";
    };

    boot.kernelModules = [ "nvidia_uvm" ];

    users.users.${username}.extraGroups = [ "video" "input" "render" ];

    networking.firewall = {
      allowedTCPPorts = [ 47984 47989 48010 ];
      allowedUDPPorts = [ 47998 47999 48000 48002 48010 ];
    };

    systemd.user.services.sunshine = {
      description = "Sunshine self-hosted game stream host";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" "pipewire.service" ];
      serviceConfig = {
        ExecStart = "/run/wrappers/bin/sunshine";
        # Running as your user but ensuring groups are mapped
        
        Environment = [
          "XDG_SESSION_TYPE=wayland"
          "XDG_CURRENT_DESKTOP=Hyprland"
          # Standard NixOS hardware paths
          "LD_LIBRARY_PATH=/run/opengl-driver/lib:/run/opengl-driver-32/lib"
          "__GLX_VENDOR_LIBRARY_NAME=nvidia"
          "GBM_BACKEND=nvidia-drm"
          "WLR_DRM_DEVICES=/dev/dri/card1"
        ];
        Restart = "on-failure";
      };
    };
  };
}
