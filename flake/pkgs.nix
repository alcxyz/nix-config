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
              "git-identity-guard"
              "ndrop"
              "zfs-auto-unlock"
              "helium"
              "ghostty"
              "kdash"
              "t3code"
              "ai-stack-upstream"
              "claude-code"
              "codex-app-server"
              "codex-cli"
              "devlog"
              "omniwm"
              "zen-browser"
              "nix-deploy"
              "k8s-node-reboot"
              "nix-gc-maintenance"
              "xonsh-with-direnv"
            ];
            pt = inputs.paperless-tools.packages.${system} or {};
            regnskap = inputs.regnskap.packages.${system} or {};
            ptDev = inputs.paperless-tools-dev.packages.${system} or {};
            regnskapDev = inputs.regnskap-dev.packages.${system} or {};
            bivrost = inputs.bivrost.packages.${system} or {};
            groveDev = inputs.grove-dev.packages.${system} or {};
            canopyDev = inputs.canopy-dev.packages.${system} or {};
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
            // lib.optionalAttrs (bivrost ? default) {
              bivrost = bivrost.default;
            }
            // lib.optionalAttrs (vidown ? default) {
              vidown = vidown.default;
            }
            // lib.optionalAttrs (videdupe ? default) {
              videdupe = videdupe.default;
            }
            // lib.optionalAttrs (regnskap ? bokfor) {
              inherit (regnskap) bokfor;
            }
            # Dev builds keep their own command name and paperweight state
            # (ADR-0087). paperweight reads XDG_STATE_HOME only for its reports
            # and does not pass it to the LLM CLIs. bokfor-dev is run by the
            # nix-secrets launcher.
            // lib.optionalAttrs (ptDev ? paperweight) {
              paperweight-dev = _prev.writeShellScriptBin "paperweight-dev" ''
                export XDG_STATE_HOME="''${XDG_STATE_HOME:-$HOME/.local/state}/paperweight-dev"
                exec ${ptDev.paperweight}/bin/paperweight "$@"
              '';
            }
            // lib.optionalAttrs (regnskapDev ? bokfor) {
              bokfor-dev = regnskapDev.bokfor;
            }
            # App dev builds only take a -dev command name (ADR-0089). They share
            # the release's config, cache and log, because changing XDG paths
            # would also move the state of the editors and git tools they open.
            // lib.optionalAttrs (groveDev ? default) {
              grove-dev = _prev.writeShellScriptBin "grove-dev" ''
                exec ${groveDev.default}/bin/grove "$@"
              '';
            }
            // lib.optionalAttrs (canopyDev ? default) {
              canopy-dev = _prev.writeShellScriptBin "canopy-dev" ''
                exec ${canopyDev.default}/bin/canopy "$@"
              '';
            }
            // lib.optionalAttrs (stashdb-pop ? default) {
              stashdb-pop = stashdb-pop.default;
            }
            // {
              k3s-flannel-node-source = _prev.callPackage "${nix-packages}/pkgs/k3s-flannel-node-source" {};
              nix-deploy = _prev.callPackage ../packages/nix-deploy {
                nixDeploy = np.nix-deploy;
              };
              reportcraft = inputs.reportcraft.packages.${system}.default;
              openbao = inputs.nixpkgs-openbao.legacyPackages.${system}.openbao;
              nixbox-plymouth-theme = _prev.callPackage ../packages/nixbox-plymouth-theme {};
              nixbox-session-splash = _prev.callPackage ../packages/nixbox-session-splash {
                quickshell = inputs.quickshell.packages.${system}.default;
              };
              ffmpeg-v4l2-request = _prev.callPackage ../packages/ffmpeg-v4l2-request {};
              moonlight-v4l2-request = _prev.moonlight-qt.override {
                ffmpeg_8 = _final.ffmpeg-v4l2-request;
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
              # pihole-ftl 6.7.1 sets but never reads a variable in
              # src/config/validator.c, which GCC 16 promotes to an error.
              pihole-ftl = _prev.pihole-ftl.overrideAttrs (old: {
                env =
                  (old.env or {})
                  // {
                    NIX_CFLAGS_COMPILE = toString [
                      (old.env.NIX_CFLAGS_COMPILE or "")
                      "-Wno-error=unused-but-set-variable"
                    ];
                  };
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
            // lib.optionalAttrs _prev.stdenv.hostPlatform.isLinux {
              hyprland = _prev.hyprland.overrideAttrs (old: {
                patches =
                  (old.patches or [])
                  ++ [../packages/hyprland/center-underfilled-scrolling-column.patch];
              });
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
