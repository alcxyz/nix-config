{
  config,
  inputs,
  self,
  ...
}: {
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
      "flake/pkgs.nix"
      "flake/hosts/lib.nix"
      "hosts/madsil/configuration.nix"
      "hosts/madsil/hardware-configuration.nix"
      "hosts/mac/configuration.nix"
      "hosts/nex/configuration.nix"
      "hosts/nux/configuration.nix"
      "hosts/rpi0/configuration.nix"
      "hosts/rpi1/configuration.nix"
      "hosts/rpi2/configuration.nix"
      "hosts/rpi3/configuration.nix"
      "hosts/xev/configuration.nix"
      "hosts/xps/configuration.nix"
      "hosts/xps/hardware-configuration.nix"
      "hosts/xyz/configuration.nix"
      "modules/home-manager/programs/stashdb-pop/default.nix"
      "modules/home-manager/programs/moonlight-endpoints/default.nix"
      "modules/home-manager/programs/ssh/default.nix"
      "modules/home-manager/programs/umu-apps/default.nix"
      "modules/nixos/common/default.nix"
      "modules/nixos/common/distributed-build-client.nix"
      "modules/nixos/common/pkgsets.nix"
      "modules/nixos/common/server.nix"
      "modules/nixos/profiles/nixbox-client/default.nix"
      "modules/nixos/profiles/nixbox-direct-client/default.nix"
      "modules/nixos/profiles/raspberry-pi-3-direct-client/default.nix"
      "modules/home-manager/services/waynergy/default.nix"
      "modules/home-manager/services/dms/default.nix"
      "modules/nixos/common/ssh-keys.nix"
      "modules/nixos/services/flatpak/default.nix"
      "modules/nixos/services/heroic-sideload/default.nix"
      "modules/nixos/services/k8s-api-vip/default.nix"
      "modules/nixos/services/wolf-streaming/default.nix"
      "modules/nixos/hardware/openzfs-7-1.nix"
      "modules/nixos/virtualisation/k3s/default.nix"
      "modules/nixos/virtualisation/longhorn-prereqs/default.nix"
      "modules/shared/host-metadata.nix"
      "modules/shared/pkgsets.nix"
      "packages/k8s-node-reboot/default.nix"
      "packages/nix-gc-maintenance/default.nix"
      "packages/ffmpeg-v4l2-request/default.nix"
      "packages/nix-deploy/default.nix"
      "packages/nixbox-plymouth-theme/default.nix"
      "packages/nixbox-session-splash/default.nix"
      "users/alc/common.nix"
      "users/alc/darwin/mac.nix"
      "users/alc/linux/madsil.nix"
      "users/alc/linux/common.nix"
      "users/alc/linux/nex.nix"
      "users/alc/linux/nux.nix"
      "users/alc/linux/operator.nix"
      "users/alc/linux/rpi0.nix"
      "users/alc/linux/embedded.nix"
      "users/alc/linux/rpi1.nix"
      "users/alc/linux/rpi2.nix"
      "users/alc/linux/rpi3.nix"
      "users/alc/linux/xev.nix"
      "users/alc/linux/xps.nix"
      "users/alc/linux/xyz.nix"
      "users/madsil/linux/madsil.nix"
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
        shellcheck scripts/checks/*.sh scripts/ci/verify-ai-package-stack.sh scripts/ops/*.sh packages/nix-deploy/deploy modules/nixos/services/wolf-streaming/browser-image/*.sh
      '';

      check-scripts-format = mkRepoCheck "check-scripts-format" [pkgs.shfmt] ''
        shfmt -d -i 2 -ci scripts/checks/*.sh scripts/ci/verify-ai-package-stack.sh scripts/ops/*.sh packages/nix-deploy/deploy modules/nixos/services/wolf-streaming/browser-image/*.sh
      '';

      ai-package-stack-verifier-contract = mkRepoCheck "ai-package-stack-verifier-contract" [pkgs.gnugrep] ''
        verifier=scripts/ci/verify-ai-package-stack.sh
        publisher=scripts/forgejo/publish-nix-packages-lock.sh
        workflow=.forgejo/workflows/update-nix-packages.yml

        grep -F 'NIX_CI_EPHEMERAL_CONTAINER: "1"' "$workflow"
        grep -F 'NIX_CI_EPHEMERAL_CONTAINER' "$verifier"
        grep -F 't3code.pnpmDeps' "$verifier"
        grep -F 't3code.resourceMonitor' "$verifier"
        grep -F 't3_out=$(nix_build "''${flake_uri}#t3code" --no-link --print-out-paths)' "$verifier"
        if grep -F 't3_out=$(nix build' "$verifier"; then
          echo "AI package verifier bypasses the staged Nix build wrapper" >&2
          exit 1
        fi

        grep -F 'prepare_verified_lock' "$publisher"
        grep -F 'git switch --detach "$latest_head"' "$publisher"
        grep -F 'scripts/ci/verify-ai-package-stack.sh flake.lock' "$publisher"
        grep -F 'git push origin "HEAD:refs/heads/''${BASE_BRANCH}"' "$publisher"
        grep -F 'kept advancing while the lock was published' "$publisher"
      '';

      check-k8s-node-reboot-workload-phases = mkRepoCheck "check-k8s-node-reboot-workload-phases" [pkgs.bash pkgs.jq] ''
        bash scripts/checks/test-k8s-node-reboot-workload-phases.sh
      '';

      check-nix-gc-maintenance = mkRepoCheck "check-nix-gc-maintenance" [pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gawk pkgs.gnugrep] ''
        bash scripts/checks/test-nix-gc-maintenance.sh
      '';

      t3code-auto-update-contract = let
        unit = self.homeConfigurations.alc-xyz.config.systemd.user.services.t3code-auto-update.Unit;
        service = self.homeConfigurations.alc-xyz.config.systemd.user.services.t3code-auto-update.Service;
        timer = self.homeConfigurations.alc-xyz.config.systemd.user.timers.t3code-auto-update.Timer;
        updater = builtins.head service.ExecStart;
      in
        assert unit.X-RestartIfChanged == false;
        assert service.Restart == "on-failure";
        assert service.RestartForceExitStatus == "75";
        assert service.RestartPreventExitStatus == "76";
        assert timer.OnCalendar == "*-*-* 09:30:00";
          pkgs.runCommand "t3code-auto-update-contract" {nativeBuildInputs = [pkgs.gnugrep];} ''
            grep -F "promotion_flake_default='git+https://git.alc.xyz/alcxyz/nix-config.git?ref=dev'" ${updater}
            grep -F 'promotion_flake="''${T3CODE_PROMOTION_FLAKE:-$promotion_flake_default}"' ${updater}
            if grep -F ":-'git+" ${updater}; then
              echo "Promotion flake default contains literal shell quotes" >&2
              exit 1
            fi
            touch "$out"
          '';

      umu-apps-contract = let
        homeConfig = self.homeConfigurations.alc-xyz.config;
        umuServices = homeConfig.systemd.user.services;
        desktopEntries = homeConfig.xdg.desktopEntries;
        battleNetService = umuServices.umu-app-battle-net.Service;
        profileService = umuServices.umu-app-heroes-profile.Service;
        battleNetEntry = desktopEntries.umu-battle-net;
        profileEntry = desktopEntries.umu-heroes-profile;
        battleNetRunner = builtins.head battleNetService.ExecStart;
        profileRunner = builtins.head profileService.ExecStart;
      in
        assert !(builtins.hasAttr "umu-app-battle-net-direct-qa" umuServices);
        assert !(builtins.hasAttr "umu-app-heroes-profile-direct-qa" umuServices);
        assert battleNetService.Type == "exec";
        assert profileService.Type == "exec";
        assert battleNetEntry.name == "Battle.net";
        assert profileEntry.name == "Heroes Profile";
        assert builtins.match ".+-battle-net.png" battleNetEntry.icon != null;
        assert builtins.match ".+-heroes-profile.png" profileEntry.icon != null;
          pkgs.runCommand "umu-apps-contract" {nativeBuildInputs = [pkgs.gnugrep];} ''
            grep -F 'export GAMEID=umu-default' ${battleNetRunner}
            grep -F 'export PROTON_VERB=waitforexitandrun' ${battleNetRunner}
            grep -F 'prefix_in_use' ${battleNetRunner}
            grep -F '"''${1:-}" = "--check-only"' ${battleNetRunner}
            grep -F 'GE-Proton10-4-steamcompattool' ${battleNetRunner}
            grep -F 'export TZ=Europe/Oslo' ${battleNetRunner}
            grep -F 'export PROTON_VERB=runinprefix' ${profileRunner}
            grep -F 'GE-Proton10-4-steamcompattool' ${profileRunner}
            if grep -F 'gamemoderun' ${battleNetRunner} ${profileRunner}; then
              echo "Direct Battle.net launchers must not request unavailable GameMode" >&2
              exit 1
            fi
            touch "$out"
          '';

      nix-gc-retention-module-contract = let
        nixosGc = self.nixosConfigurations.xyz.config.systemd.services.nix-gc;
        darwinRetention = self.darwinConfigurations.mac.config.launchd.daemons.nix-generation-retention.serviceConfig;
        darwinGc = self.darwinConfigurations.mac.config.launchd.daemons.nix-gc.serviceConfig;
      in
        assert builtins.elem "nix-generation-retention.service" nixosGc.requires;
        assert builtins.elem "nix-generation-retention.service" nixosGc.after;
        assert darwinRetention.StartCalendarInterval.Weekday == 0;
        assert darwinRetention.StartCalendarInterval.Hour == 1;
        assert darwinRetention.StartCalendarInterval.Minute == 45;
        assert darwinGc.StartCalendarInterval.Weekday == 0;
        assert darwinGc.StartCalendarInterval.Hour == 2;
          pkgs.runCommand "nix-gc-retention-module-contract" {} ''
            touch "$out"
          '';

      wolf-browser-input-contract =
        mkRepoCheck "wolf-browser-input-contract" [
          pkgs.bash
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
        ] ''
          bash scripts/checks/test-wolf-browser-input-contract.sh
        '';

      report-assets =
        mkRepoCheck "report-assets-check"
        [
          pkgs.html-tidy
        ]
        ''
          tidy -qe docs/reports/*.html
        '';

      forbid-submodule-config = mkRepoCheck "forbid-submodule-config" [] ''
        test ! -e .gitmodules
      '';

      rpi3-direct-client-contract = let
        rpi1 = self.nixosConfigurations.rpi1.config;
        rpi2 = self.nixosConfigurations.rpi2.config;
        rpi3 = self.nixosConfigurations.rpi3.config;
      in
        assert rpi1.services.nixbox-direct-client.streamFps == 30;
        assert rpi2.services.nixbox-direct-client.streamFps == 60;
        assert rpi3.services.nixbox-direct-client.streamFps == 60;
        assert rpi1.services.nixbox-direct-client.package.pname == "moonlight-rpi3";
        assert rpi2.services.nixbox-direct-client.package.pname == "moonlight-rpi3";
        assert rpi3.services.nixbox-direct-client.package.pname == "moonlight-rpi3";
        assert rpi1.services.moonlight-client.defaultSessionMode == "direct-browser";
        assert rpi1.systemd.services.greetd.serviceConfig.Restart == "always";
        assert rpi1.security.sudo.wheelNeedsPassword;
        assert !(inputs.nix-secrets.nixosModules ? operatorLogin)
        || rpi1.users.users.alc.hashedPasswordFile != null;
          pkgs.runCommand "rpi3-direct-client-contract" {} ''
            touch "$out"
          '';
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
