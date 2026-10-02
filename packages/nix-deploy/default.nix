{
  lib,
  coreutils,
  gawk,
  git,
  jq,
  nixDeploy,
  writeShellApplication,
  writeShellScriptBin,
  writeText,
}: let
  inventory = import ../../inventory.nix;

  hostNames = builtins.attrNames inventory.hosts;
  nixosHostNames = lib.filter (host: inventory.hosts.${host}.platform == "nixos") hostNames;
  homeManagerHostNames = lib.filter (host: inventory.hosts.${host}.homeManager or true) hostNames;
  deployableInAll = host: inventory.hosts.${host}.deployAll or true;
  # Embedded-etcd members switch one at a time behind a readiness gate so a
  # fleet deploy cannot disrupt more than one quorum member at once (#511).
  k3sServerHostNames =
    lib.filter (
      host: let
        role = inventory.hosts.${host}.k8sRole or null;
      in
        role != null && inventory.k8sRoles.${role}.role == "server"
    )
    nixosHostNames;

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
    serialSystemHosts = k3sServerHostNames;
    # The node's own API server must be ready (this includes etcd health) and
    # the control plane must report the node Ready. kubectl comes from PATH so
    # the managed kubeconfig wrapper applies; the context is pinned so a
    # switched kubectx cannot point the gate at another cluster.
    serialReadyCommand = "kubectl --context funhouse --request-timeout=10s --server https://{host}:6443 get --raw=/readyz >/dev/null && kubectl --context funhouse wait --for=condition=Ready node/{host} --timeout=30s";
    serialReadyTimeoutSeconds = 600;
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
  # Warns, without failing or changing the checkout, when the lock differs from
  # the validated package revision (ADR-0080).
  lockCheck = writeShellApplication {
    name = "nix-deploy-lock-check";
    runtimeInputs = [coreutils gawk git jq];
    text = builtins.readFile ../../scripts/update-inputs/lock-promoted-packages.sh;
  };
  wrapper = writeShellScriptBin "deploy" ''
    ${lockCheck}/bin/nix-deploy-lock-check --check || true
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
