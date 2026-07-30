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
  k8sBackupDataset = "tank/k8s-backups";
  k8sBackupRoot = "${appStateBackupPool}/xyz/k8s-backups";
  nvidiaContainerRuntime = lib.getExe' (
    lib.getOutput "tools" config.hardware.nvidia-container-toolkit.package
  ) "nvidia-container-runtime";
  nvidiaContainerRuntimeHook = lib.getExe' (
    lib.getOutput "tools" config.hardware.nvidia-container-toolkit.package
  ) "nvidia-container-runtime-hook";
  nvidiaCtk = lib.getExe' config.hardware.nvidia-container-toolkit.package "nvidia-ctk";
  homeBackupDataset = "xpool/home";
  homeBackupRoot = "${appStateBackupPool}/xyz/home";
  gamesDataset = "${appStateBackupPool}/games";
  gamesMountpoint = "/hitachi/games";
  localBackup = pkgs.writeShellScriptBin "xyz-local-backup" ''
    set -euo pipefail

    if [ "$(id -u)" -ne 0 ]; then
      echo "xyz-local-backup must run as root" >&2
      exit 1
    fi

    if [ "$#" -ne 1 ]; then
      echo "usage: xyz-local-backup {appstate|k8s|home}" >&2
      exit 64
    fi

    backup_name="$1"

    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
        pkgs.sanoid
        zfsKernelPkgs.zfs
      ]
    }

    target_pool=${lib.escapeShellArg appStateBackupPool}

    if ! zpool list -H "$target_pool" >/dev/null 2>&1; then
      echo "backup pool '$target_pool' is not imported; create/import it before running local backups" >&2
      exit 1
    fi

    target_pool_encryption="$(zfs get -H -o value encryption "$target_pool" 2>/dev/null || echo off)"
    if [ "$target_pool_encryption" = off ]; then
      echo "backup pool '$target_pool' is not encrypted; refusing to write unencrypted local backups" >&2
      exit 1
    fi

    target_pool_keystatus="$(zfs get -H -o value keystatus "$target_pool" 2>/dev/null || echo unavailable)"
    if [ "$target_pool_keystatus" != available ]; then
      echo "backup pool '$target_pool' key is not loaded; run: zfs load-key $target_pool" >&2
      exit 1
    fi

    lock_dir=/run/lock
    mkdir -p "$lock_dir"
    exec 9>"$lock_dir/xyz-local-backup-hitachi.lock"
    echo "waiting for hitachi backup lock for $backup_name"
    flock 9
    echo "acquired hitachi backup lock for $backup_name"

    ensure_backup_dataset() {
      local target_dataset="$1"

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
        echo "backup dataset '$target_dataset' is not encrypted; refusing to write unencrypted local backups" >&2
        exit 1
      fi

      target_dataset_keystatus="$(zfs get -H -o value keystatus "$target_dataset" 2>/dev/null || echo unavailable)"
      if [ "$target_dataset_keystatus" != available ]; then
        echo "backup dataset '$target_dataset' key is not loaded; run: zfs load-key $target_dataset" >&2
        exit 1
      fi
    }

    replicate_dataset() {
      local source_dataset="$1"
      local target_dataset="$2"
      local mode="$3"

      if ! zfs list -H "$source_dataset" >/dev/null 2>&1; then
        echo "source dataset '$source_dataset' does not exist" >&2
        exit 1
      fi

      ensure_backup_dataset "$target_dataset"

      syncoid_args=(
        --recursive
        --compress=none
        --recvoptions="u o canmount=off o readonly=on"
      )
      if [ "$mode" = skip-parent ]; then
        syncoid_args+=(--skip-parent)
      fi

      if [ "$mode" = include-parent ]; then
        target_snapshot_count="$(zfs list -H -t snapshot -o name -r "$target_dataset" 2>/dev/null | wc -l)"
        target_referenced_bytes="$(zfs get -Hp -o value referenced "$target_dataset" 2>/dev/null || echo 0)"

        if [ "$target_snapshot_count" -eq 0 ]; then
          if [ "$target_referenced_bytes" -gt 1048576 ]; then
            echo "target dataset '$target_dataset' has no snapshots but references data; refusing initial seed" >&2
            exit 1
          fi

          syncoid_args+=(--force-delete)
        fi
      fi

      syncoid \
        "''${syncoid_args[@]}" \
        "$source_dataset" \
        "$target_dataset"
    }

    case "$backup_name" in
      appstate)
        replicate_dataset xpool/appstate ${lib.escapeShellArg appStateBackupRoot} skip-parent
        ;;
      k8s)
        replicate_dataset ${lib.escapeShellArg k8sBackupDataset} ${lib.escapeShellArg k8sBackupRoot} include-parent
        ;;
      home)
        replicate_dataset ${lib.escapeShellArg homeBackupDataset} ${lib.escapeShellArg homeBackupRoot} include-parent
        ;;
      *)
        echo "unknown backup target '$backup_name'; expected appstate, k8s, or home" >&2
        exit 64
        ;;
    esac
  '';
  mkLocalBackupService = backupName: description: {
    inherit description;
    after = ["zfs-mount.service"];
    requires = ["zfs-mount.service"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${localBackup}/bin/xyz-local-backup ${backupName}";
      TimeoutStartSec = "12h";
    };
  };
  mkLocalBackupTimer = onCalendar: description: {
    inherit description;
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = onCalendar;
      Persistent = false;
      RandomizedDelaySec = "0";
    };
  };
  gamesDatasetPrepare = pkgs.writeShellScriptBin "xyz-games-dataset-prepare" ''
    set -euo pipefail

    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
        zfsKernelPkgs.zfs
      ]
    }

    dataset=${lib.escapeShellArg gamesDataset}
    mountpoint=${lib.escapeShellArg gamesMountpoint}
    pool=${lib.escapeShellArg appStateBackupPool}

    if ! zpool list -H "$pool" >/dev/null 2>&1; then
      echo "games pool '$pool' is not imported" >&2
      exit 1
    fi

    pool_encryption="$(zfs get -H -o value encryption "$pool" 2>/dev/null || echo off)"
    pool_keystatus="$(zfs get -H -o value keystatus "$pool" 2>/dev/null || echo unavailable)"
    if [ "$pool_encryption" != off ] && [ "$pool_keystatus" != available ]; then
      echo "games pool '$pool' key is not loaded; run: zfs load-key $pool" >&2
      exit 1
    fi

    install -d -m 0755 "$(dirname "$mountpoint")"

    if ! zfs list -H "$dataset" >/dev/null 2>&1; then
      zfs create -p \
        -o mountpoint="$mountpoint" \
        -o compression=zstd \
        -o atime=off \
        "$dataset"
    else
      zfs set mountpoint="$mountpoint" "$dataset"
      zfs set compression=zstd "$dataset"
      zfs set atime=off "$dataset"
    fi

    if ! findmnt -rn --target "$mountpoint" >/dev/null 2>&1; then
      zfs mount "$dataset"
    fi
    chown root:media "$mountpoint"
    chmod 0770 "$mountpoint"
  '';
