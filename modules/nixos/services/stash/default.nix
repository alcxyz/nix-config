# modules/nixos/services/stash/default.nix
{
  config,
  inputs,
  lib,
  pkgs,
  username,
  ...
}:

with lib;

let
  cfg = config.services.stash.managed;
  system = pkgs.stdenv.hostPlatform.system;
  legacyDataDir = "/ypool/vault/stash";
  preStartScript = pkgs.writeShellScript "stash-pre-start" ''
    install -d -m 0750 -o ${cfg.user} -g ${cfg.group} \
      ${cfg.dataDir} \
      ${cfg.dataDir}/config \
      ${cfg.dataDir}/metadata \
      ${cfg.dataDir}/cache \
      ${cfg.dataDir}/blobs \
      ${cfg.dataDir}/generated

    legacy_migration_marker=${cfg.dataDir}/config/.legacy-appdata-migrated
    if [ -d ${lib.escapeShellArg legacyDataDir} ] && [ ! -e "$legacy_migration_marker" ]; then
      if [ -d ${lib.escapeShellArg (legacyDataDir + "/config")} ]; then
        ${lib.getExe pkgs.rsync} -a --ignore-existing \
          ${lib.escapeShellArg (legacyDataDir + "/config/")} \
          ${lib.escapeShellArg (cfg.dataDir + "/config/")}
      fi

      for state_dir in metadata cache blobs generated; do
        if [ -d ${lib.escapeShellArg legacyDataDir}/"$state_dir" ]; then
          ${lib.getExe pkgs.rsync} -a --ignore-existing \
            ${lib.escapeShellArg legacyDataDir}/"$state_dir"/ \
            ${lib.escapeShellArg cfg.dataDir}/"$state_dir"/
        fi
      done

      touch "$legacy_migration_marker"
    fi

    permission_marker=${cfg.dataDir}/config/.native-permissions-v3
    if [ ! -e "$permission_marker" ]; then
      find \
        ${cfg.dataDir}/config \
        ${cfg.dataDir}/metadata \
        ${cfg.dataDir}/cache \
        ${cfg.dataDir}/blobs \
        ${cfg.dataDir}/generated \
        -type d -exec chmod 0750 {} +

      find \
        ${cfg.dataDir}/config \
        ${cfg.dataDir}/metadata \
        ${cfg.dataDir}/cache \
        ${cfg.dataDir}/blobs \
        ${cfg.dataDir}/generated \
        -type f -exec chmod 0660 {} +

      touch "$permission_marker"
      chmod 0640 "$permission_marker"
    fi

    chown -R ${cfg.user}:${cfg.group} \
      ${cfg.dataDir}/config \
      ${cfg.dataDir}/metadata \
      ${cfg.dataDir}/cache \
      ${cfg.dataDir}/blobs \
      ${cfg.dataDir}/generated

    if [ ! -f ${cfg.dataDir}/config/config.yml ]; then
      echo "Refusing to start Stash: ${cfg.dataDir}/config/config.yml is missing." >&2
      exit 1
    fi

    if [ ! -f ${cfg.dataDir}/config/stash-go.sqlite ]; then
      echo "Refusing to start Stash: ${cfg.dataDir}/config/stash-go.sqlite is missing." >&2
      exit 1
    fi

    current_database="$(${lib.getExe pkgs.yq-go} '.database' ${cfg.dataDir}/config/config.yml)"
    if [ "$current_database" = "/root/.stash/stash-go.sqlite" ] || [ "$current_database" = "${legacyDataDir}/config/stash-go.sqlite" ]; then
      cp -an ${cfg.dataDir}/config/config.yml ${cfg.dataDir}/config/config.yml.pre-native-paths
      ${lib.getExe pkgs.yq-go} -i '
        .database = "${cfg.dataDir}/config/stash-go.sqlite" |
        .generated = "/generated" |
        .metadata = "/metadata" |
        .cache = "/cache" |
        .blobs_path = "/blobs"
      ' ${cfg.dataDir}/config/config.yml
      chown ${cfg.user}:${cfg.group} ${cfg.dataDir}/config/config.yml
      chmod 0660 ${cfg.dataDir}/config/config.yml
    fi
  '';
in
{
  options.services.stash.managed = {
    enable = mkEnableOption "Stash (managed as a native systemd service)";

    package = mkOption {
      type = types.package;
      default = inputs.nix-packages.packages.${system}.stash;
      defaultText = literalExpression "inputs.nix-packages.packages.\${pkgs.stdenv.hostPlatform.system}.stash";
      description = "Stash package to run.";
    };

    user = mkOption {
      type = types.str;
      default = "stash";
      description = "User for Stash file ownership.";
    };
    group = mkOption {
      type = types.str;
      default = "stash";
      description = "Group for Stash file ownership.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/stash";
      description = "Directory for Stash data (config, database, etc.).";
    };
    mediaDir = mkOption {
      type = types.path;
      default = "/zpool/stash";
      description = "Directory where Stash media is located.";
    };
  };

  config = mkIf cfg.enable {
    users.groups.media = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      extraGroups = [
        "media"
        "nogroup"
        "rtorrent"
        "render"
        "video"
      ];
    };
    users.groups.${cfg.group} = { };

    users.users.${username}.extraGroups = [ cfg.group ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/config 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/metadata 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/cache 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/blobs 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/generated 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.mediaDir} 2775 ${cfg.user} media - -"
      "a+ ${cfg.mediaDir} - - - - g:media:rwx,d:g:media:rwx,m::rwx,d:m::rwx"
    ];

    networking.firewall.allowedTCPPorts = [ 9999 ];

    systemd.services.stash = {
      description = "Stash media organizer";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      after = [
        "network.target"
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      conflicts = [ "docker-stash.service" ];

      path = with pkgs; [
        ffmpeg-full
        python3
        ruby
      ];

      environment = {
        STASH_CONFIG_FILE = "${cfg.dataDir}/config/config.yml";
      };

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        SupplementaryGroups = [
          "media"
          "nogroup"
          "rtorrent"
          "render"
          "video"
        ];
        WorkingDirectory = "${cfg.dataDir}/config";
        ExecStartPre = "+${preStartScript}";
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStartSec = "30min";

        BindPaths = [
          "${cfg.dataDir}/generated:/generated"
          "${cfg.dataDir}/metadata:/metadata"
          "${cfg.dataDir}/cache:/cache"
          "${cfg.dataDir}/blobs:/blobs"
        ];

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          cfg.dataDir
          "/zpool/stash"
        ];
      };
    };
  };
}
