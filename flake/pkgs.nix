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
        # This named overlay only adds the pinned OpenZFS package. Unlike the
        # package whitelist below, it must instantiate against this nixpkgs so
        # its kernel module uses the selected kernel's build environment.
        nix-packages.overlays.openzfs-7-1
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
              nix-deploy = _prev.callPackage ../packages/nix-deploy {};
              k8s-node-reboot = _prev.callPackage ../packages/k8s-node-reboot {};
              nix-gc-maintenance = _prev.callPackage ../packages/nix-gc-maintenance {};
              reportcraft = inputs.reportcraft.packages.${system}.default;
              nixbox-plymouth-theme = _prev.callPackage ../packages/nixbox-plymouth-theme {};
              nixbox-session-splash = _prev.callPackage ../packages/nixbox-session-splash {
                quickshell = inputs.quickshell.packages.${system}.default;
              };
              ffmpeg-v4l2-request = _prev.callPackage ../packages/ffmpeg-v4l2-request {};
              moonlight-v4l2-request = _prev.moonlight-qt.override {
                ffmpeg = _final.ffmpeg-v4l2-request;
              };
              # Keep the Pi 3 client as its own derivation so board-specific
              # Moonlight/FFmpeg fixes can evolve independently of rpi0.
              moonlight-rpi3 = _prev.moonlight-qt.overrideAttrs (old: {
                pname = "moonlight-rpi3";
                patches =
                  (old.patches or [])
                  ++ [
                    ../packages/moonlight-rpi3/use-qt-drm-master.patch
                    ../packages/moonlight-rpi3/log-periodic-video-stats.patch
                  ];
                qmakeFlags = (old.qmakeFlags or []) ++ ["CONFIG+=gpuslow"];
              });
            }
            # SentinelOne kills freshly-built binaries during test phase on macOS.
            # Skip nushell tests to avoid build failure on managed Macs.
            // lib.optionalAttrs (system == "aarch64-darwin") {
              nushell = _prev.nushell.overrideAttrs {doCheck = false;};
            }
            # Raspberry Pi kernels omit modules that the generic NixOS module
            # closure expects. Apply nixos-hardware's allow-missing workaround
            # here because NixOS receives this package set as read-only.
            // lib.optionalAttrs (system == "aarch64-linux") {
              makeModulesClosure = args:
                _prev.makeModulesClosure (args // {allowMissing = true;});
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
