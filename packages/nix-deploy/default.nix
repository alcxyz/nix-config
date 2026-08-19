{
  lib,
  stdenv,
}: let
  inventory = import ../../inventory.nix;

  hostNames = builtins.attrNames inventory.hosts;
  nixosHostNames = lib.filter (host: inventory.hosts.${host}.platform == "nixos") hostNames;
  homeManagerHostNames = lib.filter (host: inventory.hosts.${host}.homeManager or true) hostNames;

  deployableInAll = host: inventory.hosts.${host}.deployAll or true;

  deployAllHostNames =
    lib.optional (builtins.elem "xyz" nixosHostNames && deployableInAll "xyz") "xyz"
    ++ lib.filter (host: host != "xyz" && deployableInAll host) nixosHostNames;

  remoteHostNames = lib.filter (host: host != "xyz") nixosHostNames;

  aliases =
    lib.concatMap (
      host:
        map (alias: {
          inherit alias host;
        }) (inventory.hosts.${host}.aliases or [])
    )
    hostNames;

  sshHostEntries = lib.filter (entry: entry.target != entry.host) (
    map (host: {
      inherit host;
      target = inventory.hosts.${host}.sshHostname or host;
    })
    hostNames
  );
  systemSshUserEntries = lib.filter (entry: entry.user != "root") (
    map (host: {
      inherit host;
      user = inventory.hosts.${host}.systemSshUser or "root";
    })
    nixosHostNames
  );
  remoteSudoHosts = lib.filter (host: inventory.hosts.${host}.systemUseRemoteSudo or false) nixosHostNames;
  systemActivationEntries = lib.filter (entry: entry.action != "switch") (
    map (host: {
      inherit host;
      action = inventory.hosts.${host}.systemActivationMode or "switch";
    })
    nixosHostNames
  );

  bashArray = name: values: ''
    ${name}=(${lib.concatMapStringsSep " " lib.escapeShellArg values})
  '';

  bashAssoc = name: entries: keyAttr: valueAttr: ''
    declare -A ${name}=(${lib.concatMapStringsSep " " (entry: "[${lib.escapeShellArg entry.${keyAttr}}]=${lib.escapeShellArg entry.${valueAttr}}") entries})
  '';

  deployHostData =
    bashArray "KNOWN_HOSTS" hostNames
    + bashArray "HOME_MANAGER_HOSTS" homeManagerHostNames
    + bashArray "REMOTE_HOSTS" remoteHostNames
    + bashArray "DEPLOY_ALL_HOSTS" deployAllHostNames
    + bashAssoc "HOST_ALIASES" aliases "alias" "host"
    + bashAssoc "SSH_HOSTS" sshHostEntries "host" "target"
    + bashAssoc "SYSTEM_SSH_USERS" systemSshUserEntries "host" "user"
    + bashArray "SYSTEM_REMOTE_SUDO_HOSTS" remoteSudoHosts
    + bashAssoc "SYSTEM_ACTIVATION_MODES" systemActivationEntries "host" "action";
in
  stdenv.mkDerivation {
    pname = "nix-deploy";
    version = "0.1.2";

    src = ./.;

    dontBuild = true;

    installPhase = ''
      install -Dm755 deploy $out/bin/deploy
      substituteInPlace $out/bin/deploy \
        --replace-fail '@deployHostData@' ${lib.escapeShellArg deployHostData}
    '';

    meta = with lib; {
      description = "Unified NixOS/darwin + home-manager deploy tool with explicit local orchestration support";
      mainProgram = "deploy";
      platforms = platforms.unix;
    };
  }
