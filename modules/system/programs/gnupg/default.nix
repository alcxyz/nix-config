{
  options,
  config,
  lib,
  pkgs,
  ...
}:
with lib;
{
  options.programs.gnupg = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable gnupg system configuration";
    };
  };

  config = mkIf config.programs.gnupg.enable {
    # System-level package installations for pinentry
    environment.systemPackages = with pkgs; [
      pinentry
      pinentry-curses
    ];

    # System-level service for pcscd (smart card reader daemon)
    services.pcscd.enable = true;

    # Note: User-specific GnuPG agent and config are in the Home Manager module
  };
}