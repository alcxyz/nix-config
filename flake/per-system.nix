{config, ...}: {
  perSystem = {system, ...}: let
    pkgs = config.alc.pkgsFor.${system};
    lib = pkgs.lib;
    src = lib.cleanSource ../.;

    mkRepoCheck = name: nativeBuildInputs: command:
      pkgs.runCommand name {inherit nativeBuildInputs src;} ''
        cp -R "$src" source
        chmod -R u+w source
        cd source
        ${command}
        touch "$out"
      '';

    formattedNixFiles = [
      "inventory.nix"
      "flake/per-system.nix"
      "flake/hosts/lib.nix"
      "hosts/madsil/configuration.nix"
      "hosts/madsil/hardware-configuration.nix"
      "hosts/mac/configuration.nix"
      "hosts/nex/configuration.nix"
      "hosts/nux/configuration.nix"
      "hosts/rpi0/configuration.nix"
      "hosts/xev/configuration.nix"
      "hosts/xps/configuration.nix"
      "hosts/xps/hardware-configuration.nix"
      "hosts/xyz/configuration.nix"
      "modules/home-manager/programs/stashdb-acquisition/default.nix"
      "modules/home-manager/programs/ssh/default.nix"
      "modules/nixos/common/default.nix"
      "modules/nixos/common/distributed-build-client.nix"
      "modules/nixos/common/pkgsets.nix"
      "modules/nixos/common/server.nix"
      "modules/nixos/common/ssh-keys.nix"
      "modules/nixos/services/flatpak/default.nix"
      "modules/nixos/services/heroic-sideload/default.nix"
      "modules/nixos/services/k8s-api-vip/default.nix"
      "modules/nixos/virtualisation/k3s/default.nix"
      "modules/shared/host-metadata.nix"
      "modules/shared/pkgsets.nix"
      "packages/k8s-node-reboot/default.nix"
      "packages/nix-deploy/default.nix"
      "users/alc/common.nix"
      "users/alc/linux/madsil.nix"
      "users/alc/linux/common.nix"
      "users/alc/linux/nex.nix"
      "users/alc/linux/nux.nix"
      "users/alc/linux/operator.nix"
      "users/alc/linux/rpi0.nix"
      "users/alc/linux/xev.nix"
      "users/alc/linux/xps.nix"
      "users/alc/linux/xyz.nix"
    ];
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

    checks = {
      nix-format = mkRepoCheck "nix-format-check" [pkgs.alejandra] ''
        alejandra --check ${lib.escapeShellArgs formattedNixFiles}
      '';

      check-scripts-shellcheck = mkRepoCheck "check-scripts-shellcheck" [pkgs.shellcheck] ''
        shellcheck scripts/checks/*.sh scripts/ops/*.sh packages/nix-deploy/deploy
      '';

      check-scripts-format = mkRepoCheck "check-scripts-format" [pkgs.shfmt] ''
        shfmt -d -i 2 -ci scripts/checks/*.sh scripts/ops/*.sh packages/nix-deploy/deploy
      '';

      forbid-submodule-config = mkRepoCheck "forbid-submodule-config" [] ''
        test ! -e .gitmodules
      '';
    };

    packages =
      {
        k8s-node-reboot = pkgs.k8s-node-reboot;
        nix-deploy = pkgs.nix-deploy;
        stashdb-acquisition-list = pkgs.stashdb-acquisition-list;
      }
      // lib.optionalAttrs (system == "x86_64-linux") {
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
