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

    services.seatd.enable = true;

    services.udev.extraRules = ''
      # Move the NVIDIA GPU and its render node to seat-gaming
      SUBSYSTEM=="drm", KERNEL=="card0", ENV{ID_SEAT}="seat-gaming"
      SUBSYSTEM=="drm", KERNEL=="renderD128", ENV{ID_SEAT}="seat-gaming"
      
      # Ensure the hardware uinput (Sunshine) also lives there
      KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="seat-gaming"
    '';

    boot.kernelModules = [ "uinput" "nvidia_uvm" ];

    environment.systemPackages = with pkgs; [
      gamescope
      mangohud
      moonlight-qt
    ];
  };
}
