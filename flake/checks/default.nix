{
  self,
  inputs,
  pkgs,
}: let
  lib = pkgs.lib;
  src = lib.cleanSource ../..;

  mkRepoCheck = name: nativeBuildInputs: command:
    pkgs.runCommand name {inherit nativeBuildInputs src;} ''
      cp -R "$src" source
      chmod -R u+w source
      cd source
      ${command}
      touch "$out"
    '';
in {
  configuration-evaluation = (import ./configurations.nix {inherit self pkgs;}).configuration-evaluation;
  configuration-evaluation-contract = assert import ./configurations-test.nix;
    pkgs.runCommand "configuration-evaluation-contract" {} ''
      touch "$out"
    '';

  forge-mirror-audit-contract = assert import ./forge-mirror-audit-test.nix {inherit lib;};
    pkgs.runCommand "forge-mirror-audit-contract" {} ''
      touch "$out"
    '';

  display-device-guard-contract = import ./display-device-guard.nix {inherit lib pkgs;};

  moonlight-endpoint-setup-contract = import ./moonlight-endpoints.nix {inherit lib pkgs;};

  nix-format = mkRepoCheck "nix-format-check" [pkgs.treefmt pkgs.alejandra] ''
    treefmt --ci --formatters nix
  '';

  check-scripts-shellcheck = mkRepoCheck "check-scripts-shellcheck" [pkgs.shellcheck] ''
    shellcheck scripts/checks/*.sh scripts/ci/*.sh scripts/forgejo/publish-nix-packages-lock.sh scripts/ops/*.sh modules/nixos/services/wolf-streaming/browser-image/*.sh
    shellcheck --shell=bash hosts/xyz/xyz-*.sh
  '';

  check-scripts-format = mkRepoCheck "check-scripts-format" [pkgs.treefmt pkgs.shfmt] ''
    treefmt --ci --formatters shell
  '';

  nix-deploy-inventory-contract = let
    config = pkgs.nix-deploy.deployConfig;
    expectedHosts = builtins.attrNames (import ../../inventory.nix).hosts;
  in
    pkgs.runCommand "nix-deploy-inventory-contract" {
      nativeBuildInputs = [pkgs.jq pkgs.gnugrep];
    } ''
      jq -e --argjson hosts ${lib.escapeShellArg (builtins.toJSON expectedHosts)} \
        '.knownHosts == $hosts' ${config} >/dev/null
      # Help validates the actual generated inventory without deployment work.
      ${pkgs.nix-deploy}/bin/deploy --help >help.txt 2>error.txt && exit 1
      test ! -s error.txt
      grep -Fq 'Known hosts:' help.txt
      NIX_DEPLOY_CONFIG=/missing-inventory ${pkgs.nix-deploy}/bin/deploy --help >help.txt 2>error.txt && exit 1
      grep -Fq 'cannot read inventory' error.txt
      NIX_DEPLOY_CONFIG=/missing-inventory ${pkgs.nix-deploy}/bin/deploy --config ${config} --help >help.txt 2>error.txt && exit 1
      test ! -s error.txt
      grep -Fq 'Known hosts:' help.txt
      touch "$out"
    '';

  maintained-dev-qa = mkRepoCheck "maintained-dev-qa" [pkgs.python3 pkgs.bash pkgs.coreutils pkgs.jq pkgs.shellcheck pkgs.shfmt] ''
    shellcheck scripts/update-inputs/update-maintained.sh scripts/update-inputs/update-dms-plugins.sh
    shfmt -d -i 2 -ci scripts/update-inputs/update-maintained.sh scripts/update-inputs/update-dms-plugins.sh
    python3 scripts/checks/test-maintained-dev-qa.py
  '';

  configuration-ci-contract = mkRepoCheck "configuration-ci-contract" [pkgs.python3 pkgs.bash pkgs.git] ''
    python3 scripts/checks/test-configuration-ci.py
  '';

  ai-package-stack-verifier-contract = mkRepoCheck "ai-package-stack-verifier-contract" [pkgs.bash pkgs.coreutils pkgs.gawk pkgs.git pkgs.gnugrep pkgs.python3 pkgs.ripgrep] ''
    publisher=scripts/forgejo/publish-nix-packages-lock.sh
    workflow=.forgejo/workflows/update-nix-packages.yml

    grep -F 'NIX_CI_EPHEMERAL_CONTAINER: "1"' "$workflow"
    bash scripts/checks/test-ai-package-stack-verifier.sh

    grep -F 'prepare_verified_lock' "$publisher"
    grep -F 'git switch --detach "$latest_head"' "$publisher"
    grep -F 'scripts/ci/verify-ai-package-stack.sh flake.lock' "$publisher"
    grep -F 'git push origin "HEAD:refs/heads/''${BASE_BRANCH}"' "$publisher"
    grep -F 'kept advancing while the lock was published' "$publisher"
  '';

  check-claude-settings-merge = mkRepoCheck "check-claude-settings-merge" [pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.diffutils pkgs.jq pkgs.shellcheck] ''
    shellcheck modules/home-manager/programs/ai/merge-settings.sh
    bash scripts/checks/test-claude-settings-merge.sh
  '';

  check-workspace-sync = mkRepoCheck "check-workspace-sync" [pkgs.bash pkgs.coreutils pkgs.git pkgs.gnugrep pkgs.diffutils pkgs.jq pkgs.shellcheck] ''
    shellcheck modules/home-manager/workspace/workspace-sync.sh
    bash scripts/checks/test-workspace-sync.sh
  '';

  k8s-api-vip-source-routing-contract = let
    instance = self.nixosConfigurations.xev.config.services.keepalived.vrrpInstances.k8s_api;
  in
    assert instance.virtualIps == [];
    assert lib.hasInfix "noprefixroute" instance.extraConfig;
      pkgs.runCommand "k8s-api-vip-source-routing-contract" {} ''
        touch "$out"
      '';

  xyz-xwayland-primary-output-lifecycle-contract = let
    unit = self.homeConfigurations.alc-xyz.config.xdg.configFile."systemd/user/hyprland-xwayland-primary-output.service".source;
  in
    pkgs.runCommand "xyz-xwayland-primary-output-lifecycle-contract" {nativeBuildInputs = [pkgs.gnugrep];} ''
      grep -Fx 'After=wayland-wm@hyprland.desktop.service' ${unit}
      grep -Fx 'BindsTo=wayland-wm@hyprland.desktop.service' ${unit}
      grep -Fx 'WantedBy=wayland-wm@hyprland.desktop.service' ${unit}
      if grep -Fq 'graphical-session.target' ${unit}; then
        echo "XWayland primary-output watcher still follows the generic graphical session" >&2
        exit 1
      fi
      touch "$out"
    '';

  t3code-auto-update-contract = let
    t3Unit = self.homeConfigurations.alc-xyz.config.systemd.user.services.t3code.Unit;
    unit = self.homeConfigurations.alc-xyz.config.systemd.user.services.t3code-auto-update.Unit;
    service = self.homeConfigurations.alc-xyz.config.systemd.user.services.t3code-auto-update.Service;
    timer = self.homeConfigurations.alc-xyz.config.systemd.user.timers.t3code-auto-update.Timer;
    updater = builtins.head service.ExecStart;
    guard = lib.removePrefix "run " self.homeConfigurations.alc-xyz.config.home.activation.t3codeRestartGuard.data;
    applyManagedUnit = self.homeConfigurations.alc-xyz.config.home.activation.t3codeApplyManagedUnit.data;
  in
    assert t3Unit.X-RestartIfChanged == false;
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
        grep -F "T3CODE_CGROUP_FILE" ${guard}
        grep -F "t3code\\.service" ${guard}
        grep -F 'systemctl --user restart t3code.service' ${
          pkgs.writeText "t3code-apply-managed-unit" applyManagedUnit
        }
        touch "$out"
      '';

  umu-apps-contract = let
    home = self.homeConfigurations.alc-xyz;
    homeConfig = home.config;
    umuConfig = homeConfig.programs.umuApps;
    umuServices = homeConfig.systemd.user.services;
    desktopEntries = homeConfig.xdg.desktopEntries;
    # Inspect the complete production scripts without building their runtime dependencies.
    renderedApplications =
      lib.mapAttrs (
        name: app:
          import ../../modules/home-manager/programs/umu-apps/application.nix {
            inherit app lib name;
            cfg = umuConfig;
            pkgs = home.pkgs;
          }
      )
      umuConfig.apps;
    battleNetUnit = umuServices.umu-app-battle-net.Unit;
    profileUnit = umuServices.umu-app-heroes-profile.Unit;
    battleNetService = umuServices.umu-app-battle-net.Service;
    profileService = umuServices.umu-app-heroes-profile.Service;
    battleNetEntry = desktopEntries.umu-battle-net;
    profileEntry = desktopEntries.umu-heroes-profile;
    battleNetRunner = builtins.head battleNetService.ExecStart;
    profileRunner = builtins.head profileService.ExecStart;
    battleNetStarter = battleNetEntry.exec;
    profileStarter = profileEntry.exec;
    battleNetRunnerText = renderedApplications.battle-net.runner.text;
    profileRunnerText = renderedApplications.heroes-profile.runner.text;
    battleNetStarterText = renderedApplications.battle-net.starter.text;
    profileStarterText = renderedApplications.heroes-profile.starter.text;
    # These fixtures contain script bytes for static inspection only. Strip their
    # dependency context, never a path used to read or execute a runtime file.
    scriptFixture = name: text:
      pkgs.writeText name (builtins.unsafeDiscardStringContext text);
    renderedScriptFixtures = [
      (scriptFixture "umu-app-battle-net-run.sh" battleNetRunnerText)
      (scriptFixture "umu-app-heroes-profile-run.sh" profileRunnerText)
      (scriptFixture "umu-app-battle-net.sh" battleNetStarterText)
      (scriptFixture "umu-app-heroes-profile.sh" profileStarterText)
    ];
    malformedScriptFixture = pkgs.writeText "umu-app-malformed.sh" ''
      if true; then
    '';
  in
    assert !(builtins.hasAttr "umu-app-battle-net-direct-qa" umuServices);
    assert !(builtins.hasAttr "umu-app-heroes-profile-direct-qa" umuServices);
    assert battleNetUnit.X-SwitchMethod == "keep-old";
    assert profileUnit.X-SwitchMethod == "keep-old";
    assert battleNetService.Type == "exec";
    assert profileService.Type == "exec";
    assert battleNetEntry.name == "Battle.net";
    assert profileEntry.name == "Heroes Profile";
    assert builtins.match ".+-battle-net.png" battleNetEntry.icon != null;
    assert builtins.match ".+-heroes-profile.png" profileEntry.icon != null;
    assert battleNetRunner == lib.getExe renderedApplications.battle-net.runner;
    assert profileRunner == lib.getExe renderedApplications.heroes-profile.runner;
    assert battleNetStarter == lib.getExe renderedApplications.battle-net.starter;
    assert profileStarter == lib.getExe renderedApplications.heroes-profile.starter;
    assert lib.hasInfix "export GAMEID=umu-default" battleNetRunnerText;
    assert lib.hasInfix "export PROTON_VERB=waitforexitandrun" battleNetRunnerText;
    assert lib.hasInfix "prefix_in_use" battleNetRunnerText;
    assert lib.hasInfix ''"''${1:-}" = "--check-only"'' battleNetRunnerText;
    assert lib.hasInfix "GE-Proton10-4-steamcompattool" battleNetRunnerText;
    assert lib.hasInfix "export TZ=Europe/Oslo" battleNetRunnerText;
    assert lib.hasInfix "No managed window remains; restarting the stale service" battleNetStarterText;
    assert lib.hasInfix "same_prefix_companion_active" battleNetStarterText;
    assert lib.hasInfix "ActiveEnterTimestampMonotonic" battleNetStarterText;
    assert !(lib.hasInfix "No managed window remains; restarting the stale service" profileStarterText);
    assert lib.hasInfix "export PROTON_VERB=runinprefix" profileRunnerText;
    assert lib.hasInfix "GE-Proton10-4-steamcompattool" profileRunnerText;
    assert !(lib.hasInfix "gamemoderun" battleNetRunnerText);
    assert !(lib.hasInfix "gamemoderun" profileRunnerText);
      pkgs.runCommand "umu-apps-contract" {
        nativeBuildInputs = [pkgs.bash pkgs.shellcheck];
      } ''
        for script in ${lib.escapeShellArgs renderedScriptFixtures}; do
          bash -n "$script"
          shellcheck --shell=bash "$script"
        done
        if bash -n ${malformedScriptFixture} >/dev/null 2>&1; then
          echo "Bash syntax check accepted a malformed rendered launcher fixture" >&2
          exit 1
        fi
        if shellcheck --shell=bash ${malformedScriptFixture} >/dev/null 2>&1; then
          echo "ShellCheck accepted a malformed rendered launcher fixture" >&2
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

  moonlight-input-source-syntax =
    mkRepoCheck "moonlight-input-source-syntax" [
      pkgs.libx11
      pkgs.libxcb
      pkgs.libxi
      pkgs.libxtst
      pkgs.pkg-config
      pkgs.python3
      pkgs.stdenv.cc
    ] ''
      python3 scripts/checks/test-moonlight-input-sources.py
      "$CC" -fsyntax-only -Wall -Wextra -Werror \
        $(pkg-config --cflags x11 xcb xi xtst) \
        modules/nixos/services/moonlight-client/kdeconnect-pointer-shim.c
    '';

  wolf-python-source-syntax = mkRepoCheck "wolf-python-source-syntax" [pkgs.python3] ''
    PYTHONPYCACHEPREFIX="$TMPDIR/pycache" python3 -m py_compile modules/nixos/services/wolf-streaming/*.py
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
    assert rpi1.users.users.alc.hashedPasswordFile != null;
      pkgs.runCommand "rpi3-direct-client-contract" {} ''
        touch "$out"
      '';

  operator-home-composition-contract = let
    inventory = import ../../inventory.nix;
    homeManagerEnabled = hostAttrs: hostAttrs.homeManager or true;
    isOperator = hostAttrs:
      lib.elem "infra-admin" inventory.roles.${hostAttrs.role}.workspaceProfiles;
    homeOutputNames = hostName: hostAttrs:
      ["alc-${hostName}"]
      ++ lib.optionals (hostAttrs.platform == "darwin")
      (map (alias: "alc-${alias}") (hostAttrs.aliases or []));
    namesFor = predicate:
      lib.concatLists (
        lib.mapAttrsToList homeOutputNames (
          lib.filterAttrs (
            hostName: hostAttrs: homeManagerEnabled hostAttrs && predicate hostName hostAttrs
          )
          inventory.hosts
        )
      );
    operatorNames = namesFor (_: hostAttrs: isOperator hostAttrs);
    nonOperatorNames = namesFor (_: hostAttrs: !isOperator hostAttrs);
    operatorHomes = map (name: self.homeConfigurations.${name}) operatorNames;
    nonOperatorHomes = map (name: self.homeConfigurations.${name}) nonOperatorNames;
  in
    assert lib.sort builtins.lessThan (operatorNames ++ nonOperatorNames)
    == lib.sort builtins.lessThan (builtins.attrNames self.homeConfigurations);
    assert lib.all (home: home.config.programs.bnBootstrap.bullet.enable) operatorHomes;
    assert lib.all (home: home.config.programs.kubernetes.managed.enable) operatorHomes;
    assert lib.all (home: !(home.options.programs ? bnBootstrap)) nonOperatorHomes;
      pkgs.runCommand "operator-home-composition-contract" {} ''
        touch "$out"
      '';
}
