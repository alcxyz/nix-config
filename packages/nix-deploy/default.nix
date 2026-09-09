{
  lib,
  nixDeploy,
  writeShellScriptBin,
  writeText,
}: let
  inventory = import ../../inventory.nix;

  hostNames = builtins.attrNames inventory.hosts;
  nixosHostNames = lib.filter (host: inventory.hosts.${host}.platform == "nixos") hostNames;
  homeManagerHostNames = lib.filter (host: inventory.hosts.${host}.homeManager or true) hostNames;
  deployableInAll = host: inventory.hosts.${host}.deployAll or true;

  deployAllHostNames =
    lib.optional (builtins.elem "xyz" nixosHostNames && deployableInAll "xyz") "xyz"
    ++ lib.filter (host: host != "xyz" && deployableInAll host) nixosHostNames;

  aliases = builtins.listToAttrs (lib.concatMap (
      host:
        map (alias: {
          name = alias;
          value = host;
        }) (inventory.hosts.${host}.aliases or [])
    )
    hostNames);

  sshHosts = builtins.listToAttrs (lib.filter (entry: entry.value != entry.name) (
    map (host: {
      name = host;
      value = inventory.hosts.${host}.sshHostname or host;
    })
    hostNames
  ));

  systemSshUsers = builtins.listToAttrs (lib.filter (entry: entry.value != "root") (
    map (host: {
      name = host;
      value = inventory.hosts.${host}.systemSshUser or "root";
    })
    nixosHostNames
  ));

  systemActivationModes = builtins.listToAttrs (lib.filter (entry: entry.value != "switch") (
    map (host: {
      name = host;
      value = inventory.hosts.${host}.systemActivationMode or "switch";
    })
    nixosHostNames
  ));

  config = {
    schemaVersion = 1;
    operatorHost = "xyz";
    homeManagerUser = "alc";
    homeOutputPrefix = "alc-";
    knownHosts = hostNames;
    homeManagerHosts = homeManagerHostNames;
    remoteHosts = lib.filter (host: host != "xyz") nixosHostNames;
    deployAllHosts = deployAllHostNames;
    inherit aliases sshHosts systemSshUsers systemActivationModes;
    systemRemoteSudoHosts = lib.filter (host: inventory.hosts.${host}.systemUseRemoteSudo or false) nixosHostNames;
    hostColors = {
      xyz = "137;180;250";
      nux = "166;227;161";
      nex = "249;226;175";
      xev = "148;226;213";
      xps = "245;194;231";
      rpi0 = "235;160;172";
      mac = "203;166;247";
    };
  };

  configFile = writeText "nix-deploy-inventory-v1.json" (builtins.toJSON config);
  wrapper = writeShellScriptBin "deploy" ''
    exec ${nixDeploy}/bin/deploy --config "''${NIX_DEPLOY_CONFIG:-${configFile}}" "$@"
  '';
in
  wrapper.overrideAttrs (_: {
    pname = "nix-deploy-configured";
    version = "0.2.0";
    passthru = {
      deployConfig = configFile;
      unconfiguredPackage = nixDeploy;
    };
    meta =
      nixDeploy.meta
      // {
        description = "nix-deploy configured from the nix-config public inventory";
      };
  })
