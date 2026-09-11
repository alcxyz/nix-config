{
  config,
  inputs,
  self,
  ...
}: {
  perSystem = {system, ...}: let
    pkgs = config.alc.pkgsFor.${system};
    lib = pkgs.lib;
  in {
    devShells.default = pkgs.mkShell {
      nativeBuildInputs = with pkgs; [
        treefmt
        alejandra
        shfmt
        shellcheck
        pre-commit
        just
      ];
    };

    checks = import ./checks {inherit self inputs pkgs;};

    packages =
      {
        k8s-node-reboot = pkgs.k8s-node-reboot;
        nix-gc-maintenance = pkgs.nix-gc-maintenance;
        nix-deploy = pkgs.nix-deploy;
        reportcraft = pkgs.reportcraft;
      }
      // lib.optionalAttrs pkgs.stdenv.isLinux {
        ffmpeg-v4l2-request = pkgs.ffmpeg-v4l2-request;
        moonlight-v4l2-request = pkgs.moonlight-v4l2-request;
        nixbox-plymouth-theme = pkgs.nixbox-plymouth-theme;
        nixbox-session-splash = pkgs.nixbox-session-splash;
      }
      // lib.optionalAttrs (pkgs ? stashdb-pop) {
        stashdb-pop = pkgs.stashdb-pop;
      }
      // lib.optionalAttrs (system == "x86_64-linux") {
        # CI publishes these exact Nix-owned Docker build contexts. The smaller
        # deployed set avoids rebuilding dormant comparative-test browsers on
        # every release while the complete export keeps those public options
        # available for explicit qualification.
        wolf-deployed-image-products = import ../modules/nixos/services/wolf-streaming/image-products.nix {
          inherit lib pkgs;
          productNames = [
            "wolf"
            "helium"
            "brave"
            "zen"
          ];
        };
        wolf-all-image-products = import ../modules/nixos/services/wolf-streaming/image-products.nix {
          inherit lib pkgs;
        };
        wolf-image-product = import ../modules/nixos/services/wolf-streaming/image-products.nix {
          inherit lib pkgs;
          productNames = ["wolf"];
        };
        wolf-helium-image-product = import ../modules/nixos/services/wolf-streaming/image-products.nix {
          inherit lib pkgs;
          productNames = ["helium"];
        };
        wolf-brave-image-product = import ../modules/nixos/services/wolf-streaming/image-products.nix {
          inherit lib pkgs;
          productNames = ["brave"];
        };
        wolf-chromium-image-product = import ../modules/nixos/services/wolf-streaming/image-products.nix {
          inherit lib pkgs;
          productNames = ["chromium"];
        };
        wolf-firefox-image-product = import ../modules/nixos/services/wolf-streaming/image-products.nix {
          inherit lib pkgs;
          productNames = ["firefox"];
        };
        wolf-zen-image-product = import ../modules/nixos/services/wolf-streaming/image-products.nix {
          inherit lib pkgs;
          productNames = ["zen"];
        };

        # Cross-compiled U-Boot for Rock Pi 4 (RK3399).
        rpi0-uboot = pkgs.pkgsCross.aarch64-multiplatform.ubootRockPi4;

        # Convenience derivation that collects the two files you need to copy.
        rpi0-uboot-files = pkgs.runCommand "rpi0-uboot-files" {} ''
          set -e
          outdir="$out/share/rockpi4"
          mkdir -p "$outdir"
          cp ${pkgs.pkgsCross.aarch64-multiplatform.ubootRockPi4}/idbloader.img "$outdir/"
          cp ${pkgs.pkgsCross.aarch64-multiplatform.ubootRockPi4}/u-boot.itb "$outdir/"
          echo "Wrote Rock Pi 4 boot files to $outdir"
        '';
      };
  };
}
