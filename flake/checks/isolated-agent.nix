{
  inputs,
  pkgs,
}: let
  evaluate = extra:
    (inputs.nixpkgs.lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../../modules/nixos/services/isolated-agent
        {
          services.isolated-agent = {
            enable = true;
            package = pkgs.hello;
            providerPackages = [];
          };
          system.stateVersion = "25.11";
        }
        extra
      ];
    }).config;
  base = evaluate {};
  service = base.systemd.services.isolated-agent;
  ordered = evaluate ({lib, ...}: {
    security.sudo.extraConfig = lib.mkAfter "ALL ALL=(ALL:ALL) NOPASSWD: ALL";
    security.polkit.extraConfig = lib.mkBefore "polkit.addRule(function() { return polkit.Result.YES; });";
  });
  hasFailure = configuration:
    builtins.any (entry: !entry.assertion && pkgs.lib.hasInfix "isolated agent" entry.message) configuration.assertions;
in
  assert base.users.users.isolated-agent.extraGroups == [];
  assert builtins.elem base.services.isolated-agent.package base.users.users.isolated-agent.packages;
  assert base.users.users.isolated-agent.homeMode == "0700";
  assert service.wantedBy == [];
  assert service.serviceConfig.NoNewPrivileges;
  assert service.serviceConfig.ProtectHome;
  assert service.serviceConfig.PrivateDevices;
  assert service.serviceConfig.CapabilityBoundingSet == "";
  assert pkgs.lib.hasInfix " start --mode desktop --no-browser " service.serviceConfig.ExecStart;
  assert service.serviceConfig.StandardOutput == "null" && service.serviceConfig.StandardError == "null";
  assert builtins.elem "/run/secrets" (map (builtins.replaceStrings ["-"] [""]) service.serviceConfig.InaccessiblePaths);
  assert hasFailure (evaluate {users.users.isolated-agent.extraGroups = ["wheel"];});
  assert hasFailure (evaluate {users.groups.docker.members = ["isolated-agent"];});
  assert hasFailure (evaluate {nix.settings.trusted-users = ["isolated-agent"];});
  assert hasFailure (evaluate {nix.settings.trusted-users = ["@isolated-agent"];});
  assert hasFailure (evaluate {nix.settings.trusted-users = ["*"];});
  assert pkgs.lib.hasSuffix "isolated-agent ALL=(ALL:ALL) !ALL\n" ordered.security.sudo.extraConfig;
  assert pkgs.lib.hasPrefix "polkit.addRule(function(action, subject)" ordered.security.polkit.extraConfig;
  assert hasFailure (evaluate ({lib, ...}: {security.sudo.extraConfig = lib.mkOrder 2500 "ALL ALL=(ALL:ALL) ALL";}));
  assert hasFailure (evaluate ({lib, ...}: {security.polkit.extraConfig = lib.mkOrder (-1) "polkit.addRule(function() { return polkit.Result.YES; });";}));
    pkgs.runCommand "isolated-agent-contract" {} "touch $out"
