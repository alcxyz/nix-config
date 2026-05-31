# nix-config/hosts/xyz/configuration.nix
{
  config,
  options,
  pkgs,
  inputs,
  username,
  hostName,
  configDir,
  lib,
  ...
}: let
  zfsKernelPkgs = import inputs.nixpkgs-zfs-master {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  appStateDatasets = {
    calibre = "xpool/appstate/calibre";
    calibre-web = "xpool/appstate/calibre-web";
    plex = "xpool/appstate/plex";
    qbittorrent = "xpool/appstate/qbittorrent";
    stash = "xpool/appstate/stash";
    steam-headless = "xpool/appstate/steam-headless";
  };
  appStateBackupPool = "hitachi";
  appStateBackupRoot = "${appStateBackupPool}/xyz/appstate";
  appStateBackup = pkgs.writeShellScriptBin "xyz-appstate-backup" ''
    set -euo pipefail

    if [ "$(id -u)" -ne 0 ]; then
      echo "xyz-appstate-backup must run as root" >&2
      exit 1
    fi

    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.sanoid
        zfsKernelPkgs.zfs
      ]
    }

    source_dataset=xpool/appstate
    target_pool=${lib.escapeShellArg appStateBackupPool}
    target_dataset=${lib.escapeShellArg appStateBackupRoot}

    if ! zpool list -H "$target_pool" >/dev/null 2>&1; then
      echo "backup pool '$target_pool' is not imported; create/import it before running appstate backups" >&2
      exit 1
    fi

    if ! zfs list -H "$source_dataset" >/dev/null 2>&1; then
      echo "source dataset '$source_dataset' does not exist" >&2
      exit 1
    fi

    target_pool_encryption="$(zfs get -H -o value encryption "$target_pool" 2>/dev/null || echo off)"
    if [ "$target_pool_encryption" = off ]; then
      echo "backup pool '$target_pool' is not encrypted; refusing to write unencrypted appstate backups" >&2
      exit 1
    fi

    target_pool_keystatus="$(zfs get -H -o value keystatus "$target_pool" 2>/dev/null || echo unavailable)"
    if [ "$target_pool_keystatus" != available ]; then
      echo "backup pool '$target_pool' key is not loaded; run: zfs load-key $target_pool" >&2
      exit 1
    fi

    if ! zfs list -H "$target_dataset" >/dev/null 2>&1; then
      zfs create -p \
        -o mountpoint=none \
        -o canmount=off \
        -o compression=zstd \
        -o atime=off \
        "$target_dataset"
    fi

    target_dataset_encryption="$(zfs get -H -o value encryption "$target_dataset" 2>/dev/null || echo off)"
    if [ "$target_dataset_encryption" = off ]; then
      echo "backup dataset '$target_dataset' is not encrypted; refusing to write unencrypted appstate backups" >&2
      exit 1
    fi

    target_dataset_keystatus="$(zfs get -H -o value keystatus "$target_dataset" 2>/dev/null || echo unavailable)"
    if [ "$target_dataset_keystatus" != available ]; then
      echo "backup dataset '$target_dataset' key is not loaded; run: zfs load-key $target_dataset" >&2
      exit 1
    fi

    syncoid \
      --recursive \
      --skip-parent \
      --compress=none \
      --recvoptions="u o canmount=off o readonly=on" \
      "$source_dataset" \
      "$target_dataset"
  '';
