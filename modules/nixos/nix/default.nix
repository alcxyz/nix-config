{
  options,
  config,
  pkgs,
  lib,
  username, # Passed in from specialArgs
  ...
}:
with lib;
let
  cfg = config.system.nix;
in
{
  options.system.nix = with lib.types; {
    enable = lib.mkOption {
      type = bool;
      default = true;
      description = "Whether or not to manage nix configuration.";
    };
    package = lib.mkOption {
      type = package;
      default = pkgs.nixVersions.latest; # Or pkgs.nix if you prefer
      description = "Which nix package to use.";
    };
    extraOptions = lib.mkOption {
      type = lines; # Use 'lines' for multi-line string, or 'str' for a single block
      default = "";
      description = "Extra lines to add to nix.conf (used if specific nix.settings aren't set or for options not covered by nix.settings).";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      nil
      nixfmt-classic
      nix-index
      nix-prefetch-git
      #nix-ld
    ];

    nix = {
      inherit (cfg) package; # This correctly refers to config.system.nix.package

      # Configure Nix daemon settings
      settings = {
        experimental-features = [ "nix-command" "flakes" ];
        accept-flake-config = true;
        warn-dirty = false;
        sandbox = "relaxed";
        # 'username' is passed as a specialArg to your NixOS configuration
        trusted-users = [ "root" username ];
        allowed-users = [ "root" username ];
        # Optionally, you can also set auto-optimise-store if desired
        auto-optimise-store = true;
      };

      # This allows you to still use extraOptions from your main configuration
      # for settings not covered above or for legacy configurations.
      # Nix will merge settings from 'nix.settings' and 'nix.extraOptions'.
      # For keys defined in both (like experimental-features), 'nix.settings'
      # usually takes precedence or they are merged if the option type allows.
      extraOptions = cfg.extraOptions;
    };
  };
}
