{
  config,
  inputs,
  lib,
  ...
}: {
  options.alc = {
    username = lib.mkOption {
      type = lib.types.str;
      description = "Canonical user identity used for flake outputs and repository paths.";
    };

    inventory = lib.mkOption {
      type = lib.types.attrs;
      description = "Canonical host and role inventory.";
    };

    pkgsFor = lib.mkOption {
      type = lib.types.attrs;
      description = "Per-system nixpkgs instances with repository overlays.";
    };
  };

  config = {
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];

    alc = {
      username = "alc";
      inventory = import ../inventory.nix;
      pkgsFor = import ./pkgs.nix {
        inherit inputs;
        nixpkgs = inputs.nixpkgs;
        nix-packages = inputs.nix-packages;
        supportedSystems = config.systems;
      };
    };
  };
}
