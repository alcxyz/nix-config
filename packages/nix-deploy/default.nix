{
  lib,
  stdenv,
}: let
  inventory = import ../../inventory.nix;

  hostNames = builtins.attrNames inventory.hosts;
  nixosHostNames = lib.filter (host: inventory.hosts.${host}.platform == "nixos") hostNames;

  deployAllHostNames =
    lib.optional (builtins.elem "xyz" nixosHostNames) "xyz"
    ++ lib.filter (host: host != "xyz") nixosHostNames;

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

  bashArray = name: values: ''
    ${name}=(${lib.concatMapStringsSep " " lib.escapeShellArg values})
  '';

  bashAssoc = name: entries: keyAttr: valueAttr: ''
    declare -A ${name}=(${lib.concatMapStringsSep " " (entry: "[${lib.escapeShellArg entry.${keyAttr}}]=${lib.escapeShellArg entry.${valueAttr}}") entries})
  '';

  deployHostData =
    bashArray "KNOWN_HOSTS" hostNames
    + bashArray "REMOTE_HOSTS" remoteHostNames
    + bashArray "DEPLOY_ALL_HOSTS" deployAllHostNames
    + bashAssoc "HOST_ALIASES" aliases "alias" "host"
    + bashAssoc "SSH_HOSTS" sshHostEntries "host" "target";
in
  stdenv.mkDerivation {
    pname = "nix-deploy";
    version = "0.1.1";

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