in {
  imports = [
    ./hardware-configuration.nix

    # Bring in consolidated layers
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/desktop.nix"
    inputs.nix-secrets.nixosModules.zfsAutoUnlock
    inputs.nix-secrets.nixosModules.xyzStorageBootstrap
    inputs.nix-secrets.nixosModules.calibreWebProxyDefaults
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
    "${configDir}/modules/nixos/virtualisation/longhorn-prereqs/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  # Only the two intentional physical keyboards pass through Kanata on xyz.
  # Composite receivers, mice, media controls, and streaming virtual devices
  # remain owned by their native consumers.
  services.kanata.keyboards.main.extraDefCfg = ''
    process-unmapped-keys yes
    linux-dev-names-include (
      "Glove80 Keyboard"
      "Logitech K850"
    )
  '';

  # ==================== Host-specific Settings ====================

  programs.hyprlock.enable = true;
  programs.kdeconnect.enable = true;
  security.pam.services.hyprlock.u2f.enable = true;

  # Prevent ZFS warning - stable host ID
  networking.hostId = "4e7ded69";

  # See docs/adr/0035-host-kernel-policy.md: xyz has ZFS root and should not
  # track linuxPackages_latest unless the full system evaluates cleanly.
  boot.kernelPackages = zfsKernelPkgs.linuxPackages;
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
  users.groups.media = {
    gid = 983;
  };

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
    localBackup
    gamesDatasetPrepare
    zfsKernelPkgs.zfs
  ];
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.devNodes = "/dev/disk/by-id";
  boot.zfs.forceImportRoot = false;
  swapDevices = lib.mkForce [
    {
      device = "/dev/disk/by-partlabel/xyz-swap";
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

  systemd.services.xyz-appstate-backup = mkLocalBackupService "appstate" "Replicate xyz appstate datasets to the local backup pool";
  systemd.services.xyz-k8s-backup = mkLocalBackupService "k8s" "Replicate xyz k8s backup dataset to the local backup pool";
  systemd.services.xyz-home-backup = mkLocalBackupService "home" "Replicate xyz home dataset to the local backup pool";

  systemd.services.xyz-games-dataset = {
    description = "Prepare xyz games dataset on hitachi";
    after = ["zfs-mount.service"];
    requires = ["zfs-mount.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${gamesDatasetPrepare}/bin/xyz-games-dataset-prepare";
    };
  };

  systemd.timers.xyz-appstate-backup = mkLocalBackupTimer "*-*-* 05:20:00" "Daily xyz appstate backup";
  systemd.timers.xyz-k8s-backup = mkLocalBackupTimer "*-*-* 06:45:00" "Daily xyz k8s backup replication";
  systemd.timers.xyz-home-backup = mkLocalBackupTimer "*-*-* 05:50:00" "Daily xyz home backup";

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

  # xyz provides host-level services on 192.168.1.10. The replacement-system
  # boot exposed that this address previously depended on an implicit DHCP
  # lease: NetworkManager accepted 192.168.1.200 while RustFS remained bound to
  # the now-unassigned service address. Keep the host identity declarative and
  # tied to the physical Ethernet adapter.
  networking.networkmanager = {
    settings.main.no-auto-default = "9c:6b:00:7e:74:65";
    ensureProfiles.profiles.xyz-wired = {
      connection = {
        id = "xyz-wired";
        uuid = "8e724127-a8d6-3154-a8a3-66a91da6c626";
        type = "ethernet";
        interface-name = "enp8s0";
        autoconnect = true;
        autoconnect-priority = 100;
      };
      ethernet.mac-address = "9c:6b:00:7e:74:65";
      ipv4 = {
        method = "manual";
        addresses = "192.168.1.10/24";
        gateway = "192.168.1.1";
        dns = "192.168.1.15;192.168.1.3;";
        dns-search = "local;";
      };
      ipv6.method = "auto";
    };
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
    # Preserve the existing RustFS group ownership of the ZFS object tree.
    # Changing this during the role reversal would require an unnecessary
    # recursive metadata rewrite across the backup dataset.
    serviceGid = 986;
    accessKeyFile = config.sops.secrets.k8s_backup_s3_root_user.path;
    secretKeyFile = config.sops.secrets.k8s_backup_s3_root_password.path;
    mirrorSourceEndpoint = "http://192.168.1.13:9200";
    mirrorSchedule = "*-*-* 06:10:00";
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
      {
        path = "/tank/stash";
        anongid = config.users.groups.media.gid;
      }
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
    enable = true;
    nodeIp = "192.168.1.10";
    nodeInterface = "enp8s0";
    serverAddr = "https://k8s-api.local:6443";
    tokenFile = config.sops.secrets.k3s_server_token.path;
    extraFlags = [
      "--node-label=nixbox.alc.xyz/ephemeral-gpu=true"
      "--node-taint=nixbox.alc.xyz/ephemeral-gpu=true:NoSchedule"
    ];
  };

  # Longhorn still needs writable engine binaries and logs on an attachment
  # node. Keep those transient files in bounded memory while the durable volume
  # replicas remain on the stable storage nodes.
  fileSystems."/var/lib/longhorn" = {
    device = "none";
    fsType = "tmpfs";
    options = [
      "mode=0755"
      "size=1G"
      "nosuid"
      "nodev"
    ];
  };
  alc.longhornPrereqs.storageMountUnit = "var-lib-longhorn.mount";

  # Kubernetes allocates NVIDIA devices by UUID. Generate CDI names that match
  # the device plugin while retaining the aggregate `all` name used by Wolf.
  hardware.nvidia-container-toolkit.device-name-strategy = "uuid";

  # XYZ is an expendable interactive worker, never a control-plane or storage
  # dependency. Bound planned shutdowns so an attached browser volume is
  # released cleanly without making workstation restarts unreasonably slow.
  services.k3s.gracefulNodeShutdown = {
    enable = true;
    shutdownGracePeriod = "30s";
    shutdownGracePeriodCriticalPods = "10s";
  };

  # K3s cannot discover Nix store executables through its conventional runtime
  # search paths. Register the NVIDIA runtime and all of its helper paths
  # explicitly for GPU workloads.
  environment.etc."nvidia-container-runtime/config.toml".text = ''
    disable-require = true
    supported-driver-capabilities = "compat32,compute,display,graphics,ngx,utility,video"

    [nvidia-container-cli]
    environment = []
    ldconfig = "@${lib.getExe' pkgs.glibc "ldconfig"}"
    load-kmods = true
    no-cgroups = false
    path = "${lib.getExe' pkgs.libnvidia-container "nvidia-container-cli"}"

    [nvidia-container-runtime]
    mode = "cdi"
    runtimes = ["docker-runc", "runc", "crun"]

    [nvidia-container-runtime-hook]
    path = "${nvidiaContainerRuntimeHook}"
    skip-mode-detection = false

    [nvidia-ctk]
    path = "${nvidiaCtk}"
  '';

  services.k3s.containerdConfigTemplate = ''
    {{ template "base" . }}

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'nvidia']
      runtime_type = "io.containerd.runc.v2"
      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'nvidia'.options]
        BinaryName = "${nvidiaContainerRuntime}"
  '';

  systemd.services.k3s = {
    after = ["nvidia-container-toolkit-cdi-generator.service"];
    requires = ["nvidia-container-toolkit-cdi-generator.service"];
  };

  # Agents do not have the server admin kubeconfig. The kube-proxy identity has
  # the read-only node inventory needed by the LAN path audit.
  systemd.services.k3s-network-path-audit = {
    environment.KUBECONFIG = "/var/lib/rancher/k3s/agent/kubeproxy.kubeconfig";
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "10s";
    };
    unitConfig = {
      StartLimitIntervalSec = 120;
      StartLimitBurst = 12;
    };
  };

  networking.hosts."192.168.1.250" = ["k8s-api.local"];

  # t3code server — reachable via Netbird and the k8s oauth2-proxy route.
  networking.firewall.interfaces."wt0".allowedTCPPorts = [3773];
  networking.firewall.extraCommands = lib.mkAfter ''
    iptables -A nixos-fw -p tcp --dport 3773 -s 10.42.0.0/16 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp --dport 3773 -s 192.168.1.13 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp --dport 3773 -s 192.168.1.15 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp --dport 3773 -s 192.168.1.16 -j nixos-fw-accept
  '';

  services.flatpak.managed = {
    enable = true;
    packages = [
      "com.heroicgameslauncher.hgl"
    ];
    overrides."com.heroicgameslauncher.hgl" = [
      "--filesystem=/ext4"
      "--filesystem=/hitachi"
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
  # Keep Sunshine's fixed service ports out of the ephemeral client-port pool.
  boot.kernel.sysctl."net.ipv4.ip_local_reserved_ports" = "47984,47989-47990,47998-48000,48002,48010";

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
    "d /hitachi 0755 root root - -"
    "d /tank/games 0770 root media - -"
    "d /tank/vault 0770 root media - -"

    # Ensure the filtered input directory exists on boot (tmpfs)
    #"d /run/steam-headless-input 0755 root root - -"
  ];
}
