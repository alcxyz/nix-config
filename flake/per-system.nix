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

    apps = lib.optionalAttrs (system == "x86_64-linux") {
      tank-xev-migrate = inputs.nix-secrets.apps.${system}.tank-xev-migrate;
    };

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
        tank-xev-migrate = inputs.nix-secrets.packages.${system}.tank-xev-migrate;
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
