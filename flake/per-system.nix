{config, ...}: {
  perSystem = {system, ...}: let
    pkgs = config.alc.pkgsFor.${system};
  in {
    devShells.default = pkgs.mkShell {
      nativeBuildInputs = with pkgs; [
        treefmt
        alejandra
        shfmt
      ];
    };

    packages =
      if system == "x86_64-linux"
      then {
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
      }
      else {};
  };
}
