# nix-config/modules/nixos/suites/gaming/default.nix
{ config, lib, pkgs, username, ... }:

{
  imports = [
    ./audio.nix
    ./wm-base.nix
    ./sunshine.nix
  ];

  options.suites.gaming = {
    enable = lib.mkEnableOption "Gaming Infrastructure";
  };

  config = lib.mkIf config.suites.gaming.enable {
    # Needed so user services can run without you being logged in
    users.users.${username} = {
      linger = true;
      extraGroups = [
        "video"
        "render"
      ];
    };

    # Headless wlroots: no seatd, no DRM/KMS -> won't VT-switch you
    services.seatd.enable = false;

    environment.systemPackages = with pkgs; [
      #gamescope
      #mangohud
      moonlight-qt
    ];

    security.pam.services.gaming-wm.text = ''
      auth required ${pkgs.linux-pam}/lib/security/pam_unix.so nullok
      account required ${pkgs.linux-pam}/lib/security/pam_unix.so
      session required ${pkgs.linux-pam}/lib/security/pam_unix.so
      session required ${config.systemd.package}/lib/security/pam_systemd.so
    '';

    security.pam.services.sunshine-kiosk.text = ''
      auth required ${pkgs.linux-pam}/lib/security/pam_unix.so nullok
      account required ${pkgs.linux-pam}/lib/security/pam_unix.so
      session required ${pkgs.linux-pam}/lib/security/pam_unix.so
      session required ${config.systemd.package}/lib/security/pam_systemd.so
    '';
  };
}
