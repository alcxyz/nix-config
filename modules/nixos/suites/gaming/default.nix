# nix-config/modules/nixos/suites/gaming/default.nix
{ config, lib, pkgs, username, ... }:

{
  imports = [
    ./audio.nix
    ./launchers.nix
    ./kiosk-base.nix
    ./sunshine.nix
  ];

  options.suites.gaming = {
    enable = lib.mkEnableOption "Gaming Infrastructure";
  };

  config = lib.mkIf config.suites.gaming.enable {
    # Hardware permissions for the isolated dGPU session
    users.users.${username}.extraGroups = [ "video" "render" "input" "seat" ];

    # We want logind multiseat (simultaneous), not seatd (VT-bound behavior).
    services.seatd.enable = false;

    services.udev.extraRules = ''
      # NVIDIA is 0000:01:00.0 on xyz -> seat-gaming
      SUBSYSTEM=="drm", KERNEL=="card*",    KERNELS=="0000:01:00.0", ENV{ID_SEAT}="seat-gaming"
      SUBSYSTEM=="drm", KERNEL=="renderD*", KERNELS=="0000:01:00.0", ENV{ID_SEAT}="seat-gaming"

      # Keep AMD (0000:71:00.0) explicitly on seat0 (optional but makes intent clear)
      SUBSYSTEM=="drm", KERNEL=="card*",    KERNELS=="0000:71:00.0", ENV{ID_SEAT}="seat0"
      SUBSYSTEM=="drm", KERNEL=="renderD*", KERNELS=="0000:71:00.0", ENV{ID_SEAT}="seat0"

      # Put Sunshine virtual input devices onto seat-gaming
      SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="Sunshine*", ENV{ID_SEAT}="seat-gaming"

      # Dedicated local input for the kiosk: Logitech Unifying Receiver 046d:c52b
      # (Matches input devices whose parent USB device is the receiver)
      #SUBSYSTEM=="input", KERNEL=="event*", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="c52b", ENV{ID_SEAT}="seat-gaming"
    '';

    boot.kernelModules = [ "uinput" "nvidia_uvm" ];

    environment.systemPackages = with pkgs; [
      gamescope
      mangohud
      moonlight-qt
    ];

  security.pam.services.gaming-kiosk.text = ''
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
