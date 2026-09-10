{
  self,
  lib,
  pkgs,
}: let
  k3sHosts = lib.filterAttrs (_: host: host.config.services.k3s.enable) self.nixosConfigurations;
  host = (builtins.head (builtins.attrValues k3sHosts)).config;
  prepare = host.systemd.services.container-netns-prepare;
  docker = host.systemd.services.docker;
  k3s = host.systemd.services.k3s;
  audit = host.systemd.services.container-netns-audit;
  timer = host.systemd.timers.container-netns-audit;
in
  assert builtins.elem "docker.service" prepare.before;
  assert builtins.elem "k3s.service" prepare.before;
  assert prepare.restartIfChanged == false;
  assert builtins.elem "container-netns-prepare.service" docker.requires;
  assert builtins.elem "container-netns-prepare.service" k3s.requires;
  assert timer.timerConfig.OnUnitActiveSec == "5m";
    pkgs.runCommand "container-netns-contract" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.gawk
        pkgs.shellcheck
      ];
    } ''
      audit_source=${../../modules/nixos/virtualisation/container-netns/audit.sh}
      prepare_source=${../../modules/nixos/virtualisation/container-netns/prepare.sh}
      prepare_test=${./test-container-netns-prepare.sh}
      fixtures=${./fixtures/container-netns}

      shellcheck --shell=bash "$audit_source"
      shellcheck --shell=bash "$prepare_source" "$prepare_test"
      bash "$prepare_test" "$prepare_source"
      bash "$audit_source" "$fixtures/healthy.mountinfo"

      if bash "$audit_source" "$fixtures/hidden.mountinfo" >hidden.out 2>hidden.err; then
        echo "audit accepted a mount hidden outside the /run/netns subtree" >&2
        exit 1
      fi
      grep -Fq 'is outside the /run/netns mount subtree' hidden.err

      if bash "$audit_source" "$fixtures/unshared.mountinfo" >unshared.out 2>unshared.err; then
        echo "audit accepted an unshared /run/netns mount" >&2
        exit 1
      fi
      grep -Fq '/run/netns is not a shared mount' unshared.err

      grep -Fq 'container-netns-audit' ${lib.escapeShellArg audit.serviceConfig.ExecStart}
      touch "$out"
    ''
