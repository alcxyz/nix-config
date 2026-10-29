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
  # Keep in sync with services.t3code ports in users/alc/linux/xyz/t3code.nix.
  t3codePorts = [3773 3774];
  # Where the k8s oauth2-proxy routes arrive from: the pod subnet, and the
  # k3s nodes (xev, nux, nex) and API address, since pod traffic leaving the
  # cluster is masqueraded to the node.
  k3sSources = [
    "10.42.0.0/16"
    "192.168.1.13"
    "192.168.1.15"
    "192.168.1.16"
    "192.168.1.250"
  ];
  # The k8s routes and trusted LAN clients.
  t3codeSources = k3sSources ++ ["192.168.1.23"];
in {
  imports = [
    ./hardware-configuration.nix
    ./storage.nix
    ./gaming.nix

    # Bring in consolidated layers
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/desktop.nix"
    "${configDir}/modules/nixos/hardware/display-device-guard.nix"
    # The agent PR review guard as a managed Codex hook.
    inputs.pandora.nixosModules.default
    inputs.nix-secrets.nixosModules.xyzDisplay
    inputs.nix-secrets.nixosModules.xyzInputHardwarePolicy
    inputs.nix-secrets.nixosModules.xyzNetworkIdentity
    inputs.nix-secrets.nixosModules.xyzNixSigningPolicy
    inputs.nix-secrets.nixosModules.xyzStoragePolicy
    inputs.nix-secrets.nixosModules.openbaoBackupPolicy
    inputs.nix-secrets.nixosModules.restoreCataloguePolicy
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
  security.agentPrReviewGuard = {
    enable = true;
    users = [username];
  };

  programs.hyprlock.enable = true;
  programs.kdeconnect.enable = true;
  security.pam.services.hyprlock.u2f.enable = true;
  # Remote view sessions authenticate with the user's password (ADR-0102).
  security.pam.services.wayvnc = {};

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
    script = builtins.readFile ./xyz-bluetooth-keyboard-reconnect.sh;
  };

  # Builds through the host daemon (deploys, local builds and remote build
  # clients) run in nix-daemon.service, which had no memory limit. Overlapping
  # compiles after a flake update froze the host. Cap the daemon so the kernel
  # kills the largest build instead. The ZFS ARC (up to 16G, reclaimable) and
  # the desktop share the rest. CI jobs run their own Nix in containers under
  # forgejobuilds.slice and its separate cap, so a deploy that overlaps busy CI
  # can still overcommit RAM.
  systemd.services.nix-daemon.serviceConfig = {
    MemoryMax = "40G";
    # Swapping builds to disk is what stalls the whole host.
    MemorySwapMax = "2G";
    # Kill only the offending build process, not the daemon and every build.
    OOMPolicy = "continue";
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
    # Alert when CI admission stays held beyond its bound (ADR-0072, #894).
    holdMonitor.enable = true;
    package = pkgs.callPackage "${inputs.nix-packages}/pkgs/forgejo-runner-cancellation" {};
    ioPressureGuard = {
      enable = true;
      diskSpace.enable = true;
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
        gameProcess = {
          enable = true;
          user = "alc";
          argv0Basenames = ["HeroesOfTheStorm_x64.exe"];
        };
      };
    };
    idlePodmanCleanup.enable = true;
    idlePodmanCleanup.pressureOnly = false;
    # Pool jobs substitute upstream paths through a local read-only proxy
    # (ADR-0103).
    nixCacheProxy.enable = true;
    isolatedDocker.enable = true;
    isolatedDocker.retention.enable = true;
    podmanCanary = {
      enable = true;
      package = pkgs.callPackage "${inputs.nix-packages}/pkgs/forgejo-runner-cancellation" {};
      # Preserve the manual canary workflow while jobs adopt the shared label.
      # ci-fast serves opted-in jobs on the fastest host (ADR-0097); this
      # pool runner keeps it as overflow beside the dedicated xyz-fast runner.
      labels = [
        "forgejo-podman:docker://docker.io/library/docker:27-cli"
        "forgejo-podman-canary:docker://docker.io/library/docker:27-cli"
        "ci-fast:docker://docker.io/library/docker:27-cli"
      ];
      sharedLabels = ["ci-fast"];
      # Most jobs use the Podman pool, so it takes the slot the Docker runner
      # gave up; the build slice's total stays at five.
      capacity = 3;
      # A ci-fast slot pool jobs cannot take; fast jobs may still start in a
      # free pool slot, since whichever runner polls first takes the job.
      # Up to five jobs now share the build slice's budget.
      extraRunners.fast = {
        labels = ["ci-fast:docker://docker.io/library/docker:27-cli"];
        capacity = 1;
        # xev's standby xev-fast runs while this runner is down.
        status = {
          enable = true;
          port = 9478;
          interface = "wt0";
        };
      };
    };
    name = "xyz";
    # One Docker slot serves the few jobs that still select a Docker label.
    capacity = 1;
    # Bound the runner daemon and all nested workers within one budget. Low
    # weights make builds yield to desktop and game work.
    resourcePolicy.enable = true;
    labels = [
      "forgejo-docker-primary:docker://node:20-bookworm"
      "ubuntu-latest:docker://node:20-bookworm"
      "docker:docker://node:20-bookworm"
      "xyz:docker://node:20-bookworm"
    ];
  };

  # xyz is the fleet's controller, so its own reboot also interrupts what the
  # operator and the other hosts run here.
  services.nixfleet-reboot-guard = let
    gameProcess = config.services.forgejo-actions-runner.ioPressureGuard.admissionControl.gameProcess;
    t3code = configDir.homeConfigurations."${username}-${hostName}".config.services.t3code.idleCheck;
  in {
    # The agreed rule: a running game on the controller blocks its self reboot.
    game = {
      blocksReboot = true;
      inherit (gameProcess) user;
      # The runner's games and the sideloaded Heroic games, by the
      # executable each runs under Wine; the Battle.net launcher is no game.
      wineArgv0Basenames = lib.unique (gameProcess.argv0Basenames
        ++ lib.mapAttrsToList (_: app: app.executable)
        (lib.filterAttrs (name: _: name != "battle-net") config.services.heroicSideload.apps));
      # Steam runs each game under reaper, alive only while the game runs.
      # Not wineserver: non-game Wine apps keep one here too.
      processNames = ["reaper"];
    };
    backupUnits = [
      "xyz-appstate-backup.service"
      "xyz-k8s-backup.service"
      "xyz-home-backup.service"
      "k8s-backup-s3-mirror.service"
      "k8s-backup-rustfs.service"
      "snapshot-restic-home-maintenance.service"
      "snapshot-restic-home-full-check.service"
    ];
    operator = {
      user = username;
      agentJobs = true;
      tmux = true;
      t3code = {
        idleCheck = t3code.package;
        inherit (t3code) instances;
      };
    };
    remoteNixClients = true;
    notes = [
      "other hosts use xyz as binary cache and remote builder"
      "xps streams games from SteamHeadless on xyz"
    ];
  };

  networking.hosts."192.168.1.250" = ["k8s-api.local"];

  # t3code servers (primary and work, see users/alc/linux/xyz/t3code.nix) —
  # reachable via Netbird and the k8s oauth2-proxy routes.
  networking.firewall.interfaces."wt0".allowedTCPPorts = t3codePorts;
  networking.firewall.extraCommands = lib.mkAfter ((lib.concatMapStrings (port:
      lib.concatMapStrings (source: ''
        iptables -A nixos-fw -p tcp --dport ${toString port} -s ${source} -j nixos-fw-accept
      '')
      t3codeSources)
    t3codePorts)
    # The agent dashboard (users/alc/linux/xyz.nix) is reached only through
    # the k8s oauth2-proxy route.
    + lib.concatMapStrings (source: ''
      iptables -A nixos-fw -p tcp --dport 3775 -s ${source} -j nixos-fw-accept
    '')
    k3sSources);

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
