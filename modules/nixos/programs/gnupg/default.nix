# modules/nixos/programs/gnupg/default.nix
{ config, lib, pkgs, ... }:

with lib;

{
  # Define an option for enabling system-level GPG related features
  options.mySystem.gnupg.smartcardSupport = mkEnableOption "system-wide smart card daemon (pcscd) for GnuPG and other uses";
  # You could also have options for installing a base gnupg package system-wide if desired,
  # though often not strictly necessary if Home Manager handles it for users.

  config = mkIf config.mySystem.gnupg.smartcardSupport {
    services.pcscd.enable = true;

    # Example: If you wanted to ensure gnupg is available system-wide for some reason
    # environment.systemPackages = [ pkgs.gnupg ];
  };
}
