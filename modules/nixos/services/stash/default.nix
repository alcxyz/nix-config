# modules/nixos/services/stash/default.nix
{
  config,
  inputs,
  lib,
  pkgs,
  username,
  ...
}:
with lib; let
  cfg = config.services.stash.managed;
  system = pkgs.stdenv.hostPlatform.system;
  stateDirs = [
    "blobs"
    "cache"
    "generated"
    "metadata"
  ];
  preStartScript = pkgs.writeShellScript "stash-pre-start" ''
    install -d -m 0750 -o ${cfg.user} -g ${cfg.group} \
      ${cfg.dataDir} \
      ${cfg.dataDir}/config \
      ${lib.concatMapStringsSep " \\\n      " (dir: "${cfg.dataDir}/config/${dir}") stateDirs}

    permission_marker=${cfg.dataDir}/config/.native-permissions-v4
    if [ ! -e "$permission_marker" ]; then
      find \
        ${cfg.dataDir}/config \
        ${lib.concatMapStringsSep " \\\n        " (dir: "${cfg.dataDir}/config/${dir}") stateDirs} \
        -type d -exec chmod 0750 {} +

      find \
        ${cfg.dataDir}/config \
        ${lib.concatMapStringsSep " \\\n        " (dir: "${cfg.dataDir}/config/${dir}") stateDirs} \
        -type f -exec chmod 0660 {} +

      touch "$permission_marker"
      chmod 0640 "$permission_marker"
    fi

    chown -R ${cfg.user}:${cfg.group} \
      ${cfg.dataDir}/config \
      ${lib.concatMapStringsSep " \\\n      " (dir: "${cfg.dataDir}/config/${dir}") stateDirs}

    if [ ! -f ${cfg.dataDir}/config/config.yml ] || [ ! -f ${cfg.dataDir}/config/stash-go.sqlite ]; then
      echo "Stash state is incomplete; allowing Stash to bootstrap fresh state." >&2
    fi
  '';
in {
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
      default = "/tank/stash";
      description = "Directory where Stash media is located.";
    };
  };

  config = mkIf cfg.enable {
    users.groups.media = {};
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
    users.groups.${cfg.group} = {};

    users.users.${username}.extraGroups = [cfg.group];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/config 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/config/metadata 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/config/cache 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/config/blobs 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/config/generated 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.mediaDir} 2775 ${cfg.user} media - -"
      "a+ ${cfg.mediaDir} - - - - g:media:rwx,d:g:media:rwx,m::rwx,d:m::rwx"
    ];

    networking.firewall.allowedTCPPorts = [9999];

    systemd.services.stash = {
      description = "Stash media organizer";
      wantedBy = ["multi-user.target"];
      requires = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      after = [
        "network.target"
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      conflicts = ["docker-stash.service"];

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

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          cfg.dataDir
          cfg.mediaDir
        ];
      };
    };
  };
}
