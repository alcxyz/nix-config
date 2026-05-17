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
              "ghostty"
              "kdash"
              "t3code"
              "stashdb-acquisition-list"
              "claude-code"
              "devlog"
              "agent-sync-check"
              "omniwm"
              "zen-browser"
              "nix-deploy"
              "k8s-node-reboot"
              "wcap"
              "xonsh-with-direnv"
            ];
            pt = inputs.paperless-tools.packages.${system} or {};
            lt = inputs.leantime-tidy.packages.${system} or {};
            vidown = inputs.vidown.packages.${system} or {};
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
            // lib.optionalAttrs (vidown ? default) {
              vidown = vidown.default;
            }
            // {
              nix-deploy = _prev.callPackage ../packages/nix-deploy {};
              k8s-node-reboot = _prev.callPackage ../packages/k8s-node-reboot {};
              stashdb-acquisition-list = _prev.callPackage ../packages/stashdb-acquisition-list {};
              paneru = inputs.paneru.packages.${system}.default;
            }
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
