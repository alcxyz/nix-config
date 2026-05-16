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
  boot.extraModprobeConfig = ''
    options btusb reset=1 enable_autosuspend=0
    options mt7925e disable_aspm=1
  '';

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
  environment.systemPackages = [zfsKernelPkgs.zfs];
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.devNodes = "/dev/disk/by-id";

  systemd.services."zfs-mount".after = ["zfs-auto-unlock.service"];
  systemd.services."zfs-mount".requires = ["zfs-auto-unlock.service"];

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
    enable = false;
  };
  services.calibre-web.managed = {
    enable = true;
    configDir = "/var/lib/calibre-web/config";
    libraryDir = "/var/lib/calibre/config/libraries/Main";
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
      {path = "/tank/vault";}
    ];
  };

  services.netbird.managed.enable = true;

  services.forgejo-actions-runner = {
    enable = true;
    name = "xyz";
    capacity = 4;
    labels = [
      "ubuntu-latest:docker://node:20-bookworm"
      "xyz:docker://node:20-bookworm"
      "docker:docker://node:20-bookworm"
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

  services.flatpak.enable = true;

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
