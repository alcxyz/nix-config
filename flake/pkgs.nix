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
              "claude-code"
              "codex-app-server"
              "codex-cli"
              "devlog"
              "agent-sync-check"
              "omniwm"
              "zen-browser"
              "nix-deploy"
              "k8s-node-reboot"
              "xonsh-with-direnv"
            ];
            pt = inputs.paperless-tools.packages.${system} or {};
            stashdb-pop = inputs.stashdb-pop.packages.${system} or {};
            vidown = inputs.vidown.packages.${system} or {};
            videdupe = inputs.videdupe.packages.${system} or {};
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
            // lib.optionalAttrs (vidown ? default) {
              vidown = vidown.default;
            }
            // lib.optionalAttrs (videdupe ? default) {
              videdupe = videdupe.default;
            }
            // lib.optionalAttrs (stashdb-pop ? default) {
              stashdb-pop = stashdb-pop.default;
            }
            // {
              # Current nixpkgs lock has a stale fetchFromGitHub hash for croc 10.4.5.
              croc = _prev.croc.overrideAttrs (old: {
                src = _prev.fetchFromGitHub {
                  owner = "schollz";
                  repo = "croc";
                  rev = "v${old.version}";
                  hash = "sha256-u262LwHUL6+rPE7nzIda7W5dAXaikQ/cKwtUEIbcbH0=";
                };
              });
              nix-deploy = _prev.callPackage ../packages/nix-deploy {};
              k8s-node-reboot = _prev.callPackage ../packages/k8s-node-reboot {};
              reportcraft = inputs.reportcraft.packages.${system}.default;
              nixbox-plymouth-theme = _prev.callPackage ../packages/nixbox-plymouth-theme {};
              nixbox-session-splash = _prev.callPackage ../packages/nixbox-session-splash {
                quickshell = inputs.quickshell.packages.${system}.default;
              };
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
        config = {
          allowUnfree = true;
          allowUnsupportedSystem = true;
          # Required by bitwarden-desktop 2026.5.0 until nixpkgs moves it off electron_39.
          permittedInsecurePackages = lib.optionals (system == "x86_64-linux") [
            "electron-39.8.10"
          ];
        };
      }
  )
