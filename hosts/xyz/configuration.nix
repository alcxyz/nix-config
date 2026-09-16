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
    ./gaming.nix

    # Bring in consolidated layers
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/desktop.nix"
    "${configDir}/modules/nixos/hardware/display-device-guard.nix"
    inputs.nix-secrets.nixosModules.xyzDisplay
    inputs.nix-secrets.nixosModules.xyzInputHardwarePolicy
    inputs.nix-secrets.nixosModules.xyzNetworkIdentity
    inputs.nix-secrets.nixosModules.xyzNixSigningPolicy
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

  security.credentialConsent = {
    enable = true;
    ownerUsers = [username];
  };

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
    ioPressureGuard = {
      enable = true;
      highPercent = 20;
      highDurationSeconds = 20;
      lowPercent = 5;
      lowDurationSeconds = 60;
      # Trial admission drain: stop polling at moderate pressure, reserving the
      # aggregate freeze for sustained severe pressure.
      admissionControl = {
        enable = true;
        severePercent = 60;
        severeDurationSeconds = 30;
      };
    };
    isolatedDocker.enable = true;
    name = "xyz";
    capacity = 2;
    # Bound the runner daemon and all nested workers while allowing two jobs to
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

  systemd.coredump.enable = true;
  systemd.coredump.settings.Coredump = {
    Storage = "external";
    ProcessSizeMax = "2G";
  };

  # ==================== Virtualisation ====================
  virtualisation.podman = {
    enable = true;
    # Docker retains its CLI and socket; invoke Podman explicitly.
    dockerCompat = false;
    dockerSocket.enable = false;
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.kvm.managed.enable = false;
  virtualisation.kvm.gpu-passthrough = {
    enable = false;
    vmName = "win11";
    gpuContainerStacks = [
      "/home/alc/src/infra/gitops/docker/xyz/steam"
    ];
    gpuSystemdServices = ["stash.service"];
  };

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
