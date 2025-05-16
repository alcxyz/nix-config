{ config, pkgs, lib, ... }:
with lib;
{
  config = {
    hardware.audio.enable = true;
    hardware.networking.enable = true;

    services.ssh.enable = true;

    programs.dconf.enable = true;

    system = {
      nix.enable = true;
      security.doas.enable = true;
      fonts.enable = true;
      locale.enable = true;
      time.enable = true;
      xkb.enable = true;
    };
  };
}
