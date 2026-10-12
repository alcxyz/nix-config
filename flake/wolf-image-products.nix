# Wolf image products from public inputs only. The repository package set
# applies overlays that read private flake inputs, and any access to it fetches
# them. The Wolf context producer (ADR-0074) evaluates `deployed` without git
# or SSH credentials; the derivations match those built from the full set.
{
  nixpkgs,
  nix-packages,
  system,
}: let
  pkgs = import nixpkgs {
    inherit system;
    config.allowUnfree = true;
    overlays = [
      (_final: _prev: {
        inherit (nix-packages.packages.${system}) zen-browser;
      })
    ];
  };
  products = productNames:
    import ../modules/nixos/services/wolf-streaming/image-products.nix ({
        inherit pkgs;
        inherit (pkgs) lib;
      }
      // pkgs.lib.optionalAttrs (productNames != null) {inherit productNames;});
in {
  inherit products;
  # CI publishes these exact Nix-owned Docker build contexts. The smaller
  # deployed set avoids rebuilding dormant comparative-test browsers on every
  # release while the complete export keeps those public options available for
  # explicit qualification.
  deployed = products [
    "wolf"
    "brave"
    "brave-origin"
    "zen"
  ];
}
