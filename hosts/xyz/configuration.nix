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
}: {
  imports = [
    ./hardware-configuration.nix
    ./storage.nix

    # Bring in consolidated layers
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/desktop.nix"
    "${configDir}/modules/nixos/hardware/display-device-guard.nix"
    inputs.nix-secrets.nixosModules.xyzDisplay
    inputs.nix-secrets.nixosModules.xyzInputHardwarePolicy
    inputs.nix-secrets.nixosModules.xyzNetworkIdentity
    inputs.nix-secrets.nixosModules.xyzStoragePolicy
    inputs.nix-secrets.nixosModules.xyzPrinter
    inputs.nix-secrets.nixosModules.steamHeadlessWakeServer
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
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  # ==================== Host-specific Settings ====================

  programs.hyprlock.enable = true;
  programs.kdeconnect.enable = true;
  security.pam.services.hyprlock.u2f.enable = true;

  # DMS owns unlocked idle handling, while the Home Manager lock wrapper starts
  # a private hypridle only for an active Hyprlock. Prevent the package-provided
  # configless unit from crash-looping when the graphical session starts.
  systemd.user.services.hypridle = {
    overrideStrategy = "asDropin";
    unitConfig.ConditionPathExists = "/run/xyz-enable-hypridle";
  };

  boot.binfmt.emulatedSystems = ["aarch64-linux"];
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=17179869184
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

  # ==================== Users ====================
  users.users.${username} = {
    # Keep the user manager—and therefore the headless T3 service—running
    # across graphical logouts and start it during boot.
    linger = true;
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

  # ==================== Services ====================
  services.printing = {
    enable = true;
    drivers = [pkgs.hplipWithPlugin];
    # The xev-backed queue below is managed explicitly; do not create a second
    # implicit queue for the same Bonjour advertisement.
    browsed.enable = false;
  };

  services.netbird.managed = {
    enable = true;
    disableDns = true;
  };

  services.forgejo-actions-runner = {
    enable = true;
    name = "xyz";
    capacity = 2;
    # Bound all Forgejo-created containers together while allowing two jobs to
    # share the budget. Low weights make builds yield to desktop and game work.
    resourcePolicy.enable = true;
    labels = [
      "forgejo-docker-primary:docker://node:20-bookworm"
      "ubuntu-latest:docker://node:20-bookworm"
      "docker:docker://node:20-bookworm"
      "xyz:docker://node:20-bookworm"
    ];
  };

  networking.hosts."192.168.1.250" = ["k8s-api.local"];

  # t3code server — reachable via Netbird and the k8s oauth2-proxy route.
  networking.firewall.interfaces."wt0".allowedTCPPorts = [3773];
  networking.firewall.extraCommands = lib.mkAfter ''
    iptables -A nixos-fw -p tcp --dport 3773 -s 10.42.0.0/16 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp --dport 3773 -s 192.168.1.13 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp --dport 3773 -s 192.168.1.15 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp --dport 3773 -s 192.168.1.16 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp --dport 3773 -s 192.168.1.250 -j nixos-fw-accept
  '';

  services.flatpak.managed = {
    enable = true;
    packages = [
      "com.heroicgameslauncher.hgl"
      "net.retrodeck.retrodeck"
    ];
    overrides."com.heroicgameslauncher.hgl" = [
      "--env=TZ=Europe/Oslo"
      "--filesystem=/ext4"
      "--filesystem=/games"
      "--filesystem=/nix/store:ro"
      "--filesystem=home"
    ];
  };

  services.heroicSideload = {
    enable = true;
    user = username;
    apps.battle-net = {
      title = "Battle.net";
      appName = "tiJeeLoWxRnVACPf7WYvkr";
      installDir = "/ext4/games/Heroic/Prefixes/default/Battle.net/pfx/drive_c/Program Files (x86)/Battle.net";
      executable = "Battle.net.exe";
      art = "https://cdn2.steamgriddb.com/grid/18c968e3898f39820946387c9e8aa5c8.png";
      manageGameConfig = false;
    };
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

  # Streaming ingress is scoped to trusted interfaces by the private host policy.
  networking.firewall.allowedTCPPorts = [
    3774
    5201
  ];

  networking.firewall.allowedUDPPorts = [
    3774
    5353
  ];
}
