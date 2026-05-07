{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unifi-native;

  unifiPorts = {
    tcp = [
      8443
      8080
      8880
      8843
      6789
    ];
    udp = [
      3478
      10001
    ];
  };

  backupScript = pkgs.writeShellScriptBin "unifi-native-backup" ''
    set -euo pipefail

    backup_dir="''${1:-/var/backups/unifi}"
    install -d -m 0700 -o root -g root "$backup_dir"

    stamp="$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%SZ)"
    out="$backup_dir/unifi-native-$stamp.tar.zst"

    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet unifi.service; then
      echo "unifi.service is not active; refusing backup" >&2
      exit 1
    fi

    ${pkgs.gnutar}/bin/tar \
      --use-compress-program=${pkgs.zstd}/bin/zstd \
      --one-file-system \
      -cpf "$out" \
      -C / \
      var/lib/unifi \
      var/log/unifi

    chmod 0600 "$out"
    echo "$out"
  '';

  legacyStopScript = pkgs.writeShellScriptBin "unifi-stop-legacy-docker" ''
    set -euo pipefail

    for name in unifi unifi-db; do
      if ${pkgs.docker}/bin/docker ps -a --format '{{.Names}}' | ${pkgs.gnugrep}/bin/grep -qx "$name"; then
        ${pkgs.docker}/bin/docker stop "$name" >/dev/null || true
      fi
    done
  '';
in {
  options.services.unifi-native = {
    enable = lib.mkEnableOption "native UniFi Network Application runtime";

    role = lib.mkOption {
      type = lib.types.enum [
        "active"
        "standby"
      ];
      default = "active";
      description = "Whether this host should run UniFi now or only be prepared as a fallback host.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open UniFi controller, inform, STUN, discovery, portal, and speed test ports.";
    };

    initialJavaHeapSize = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Initial UniFi JVM heap size in MiB.";
    };

    maximumJavaHeapSize = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Maximum UniFi JVM heap size in MiB.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.unifi
      pkgs.mongodb-7_0
      backupScript
      legacyStopScript
    ];

    services.unifi = {
      enable = true;
      unifiPackage = pkgs.unifi;
      mongodbPackage = pkgs.mongodb-7_0;
      openFirewall = false;
      initialJavaHeapSize = cfg.initialJavaHeapSize;
      maximumJavaHeapSize = cfg.maximumJavaHeapSize;
    };

    systemd.services.unifi = lib.mkIf (cfg.role == "standby") {
      wantedBy = lib.mkForce [];
    };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = unifiPorts.tcp;
      allowedUDPPorts = unifiPorts.udp;
    };
  };
}
