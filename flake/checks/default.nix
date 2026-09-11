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

  nsswitch-hosts-contract = import ./nsswitch-hosts.nix {inherit inputs lib pkgs;};

  moonlight-endpoint-setup-contract = import ./moonlight-endpoints.nix {inherit lib pkgs;};

  credential-consent-contract = import ./credential-consent.nix {inherit lib pkgs;};

  forgejo-runner-isolated-docker-contract = import ./forgejo-isolated-docker.nix {inherit lib pkgs;};

  forgejo-runner-pool-contract = let
    runnerHosts = {
      inherit
        (self.nixosConfigurations)
        nex
        nux
        xev
        xyz
        ;
    };
    runners = lib.mapAttrs (_: host: host.config.services.forgejo-actions-runner) runnerHosts;
    runnerUnits = lib.mapAttrs (_: host: host.config.systemd.services.forgejo-actions-runner) runnerHosts;
    runnerStarts = map (unit: lib.removeSuffix " " unit.serviceConfig.ExecStart) (lib.attrValues runnerUnits);
    hasLabel = name: runner: lib.any (label: lib.hasPrefix "${name}:docker://" label) runner.labels;
  in
    assert lib.all (runner: runner.enable) (lib.attrValues runners);
    assert runners.xyz.capacity == 2;
    assert lib.all (runner: runner.capacity == 1) [runners.xev runners.nux runners.nex];
    assert lib.all (hasLabel "forgejo-docker-primary") (lib.attrValues runners);
    assert lib.all (hasLabel "ubuntu-latest") (lib.attrValues runners);
    assert lib.all (hasLabel "docker") (lib.attrValues runners);
    assert lib.all (unit: unit.serviceConfig.TimeoutStopSec == "3660s") (lib.attrValues runnerUnits);
      pkgs.runCommand "forgejo-runner-pool-contract" {
        nativeBuildInputs = [pkgs.gawk pkgs.gnugrep];
      } ''
        ${lib.concatMapStringsSep "\n" (runnerStart: ''
            runner_config="$(awk '/--config/ { print $NF }' ${lib.escapeShellArg runnerStart})"
            grep -Fxq '  timeout: 3600s' "$runner_config"
            grep -Fxq '  shutdown_timeout: 3600s' "$runner_config"
          '')
          runnerStarts}
        touch "$out"
      '';

  forgejo-runner-resource-policy-contract = let
    xyz = self.nixosConfigurations.xyz.config;
    runner = xyz.services.forgejo-actions-runner;
    runnerUnit = xyz.systemd.services.forgejo-actions-runner;
    policyUnit = xyz.systemd.services.forgejo-runner-resource-policy;
    daemonUnit = xyz.systemd.services.forgejo-runner-docker;
    buildSlice = xyz.systemd.slices.forgejobuilds.sliceConfig;
    isolatedServerConfigs = [
      self.nixosConfigurations.nux.config
      self.nixosConfigurations.nex.config
    ];
    isolatedServerRunners = map (host: host.services.forgejo-actions-runner) isolatedServerConfigs;
    xev = self.nixosConfigurations.xev.config;
    xevRunner = xev.services.forgejo-actions-runner;
    mockGetconf = pkgs.writeShellScript "mock-getconf" ''
      test "''${1:-}" = _NPROCESSORS_ONLN
      printf '%s\n' "''${MOCK_PROCESSORS:?}"
    '';
    mockSystemctl = pkgs.writeShellScript "mock-systemctl" ''
      printf '%s\n' "$*" > "''${FORGEJO_RUNNER_TEST_OUTPUT:?}"
    '';
  in
    assert runner.resourcePolicy.enable;
    assert runner.isolatedDocker.enable;
    assert !(builtins.elem "--cgroup-parent=forgejobuilds.slice" runner.containerOptions);
    assert daemonUnit.serviceConfig.Slice == "forgejobuilds.slice";
    assert lib.all (serverRunner: serverRunner.resourcePolicy.enable && serverRunner.isolatedDocker.enable) isolatedServerRunners;
    assert lib.all (serverRunner: serverRunner.dockerHost == "unix:///run/forgejo-docker/docker.sock") isolatedServerRunners;
    assert lib.all (host: builtins.elem "forgejo-runner-docker.service" host.systemd.services.forgejo-actions-runner.requires) isolatedServerConfigs;
    assert lib.all (host: !(builtins.elem "docker.service" host.systemd.services.forgejo-actions-runner.requires)) isolatedServerConfigs;
    assert lib.all (host: host.users.users.forgejo-runner.extraGroups == []) isolatedServerConfigs;
    assert !xevRunner.resourcePolicy.enable && !xevRunner.isolatedDocker.enable;
    assert xevRunner.dockerHost == "unix:///var/run/docker.sock";
    assert builtins.elem "docker.service" xev.systemd.services.forgejo-actions-runner.requires;
    assert xev.users.users.forgejo-runner.extraGroups == ["docker"];
    assert buildSlice.CPUWeight == 10;
    assert buildSlice.IOWeight == 10;
    assert buildSlice.MemoryHigh == "40%";
    assert buildSlice.MemoryMax == "50%";
    assert !(xyz.virtualisation.docker.daemon.settings ? "exec-opts");
    assert builtins.elem "forgejo-runner-resource-policy.service" runnerUnit.after;
    assert builtins.elem "forgejo-runner-resource-policy.service" runnerUnit.requires;
    assert builtins.elem "forgejobuilds.slice" policyUnit.after;
    assert builtins.elem "forgejobuilds.slice" policyUnit.requires;
    assert policyUnit.partOf == [];
      pkgs.runCommand "forgejo-runner-resource-policy-contract" {} ''
        for fixture in "4 200" "5 250" "32 1600"; do
          set -- $fixture
          output="$TMPDIR/systemctl-$1"
          MOCK_PROCESSORS="$1" \
            FORGEJO_RUNNER_GETCONF=${mockGetconf} \
            FORGEJO_RUNNER_SYSTEMCTL=${mockSystemctl} \
            FORGEJO_RUNNER_TEST_OUTPUT="$output" \
            ${policyUnit.serviceConfig.ExecStart}
          test "$(cat "$output")" = "set-property --runtime forgejobuilds.slice CPUQuota=$2%"
        done

        for invalid_count in 0 invalid; do
          output="$TMPDIR/invalid-systemctl-$invalid_count"
          if MOCK_PROCESSORS="$invalid_count" \
            FORGEJO_RUNNER_GETCONF=${mockGetconf} \
            FORGEJO_RUNNER_SYSTEMCTL=${mockSystemctl} \
            FORGEJO_RUNNER_TEST_OUTPUT="$output" \
            ${policyUnit.serviceConfig.ExecStart}; then
            echo "resource policy accepted invalid processor count: $invalid_count" >&2
            exit 1
          fi
          test ! -e "$output"
        done
        touch "$out"
      '';

  forgejo-runner-io-pressure-guard-contract = let
    hostNames = [
      "nex"
      "nux"
      "xev"
      "xyz"
    ];
    hostConfigs = lib.genAttrs hostNames (name: self.nixosConfigurations.${name}.config);
    isolatedHostNames = [
      "nex"
      "nux"
      "xyz"
    ];
    isolatedGuards = map (name: hostConfigs.${name}.systemd.services.forgejo-runner-io-pressure-guard) isolatedHostNames;
    xevGuard = hostConfigs.xev.systemd.services.forgejo-runner-io-pressure-guard;
    legacyConfig =
      (import "${pkgs.path}/nixos/lib/eval-config.nix" {
        # This fixture evaluates a NixOS service even when the surrounding
        # flake check is instantiated for a non-Linux system.
        system = "x86_64-linux";
        specialArgs.inputs = {};
        modules = [
          ../../modules/nixos/services/forgejo-actions-runner
          ({lib, ...}: {
            options.sops.secrets = lib.mkOption {
              type = lib.types.attrs;
              default = {};
            };
            config = {
              system.stateVersion = "25.11";
              virtualisation.docker.enable = true;
              services.forgejo-actions-runner = {
                enable = true;
                ioPressureGuard.enable = true;
                labels = ["test:docker://example.invalid/test:latest"];
                secretsFile = pkgs.writeText "dummy-runner-secrets.yaml" "dummy: encrypted-fixture";
              };
            };
          })
        ];
      }).config;
    legacyGuard = legacyConfig.systemd.services.forgejo-runner-io-pressure-guard;
    guardStart = legacyGuard.serviceConfig.ExecStart;
    runners = map (name: hostConfigs.${name}.systemd.services.forgejo-actions-runner) hostNames;
    legacyRunnerStart = lib.removeSuffix " " legacyConfig.systemd.services.forgejo-actions-runner.serviceConfig.ExecStart;
    xevRunnerStart = lib.removeSuffix " " hostConfigs.xev.systemd.services.forgejo-actions-runner.serviceConfig.ExecStart;
    guardSource = ../../modules/nixos/services/forgejo-actions-runner/io-pressure-guard.sh;
    guardTest = ./test-forgejo-runner-io-pressure-guard.sh;
  in
    assert legacyGuard.wantedBy == ["multi-user.target"];
    assert lib.hasPrefix "io.alc.forgejo-runner=" legacyGuard.environment.RUNNER_CONTAINER_LABEL;
    assert legacyGuard.environment.HIGH_SAMPLES_REQUIRED == "5";
    assert legacyGuard.environment.LOW_SAMPLES_REQUIRED == "13";
    assert xevGuard.wantedBy == ["multi-user.target"];
    assert lib.hasPrefix "io.alc.forgejo-runner=" xevGuard.environment.RUNNER_CONTAINER_LABEL;
    assert xevGuard.environment.HIGH_SAMPLES_REQUIRED == "5";
    assert xevGuard.environment.LOW_SAMPLES_REQUIRED == "13";
    assert lib.all (guard: guard.wantedBy == []) isolatedGuards;
    assert lib.all (guard: !(guard.environment ? RUNNER_CONTAINER_LABEL)) isolatedGuards;
    assert lib.all (guard: guard.environment.HIGH_SAMPLES_REQUIRED == "5") isolatedGuards;
    assert lib.all (guard: guard.environment.LOW_SAMPLES_REQUIRED == "13") isolatedGuards;
    assert lib.all (guard: guard.environment.TRANSITION_TIMEOUT_SECONDS == "120") isolatedGuards;
    assert lib.all (runner: builtins.elem "forgejo-runner-io-pressure-guard.service" runner.requires) runners;
    assert lib.all (runner: runner.bindsTo == ["forgejo-runner-io-pressure-guard.service"]) runners;
      pkgs.runCommand "forgejo-runner-io-pressure-guard-contract" {
        nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.ripgrep pkgs.shellcheck];
      } ''
        shellcheck ${guardSource} ${guardTest}
        bash ${guardTest} ${guardStart}
        runner_config="$(${pkgs.gawk}/bin/awk '/--config/ { print $NF }' ${lib.escapeShellArg legacyRunnerStart})"
        grep -Fq -- '--label=io.alc.forgejo-runner=' "$runner_config"
        xev_runner_config="$(${pkgs.gawk}/bin/awk '/--config/ { print $NF }' ${lib.escapeShellArg xevRunnerStart})"
        grep -Fq -- '--label=io.alc.forgejo-runner=' "$xev_runner_config"
        touch "$out"
      '';
  forgejo-runner-registration-contract = let
    source = ../../modules/nixos/services/forgejo-actions-runner/register-from-file.sh;
    test = ./test-forgejo-runner-registration.sh;
    helper = pkgs.writeShellApplication {
      name = "forgejo-runner-register-from-file-test";
      runtimeInputs = [pkgs.coreutils];
      text = builtins.readFile source;
    };
  in
    pkgs.runCommand "forgejo-runner-registration-contract" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.shellcheck];
    } ''
      shellcheck ${source} ${test}
      bash ${test} ${lib.getExe helper}
      touch "$out"
    '';
  container-netns-contract = import ./container-netns.nix {inherit self lib pkgs;};

  game-window-geometry-contract = mkRepoCheck "game-window-geometry-contract" [pkgs.bash pkgs.jq pkgs.gawk pkgs.gnused] ''
    bash scripts/checks/test-game-window-geometry-guard.sh
  '';

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

  wolf-image-publisher-contract = mkRepoCheck "wolf-image-publisher-contract" [pkgs.bash pkgs.coreutils pkgs.jq pkgs.ripgrep pkgs.gnused] ''
    bash scripts/checks/test-publish-wolf-images.sh
  '';

  xyz-runtime-storage-policy-contract = mkRepoCheck "xyz-runtime-storage-policy-contract" [pkgs.bash pkgs.coreutils pkgs.ripgrep pkgs.gnused] ''
    bash scripts/checks/test-xyz-runtime-storage-policy.sh hosts/xyz/xyz-runtime-storage-policy.sh
  '';

  storage-health-monitor-contract = let
    host = self.nixosConfigurations.xyz.config;
    monitored = host.services.storage-health-monitor.units;
    recent = builtins.filter (unit: unit.mode == "recent-success") monitored;
    serviceFor = unit: host.systemd.services.${lib.removeSuffix ".service" unit.name};
  in
    assert lib.all (unit: builtins.length (serviceFor unit).serviceConfig.ExecStopPost == 1) recent;
      mkRepoCheck "storage-health-monitor-contract" [pkgs.bash pkgs.coreutils pkgs.gawk pkgs.gnugrep] ''
        bash modules/nixos/services/storage-health-monitor/test-storage-health-monitor.sh \
          modules/nixos/services/storage-health-monitor/record-success.sh \
          modules/nixos/services/storage-health-monitor/check-recent-success.sh
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
    home = self.homeConfigurations.alc-xyz;
    upstreamHome = home.extendModules {
      modules = [
        {
          services.t3code.channel = lib.mkForce "upstream";
          services.t3code.package = lib.mkForce home.config.services.t3code.package;
        }
      ];
    };
    forkHome = home.extendModules {
      modules = [
        {
          services.t3code.channel = lib.mkForce "fork";
          # Exercise channel behavior independently of the producer lock.
          services.t3code.package = lib.mkForce home.config.services.t3code.package;
        }
      ];
    };
    t3Unit = self.homeConfigurations.alc-xyz.config.systemd.user.services.t3code.Unit;
    unit = self.homeConfigurations.alc-xyz.config.systemd.user.services.t3code-auto-update.Unit;
    service = self.homeConfigurations.alc-xyz.config.systemd.user.services.t3code-auto-update.Service;
    timer = self.homeConfigurations.alc-xyz.config.systemd.user.timers.t3code-auto-update.Timer;
    updater = builtins.head service.ExecStart;
    guard = lib.removePrefix "run " upstreamHome.config.home.activation.t3codeRestartGuard.data;
    applyManagedUnit = self.homeConfigurations.alc-xyz.config.home.activation.t3codeApplyManagedUnit.data;
    forkGuard = lib.removePrefix "run " forkHome.config.home.activation.t3codeRestartGuard.data;
  in
    assert forkHome.config.services.t3code.baseDir == home.config.services.t3code.baseDir;
    assert forkHome.config.systemd.user.services.t3code.Service.ExecStart == home.config.systemd.user.services.t3code.Service.ExecStart;
    assert t3Unit.X-RestartIfChanged == false;
    assert unit.X-RestartIfChanged == false;
    assert service.Restart == "on-failure";
    assert service.RestartForceExitStatus == "75";
    assert service.RestartPreventExitStatus == "76";
    assert timer.OnCalendar == "*-*-* 09:30:00";
      pkgs.runCommand "t3code-auto-update-contract" {nativeBuildInputs = [pkgs.gnugrep pkgs.python3];} ''
        python3 ${../../modules/home-manager/services/t3code/test-channel-guard.py} ${lib.escapeShellArg (lib.removeSuffix "\n" guard)} ${lib.escapeShellArg (lib.removeSuffix "\n" forkGuard)}
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
    directClients = [rpi1 rpi2 rpi3];
    hasPackage = name: client:
      lib.any (package: lib.getName package == name) client.environment.systemPackages;
    hasSudoCommand = name: client:
      lib.any (rule:
        lib.any (entry: lib.hasSuffix "/bin/${name}" entry.command) rule.commands)
      client.security.sudo.extraRules;
    hasSteamLifecycle = client:
      lib.all (name: hasPackage name client && hasSudoCommand name client) [
        "steam-start"
        "steam-stop"
        "steam-wake"
      ];
  in
    assert rpi1.services.nixbox-direct-client.streamFps == 30;
    assert rpi2.services.nixbox-direct-client.streamFps == 60;
    assert rpi3.services.nixbox-direct-client.streamFps == 60;
    assert rpi1.services.nixbox-direct-client.package.pname == "moonlight-rpi3";
    assert rpi2.services.nixbox-direct-client.package.pname == "moonlight-rpi3";
    assert rpi3.services.nixbox-direct-client.package.pname == "moonlight-rpi3";
    assert rpi1.services.moonlight-client.defaultSessionMode == "direct-browser";
    assert lib.all hasSteamLifecycle directClients;
    assert lib.all
    (client: lib.hasInfix "/bin/steam-start" client.services.moonlight-client.streamHostStartCommand)
    directClients;
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
    forgeMirrorActivation = home: home.config.home.activation.forgejoPrimary;
    forgeMirrorActivationDependencies = [
      "linkGeneration"
      "workspaceDirs"
      "sops-nix"
    ];
    forgeMirrorSessionVariables = [
      "FORGEJO_URL"
      "FORGEJO_USER"
      "FORGEJO_SSH_HOST"
      "FORGE_MIRROR_SCAN_ROOTS_FILE"
      "FORGE_MIRROR_GITHUB_PRIMARY_REPOS_FILE"
      "FORGEJO_TOKEN_FILE"
    ];
    forgeMirrorActivationVariables = map (name: "${name}=") forgeMirrorSessionVariables;
  in
    assert lib.sort builtins.lessThan (operatorNames ++ nonOperatorNames)
    == lib.sort builtins.lessThan (builtins.attrNames self.homeConfigurations);
    assert lib.all (home: home.config.programs.bnBootstrap.bullet.enable) operatorHomes;
    assert lib.all (home: home.config.programs.kubernetes.managed.enable) operatorHomes;
    assert lib.all (home: builtins.elem home.pkgs.forge-mirror home.config.home.packages) operatorHomes;
    assert lib.all (home: !(home.options.programs ? bnBootstrap)) nonOperatorHomes;
    assert lib.all (home: !(home.config.home.activation ? forgejoPrimary)) nonOperatorHomes;
    assert lib.all (home:
      lib.all (name:
        builtins.hasAttr name home.config.home.sessionVariables
        && toString home.config.home.sessionVariables.${name} != "")
      forgeMirrorSessionVariables)
    operatorHomes;
    assert lib.all (home:
      lib.all (dependency: lib.elem dependency (forgeMirrorActivation home).after)
      forgeMirrorActivationDependencies)
    operatorHomes;
    assert lib.all (home:
      lib.all (variable: lib.hasInfix variable (forgeMirrorActivation home).data)
      forgeMirrorActivationVariables)
    operatorHomes;
    assert lib.all (home: lib.hasInfix "/bin/forge-mirror primary" (forgeMirrorActivation home).data) operatorHomes;
    assert lib.all (home: lib.hasInfix "could not update repository remotes; continuing" (forgeMirrorActivation home).data) operatorHomes;
    assert lib.all (home: !(lib.hasInfix "FORGE_MIRROR_GITHUB_PRIMARY_REPOS=" (forgeMirrorActivation home).data)) operatorHomes;
    assert lib.all (home: !(lib.hasInfix "2>/dev/null" (forgeMirrorActivation home).data)) operatorHomes;
      pkgs.runCommand "operator-home-composition-contract" {} ''
        touch "$out"
      '';
}
