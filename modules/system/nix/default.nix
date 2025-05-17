{
  options,
  config,
  pkgs,
  lib,
  ...
}:
with lib;

let
  cfg = config.system.nix;
in
{
  options.system.nix = with types; {
    enable = mkBoolOpt true "Whether or not to manage nix configuration.";
    package = mkOpt package pkgs.nixVersions.latest "Which nix package to use.";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      nil
      nixfmt-classic
      nix-index
      nix-prefetch-git
    ];

    nix = let
      # Use config.username which is passed as a specialArg
      users = [ "root" config.username ];
    in {
      inherit (cfg) package;

      settings =
        {
          experimental-features = "nix-command flakes";
          http-connections = 50;
          warn-dirty = false;
          log-lines = 50;
          sandbox = "relaxed";
          auto-optimise-store = true;
          trusted-users = users;
          allowed-users = users;
          # Made keep-outputs and keep-derivations unconditional for direnv support
          keep-outputs = true;
          keep-derivations = true;
        };

      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 7d";
      };

      # flake-utils-plus
      generateRegistryFromInputs = true;
      generateNixPathFromInputs = true;
      linkInputs = true;
    };
  };
}
