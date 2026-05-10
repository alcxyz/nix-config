{
  inputs,
  nixpkgs,
  nix-packages,
  supportedSystems,
}: let
  lib = nixpkgs.lib;
in
  lib.genAttrs supportedSystems (
    system: let
      overlays = [
        (
          _final: _prev: let
            np = nix-packages.packages.${system};
            wanted = [
              "forge-mirror"
              "ndrop"
              "zfs-auto-unlock"
              "helium"
              "kdash"
              "t3code"
              "claude-code"
              "devlog"
              "agent-sync-check"
              "omniwm"
              "zen-browser"
              "nix-deploy"
              "wcap"
            ];
            pt = inputs.paperless-tools.packages.${system} or {};
            lt = inputs.leantime-tidy.packages.${system} or {};
          in
            (lib.filterAttrs (n: _: builtins.elem n wanted) np)
            // (lib.filterAttrs (
                n: _:
                  builtins.elem n [
                    "paperweight"
                    "paperless-filetype-index"
                  ]
              )
              pt)
            // (lib.filterAttrs (
                n: _:
                  builtins.elem n [
                    "leantime-tidy"
                  ]
              )
              lt)
            # SentinelOne kills freshly-built binaries during test phase on macOS.
            # Skip nushell tests to avoid build failure on managed Macs.
            // lib.optionalAttrs (system == "aarch64-darwin") {
              nushell = _prev.nushell.overrideAttrs {doCheck = false;};
            }
        )
      ];
    in
      import nixpkgs {
        inherit system overlays;
        config.allowUnfree = true;
        config.allowUnsupportedSystem = true;
      }
  )
