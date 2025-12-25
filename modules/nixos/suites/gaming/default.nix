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
        "input"
        "uinput"
      ];
    };

    # Make sure uinput exists.
    boot.kernelModules = lib.mkAfter [ "uinput" ];

    # Ensure correct permissions on /dev/uinput and /dev/uhid.
    services.udev.extraRules = lib.mkAfter ''
      KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", MODE="0660", GROUP="uinput"
      KERNEL=="uhid",   SUBSYSTEM=="misc", MODE="0660", GROUP="input"
    '';

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