in {
  imports = [
    ./hardware-configuration.nix

    # Bring in consolidated layers
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/desktop.nix"
    inputs.nix-secrets.nixosModules.zfsAutoUnlock
    inputs.nix-secrets.nixosModules.xyzStorageBootstrap
    "${configDir}/modules/nixos/hardware/nvidia.nix"
    "${configDir}/modules/nixos/hardware/amd.nix"
    "${configDir}/modules/nixos/services/torrent/default.nix"
    "${configDir}/modules/nixos/services/stash/default.nix"
    "${configDir}/modules/nixos/services/plex/default.nix"
    "${configDir}/modules/nixos/services/calibre-web/default.nix"
    "${configDir}/modules/nixos/services/flatpak/default.nix"
    "${configDir}/modules/nixos/services/heroic-sideload/default.nix"
    "${configDir}/modules/nixos/services/k8s-backup-s3/default.nix"
    "${configDir}/modules/nixos/services/nfs/default.nix"
    "${configDir}/modules/nixos/services/forgejo-actions-runner/default.nix"
    "${configDir}/modules/nixos/virtualisation/kvm/default.nix"
    "${configDir}/modules/nixos/virtualisation/kvm/gpu-passthrough.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  # ==================== Host-specific Settings ====================

  programs.hyprlock.enable = true;
  security.pam.services.hyprlock.u2f.enable = true;

  # Prevent ZFS warning - stable host ID
  networking.hostId = "4e7ded69";

  boot.kernelPackages = zfsKernelPkgs.linuxPackages_latest;
  boot.zfs.package = zfsKernelPkgs.zfs;
  boot.binfmt.emulatedSystems = ["aarch64-linux"];
  boot.kernelParams = ["usbcore.autosuspend=-1"];
  boot.extraModprobeConfig = ''
    options btusb reset=1 enable_autosuspend=0
    options mt7925e disable_aspm=1
  '';

  systemd.services.bluetooth-keyboard-reconnect = {
    description = "Reconnect trusted Bluetooth keyboards";
    after = ["bluetooth.service"];
    wants = ["bluetooth.service"];
    wantedBy = ["multi-user.target"];
    path = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.systemd
    ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "5s";
    };
    script = ''
      set -u

      prop() {
        busctl get-property org.bluez "$1" org.bluez.Device1 "$2" 2>/dev/null || true
      }

      while true; do
        busctl tree --list org.bluez \
          | grep -E '^/org/bluez/hci[0-9]+/dev_[^/]+$' \
          | while read -r device; do
            [ "$(prop "$device" Icon)" = 's "input-keyboard"' ] || continue
            [ "$(prop "$device" Paired)" = "b true" ] || continue
            [ "$(prop "$device" Trusted)" = "b true" ] || continue
            [ "$(prop "$device" Connected)" = "b false" ] || continue

            busctl call org.bluez "$device" org.bluez.Device1 Connect >/dev/null 2>&1 || true
          done

        sleep 10
      done
    '';
  };

  # ---- Nix Settings ----
  nix.settings.secret-key-files = ["/etc/nix/signing-key"];
  # Allow this host to build for remote machines via SSH
  nix.settings.allowed-uris = [
    "ssh-ng://*"
    "ssh://*"
    "file://*"
    "https://*"
  ];

  # ---- Secrets ----
  sops = {
    secrets = {
      k3s_server_token = {
        sopsFile = "${inputs.nix-secrets}/cluster-bootstrap/secrets.yaml";
        key = "k3s_server_token";
      };
      k8s_backup_s3_root_user = {
        sopsFile = "${inputs.nix-secrets}/hosts/xyz/secrets.yaml";
        owner = "root";
        group = "root";
      };
      k8s_backup_s3_root_password = {
        sopsFile = "${inputs.nix-secrets}/hosts/xyz/secrets.yaml";
        owner = "root";
        group = "root";
      };
    };
  };

  # ==================== Users ====================
  users.users.${username} = {
    extraGroups = [
      "media"
      "render"
    ];
  };

  # Populate AccountsService so DMS persists the profile picture across restarts.
  # DMS reads the icon path from AccountsService on startup; without this it
  # falls back to an empty string and discards whatever was set manually.
  system.activationScripts.accountsServiceIcon = {
    text = ''
      install -d -m755 /var/lib/AccountsService/icons
      install -d -m755 /var/lib/AccountsService/users
      install -m644 ${configDir}/users/${username}/profile.jpg \
        /var/lib/AccountsService/icons/${username}
      if [ ! -f /var/lib/AccountsService/users/${username} ]; then
        printf '[User]\nIcon=/var/lib/AccountsService/icons/${username}\nSystemAccount=false\n' \
          > /var/lib/AccountsService/users/${username}
      fi
    '';
    deps = [];
  };

  users.users.media = {
    isSystemUser = true;
    group = "media";
  };
  users.groups.media = {};

  users.groups.steamheadless = {
    gid = 2001;
  };
  users.users.steamheadless = {
    isSystemUser = true;
    uid = 2001;
    group = "steamheadless";
    extraGroups = [
      "users"
      "media"
      "video"
      "render"
    ];
  };

  # ==================== ZFS ====================
  environment.systemPackages = [
    appStateBackup
    zfsKernelPkgs.zfs
  ];
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.devNodes = "/dev/disk/by-id";
  swapDevices = lib.mkForce [
    {
      device = "/dev/disk/by-partuuid/34b759ea-2e88-4ea1-9cd5-f79cee42e952";
      randomEncryption.enable = true;
      options = ["nofail"];
    }
  ];

  fileSystems."/var/lib/calibre" = {
    device = appStateDatasets.calibre;
    fsType = "zfs";
    options = ["nofail"];
  };
  fileSystems."/var/lib/calibre-web" = {
    device = appStateDatasets.calibre-web;
    fsType = "zfs";
    options = ["nofail"];
  };
  fileSystems."/var/lib/plex" = {
    device = appStateDatasets.plex;
    fsType = "zfs";
    options = ["nofail"];
  };
  fileSystems."/var/lib/qbittorrent" = {
    device = appStateDatasets.qbittorrent;
    fsType = "zfs";
    options = ["nofail"];
  };
  fileSystems."/var/lib/stash" = {
    device = appStateDatasets.stash;
    fsType = "zfs";
    options = ["nofail"];
  };
  fileSystems."/var/lib/steam-headless" = {
    device = appStateDatasets.steam-headless;
    fsType = "zfs";
    options = ["nofail"];
  };

  # Disable discard/trim timers on this storage stack. A hard hang on 2026-05-18
  # coincided with fstrim starting, and the post-reset boot left tank import
  # blocked until manual recovery.
  services.fstrim.enable = lib.mkForce false;
  systemd.timers.fstrim.wantedBy = lib.mkForce [];
  systemd.timers.zpool-trim.wantedBy = lib.mkForce [];
  systemd.timers.fstrim.timerConfig = {
    OnCalendar = lib.mkForce "Sat *-*-* 05:00:00";
    Persistent = lib.mkForce false;
    RandomizedDelaySec = lib.mkForce "0";
  };
  systemd.timers.zpool-trim.timerConfig = {
    OnCalendar = lib.mkForce "Sat *-*-* 06:00:00";
    Persistent = lib.mkForce false;
    RandomizedDelaySec = lib.mkForce "0";
  };

  # Keep disruptive maintenance in the 04:00-07:00 local quiet window.
  nix.gc = {
    dates = lib.mkForce "Mon *-*-* 04:30:00";
    persistent = lib.mkForce false;
  };
  systemd.timers.logrotate.timerConfig = {
    OnCalendar = lib.mkForce "*-*-* 04:10:00";
    Persistent = lib.mkForce false;
    RandomizedDelaySec = lib.mkForce "0";
  };
  systemd.timers.systemd-tmpfiles-clean.timerConfig = {
    OnCalendar = lib.mkForce "*-*-* 04:20:00";
    Persistent = lib.mkForce false;
    RandomizedDelaySec = lib.mkForce "0";
  };

  systemd.services."zfs-mount".after = ["zfs-auto-unlock.service"];
  systemd.services."zfs-mount".requires = ["zfs-auto-unlock.service"];

  systemd.services.xyz-appstate-backup = {
    description = "Replicate xyz appstate datasets to the local backup pool";
    after = ["zfs-mount.service"];
    requires = ["zfs-mount.service"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${appStateBackup}/bin/xyz-appstate-backup";
    };
  };

  systemd.timers.xyz-appstate-backup = {
    description = "Daily xyz appstate dataset backup";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 05:20:00";
      Persistent = false;
      RandomizedDelaySec = "0";
    };
  };

  # Docker - ZFS relationship

  systemd.services.docker = {
    after = [
      "zfs-mount.service"
      "zfs-import.target"
      "zfs-auto-unlock.service"
    ];

    requires = [
      "zfs-mount.service"
      "zfs-auto-unlock.service"
    ];
  };

  # ==================== Services ====================
  services.printing = {
    enable = true;
    drivers = [pkgs.hplipWithPlugin];
  };

  services.torrent.enable = true;
  services.plex.managed = {
    enable = true;
    mediaDir = "/tank/media/plex";
    transcodeDir = "/tmp/plex-transcode";
  };
  services.stash.managed = {
    enable = true;
  };
  services.calibre-web.managed = {
    enable = true;
    configDir = "/var/lib/calibre-web/config";
    libraryDir = "/var/lib/calibre/config/libraries/Main";
  };

  systemd.services.calibre-web = {
    requires = [
      "var-lib-calibre.mount"
      "var-lib-calibre\\x2dweb.mount"
    ];
    after = [
      "var-lib-calibre.mount"
      "var-lib-calibre\\x2dweb.mount"
    ];
  };
  systemd.services.plex = {
    requires = ["var-lib-plex.mount"];
    after = ["var-lib-plex.mount"];
  };
  systemd.services.qbittorrent = {
    requires = ["var-lib-qbittorrent.mount"];
    after = ["var-lib-qbittorrent.mount"];
  };
  systemd.services.stash = {
    requires = ["var-lib-stash.mount"];
    after = ["var-lib-stash.mount"];
  };

  services.k8s-backup-s3 = {
    enable = true;
    dataset = "tank/k8s-backups";
    dataDir = "/tank/k8s-backups/rustfs";
    quota = "1T";
    apiAddress = "192.168.1.10:9100";
    consoleAddress = "127.0.0.1:9101";
    accessKeyFile = config.sops.secrets.k8s_backup_s3_root_user.path;
    secretKeyFile = config.sops.secrets.k8s_backup_s3_root_password.path;
  };

  # NFS mount from nux — shared directory for paperless-ingest and future services
  fileSystems."/mnt/nux-shared" = {
    device = "192.168.1.15:/mnt/shared";
    fsType = "nfs";
    options = [
      "nfsvers=4"
      "soft"
      "timeo=15"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
    ];
  };

  services.nfs.managed = {
    enable = true;
    allowedClients = [
      "192.168.1.24" # mac
      "192.168.1.15" # nux
    ];
    shares = [
      # Home directories
      {path = "/home/alc/Documents";}
      {path = "/home/alc/Downloads";}
      {path = "/home/alc/Pictures";}
      {path = "/home/alc/Music";}
      {path = "/home/alc/Cloud";}
      {path = "/home/alc/Public";}
      # Paperless consumption
      {path = "/home/alc/paperless-ingest";}
      # Shared state for gitops tools (tokens, cross-host config)
      {path = "/home/alc/.local/share/gitops-state";}
      # ZFS datasets
      {path = "/tank/media";}
      {path = "/tank/downloads";}
      {path = "/tank/games";}
      {
        path = "/tank/vault";
        anonuid = 65534;
        anongid = 65534;
        allowedClients = ["192.168.1.0/24"];
      }
    ];
  };

  services.netbird.managed = {
    enable = true;
    disableDns = true;
  };

  services.forgejo-actions-runner = {
    enable = true;
    name = "xyz";
    capacity = 4;
    labels = [
      "forgejo-docker-primary:docker://node:20-bookworm"
      "ubuntu-latest:docker://node:20-bookworm"
      "docker:docker://node:20-bookworm"
      "xyz:docker://node:20-bookworm"
    ];
  };

  k3s = {
    enable = false;
    serverAddr = "https://k8s-api.local:6443";
    tokenFile = config.sops.secrets.k3s_server_token.path;
  };

  networking.hosts."192.168.1.250" = ["k8s-api.local"];

  # t3code server — only reachable via Netbird (wt0), not LAN
  networking.firewall.interfaces."wt0".allowedTCPPorts = [3773];

  services.flatpak.managed = {
    enable = true;
    packages = [
      "com.heroicgameslauncher.hgl"
    ];
    overrides."com.heroicgameslauncher.hgl" = [
      "--filesystem=/ext4"
      "--filesystem=/nix/store:ro"
      "--filesystem=home"
    ];
  };

  services.heroicSideload = {
    enable = true;
    user = username;
    apps.totem-quest = {
      title = "Totem Quest";
      appName = "rcFYseiJyPmfqM9tn2Di7a";
      source = "/var/lib/xyz-games/sources/Totem-Quest_Win_EN_Full.zip";
      installDir = "/ext4/games/Totem_Quest";
      executable = "TotemQuest.exe";
      art = "https://www.myabandonware.com/media/screenshots/t/totem-quest-1c8k/webp/totem-quest_1.webp";
      protonPackage = pkgs.proton-ge-bin.steamcompattool;
    };
  };

  systemd.coredump.enable = true;
  systemd.coredump.settings.Coredump = {
    Storage = "external";
    ProcessSizeMax = "2G";
  };

  # ==================== Virtualisation ====================
  virtualisation.kvm.managed.enable = false;
  virtualisation.kvm.gpu-passthrough = {
    enable = false;
    vmName = "win11";
    gpuContainerStacks = [
      "/home/alc/src/infra/gitops/docker/xyz/steam"
    ];
    gpuSystemdServices = ["stash.service"];
  };

  # ==================== Gaming ====================
  programs.steam = {
    enable = true;
  };

  # Steam Stream
  networking.firewall = {
    allowedUDPPortRanges = [
      {
        from = 27031;
        to = 27036;
      }
    ];
  };

  networking.firewall.allowedTCPPorts = [
    3774
    5201
    18083
    27036
    47984
    47989
    47990
    48010
  ];

  networking.firewall.allowedUDPPorts = [
    3774
    47998
    47999
    48000
    48002
    48010
    5353
  ];

  # ==================== Tmpfiles ====================
  systemd.tmpfiles.rules = [
    "d /tank 0755 root root - -"
    "z /tank 0755 root root - -"
    "L+ /downloads - - - - /tank/downloads"
    "L+ /vault - - - - /tank/vault"
    "d /tank/games 0770 root media - -"
    "d /tank/vault 0770 root media - -"

    # Ensure the filtered input directory exists on boot (tmpfs)
    #"d /run/steam-headless-input 0755 root root - -"
  ];
}
