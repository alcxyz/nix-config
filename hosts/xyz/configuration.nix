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
    inputs.nix-secrets.nixosModules.xyzDynamicDns
    inputs.nix-secrets.nixosModules.xyzCredentialConsentRemote
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
    # The main T3 instance's threads get a name and a link; another instance's get
    # a name. deck's threadLink builds the same link.
    requesterCommand = lib.getExe (pkgs.writeShellApplication {
      name = "t3-thread-describe";
      runtimeInputs = [pkgs.jq];
      text = ''
        bin="$HOME/.nix-profile/bin"
        status="$("$bin/t3-thread-status" --self "$1")"
        # One line, without what the helper's check refuses.
        jq -r '(.threads[0].title // "") | gsub("[\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}]"; " ")' <<< "$status"
        if [[ "$(jq -r .database <<< "$status")" == "$HOME/.t3/userdata/statev2.sqlite" ]]; then
          environment="$("$bin/t3-thread-inventory" --thread "$1" --days 0 | jq -r '.environmentId // empty')"
          if [[ -n "$environment" ]]; then
            printf 'https://t3code.alc.xyz/%s/%s\n' "$environment" "$1"
          fi
        fi
      '';
    });
  };
  security.agentPrReviewGuard = {
    enable = true;
    users = [username];
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
    script = builtins.readFile ./xyz-bluetooth-keyboard-reconnect.sh;
  };

  # Builds through the host daemon (deploys, local builds and remote build
  # clients) run in nix-daemon.service, which had no memory limit. Overlapping
  # compiles after a flake update froze the host. Cap the daemon so the kernel
  # kills the largest build instead. CI jobs run their own Nix in containers
  # under forgejobuilds.slice. The daemon runs in that slice's child
  # forgejobuilds-nixdaemon.slice, so the slice's shared limit (77%, below)
  # keeps the daemon and CI together from overcommitting the host.
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

  # xyz's sshd is reachable from outside the LAN and NetBird (nix-secrets
  # ADR-0028), so beyond the common key-only settings it also refuses
  # keyboard-interactive logins and accepts only the accounts that log in.
  # A new SSH account on xyz, such as a managed forward target, must be
  # added here.
  services.openssh.settings = {
    KbdInteractiveAuthentication = false;
    AllowUsers = [username "root"];
    LoginGraceTime = 30;
  };

  services.forgejo-actions-runner = {
    enable = true;
    package = pkgs.callPackage "${inputs.nix-packages}/pkgs/forgejo-runner-cancellation" {};
    # Hold the runners while a game runs or the disk is low, and report a
    # runner left off (ADR-0106). A game gives running jobs two minutes,
    # then cancels them.
    runnerHold = {
      game.enable = true;
      # Runner caches stay on root, and the Podman store shares /ext4 with the
      # games with no quota of its own, so the floor watches both.
      diskSpace = {
        enable = true;
        extraPaths = ["/ext4"];
      };
      alert.enable = true;
    };
    shutdownTimeoutSeconds = 120;
    # Reset the Podman store offline while the runners are idle (ADR-0105).
    # Leftovers reset the 16G scratch at 5% (0.8G) and the volume filesystem
    # at 5% (about 0.4G; its inode tables take 0.5G of the 8G device). Below
    # that, a pool job beside a forgejo-podman-large job of up to 12.8G keeps
    # 2.4G for its container layers (3.2G with no leftovers), less than the
    # 4G it gets on the other hosts, and two pool jobs share about 7.1G of
    # volumes, 3.5G each (ADR-0108).
    podmanStoreReset = {
      enable = true;
      scratchTriggerPercent = 5;
    };
    # Engines pull docker.io images through the LAN cache, falling back to
    # docker.io when it is down (#917).
    registryMirror = "registry-cache.alc.xyz";
    registryMirrorCaFile = ../../modules/nixos/services/forgejo-actions-runner/registry-cache-ca.crt;
    isolatedDocker.enable = true;
    isolatedDocker.retention.enable = true;
    podmanCanary = {
      enable = true;
      package = pkgs.callPackage "${inputs.nix-packages}/pkgs/forgejo-runner-cancellation" {};
      # The pool runner also serves ci-fast, opted-in jobs for the fast
      # hosts (ADR-0097), and forgejo-podman-large, jobs whose scratch only
      # xyz's RAM holds (ADR-0108), in the same slot as pool jobs.
      labels = [
        "forgejo-podman:docker://docker.io/library/docker:27-cli"
        "ci-fast:docker://docker.io/library/docker:27-cli"
        "forgejo-podman-large:docker://docker.io/library/docker:27-cli"
      ];
      # A second pool slot, beside the nearly idle Docker slot (ADR-0106).
      # It leaves out forgejo-podman-large, so large jobs never run two at
      # a time.
      secondSlot = {
        enable = true;
        labels = [
          "forgejo-podman:docker://docker.io/library/docker:27-cli"
          "ci-fast:docker://docker.io/library/docker:27-cli"
        ];
      };
      # Job throwaway data in RAM, images on disk (ADR-0108, #1027), shared
      # by both slots: 24G in all, as before, 16G of tmpfs for container
      # layers and 8G of zram for volumes, where BuildKit builds that run
      # dpkg work. Two pool jobs get the other hosts' 4G of each. A large
      # job, whose largest measured kept 12.7G live in its container, leaves
      # a pool job beside it only 3.2G of tmpfs for its layers, while that
      # job's volumes share the 8G with the large job's workspace. A 17G and
      # 7G split would favour that rarer pairing over two pool jobs. The
      # tmpfs counts against the CI memory limits below, and the zram is set
      # aside from them.
      scratch = {
        enable = true;
        size = "16G";
        volumes = {
          enable = true;
          size = "8G";
        };
      };
      # Trial: opted-in Nix jobs use a persistent, read-only store as the
      # lower layer of /nix/store instead of installing Nix (ADR-0109, #1038).
      # On the CI disk, under root-owned /ext4/ci.
      nixCache = {
        enable = true;
        dataPath = "/ext4/ci/forgejo-nix-cache";
        # The filler runs in the CI slice: 1G of staging, as on the other
        # hosts, caps it at 3G within the CI memory limits below.
        stageSize = "1G";
        # /ext4 also holds the Podman store, whose reset fires at 70% used:
        # the filler stops adding, and evicts, at 65% used.
        minFreePercent = 35;
        # Verified runs of these public repositories offer paths.
        offers = {
          forge = "https://git.alc.xyz";
          repos = ["alcxyz/nix-packages"];
        };
      };
    };
    # One Docker slot serves the few jobs that still select a Docker label.
    capacity = 1;
    # forgejobuilds.slice is one budget for CI and the nix-daemon (ADR-0108):
    # its hard limit at 64% (39.9 GiB of 62.3 GiB), with the 8G of zram for
    # CI's volumes, which no cgroup is charged for, beside it, leaves
    # 14.4 GiB for the desktop, the services and the ZFS ARC, which shrinks
    # under pressure. Its low weights make all building yield to desktop,
    # game and media work. CI's own limits, 51% throttle, 56% hard limit
    # (each 8G of zram, 12.8%, below what they were with the volumes in the
    # tmpfs) and half the CPUs, are split across the CI units, since the
    # slice also holds the daemon:
    # - The Podman API throttles at 46% (28.7 GiB), which holds the full 16G
    #   scratch its jobs write and two pool jobs' 6 GiB each (a large job
    #   takes 4.5 GiB) with 0.7 GiB for the engine (0.1 to 0.2 GiB idle).
    #   While the jobs keep to those budgets, which nothing enforces per job,
    #   a full scratch fails a write before the API is throttled. Hard
    #   limit 48% (29.9 GiB); 40% of the CPUs.
    # - The Docker engine and its one light job (tofu plans, probes): 2%
    #   (1.2 GiB) throttle, 3% (1.9 GiB) hard limit, 7% of the CPUs.
    # - The Nix store filler keeps its 3G cap; 3% of the CPUs.
    # The hard limits add up to 34.8 GiB, within the 56%, and the CPU
    # shares to the 50% ceiling.
    resourcePolicy = {
      enable = true;
      memoryHigh = "51%";
      memoryMax = "56%";
      sharedBudget = {
        enable = true;
        memoryMax = "64%";
        podmanApi = {
          memoryHigh = "46%";
          memoryMax = "48%";
          cpuQuotaPercent = 40;
        };
        dockerEngine = {
          memoryHigh = "2%";
          memoryMax = "3%";
          cpuQuotaPercent = 7;
        };
        nixCacheFillCpuQuotaPercent = 3;
      };
    };
    labels = [
      "forgejo-docker:docker://node:20-bookworm"
    ];
  };

  # xyz is the fleet's controller, so its own reboot also interrupts what the
  # operator and the other hosts run here.
  services.nixfleet-reboot-guard = let
    t3code = configDir.homeConfigurations."${username}-${hostName}".config.services.t3code.idleCheck;
  in {
    # The agreed rule: a running game on the controller blocks its self
    # reboot. The games are the game signal's (gaming.nix).
    game = {
      blocksReboot = true;
      inherit (config.services.gameSignal) user wineArgv0Basenames processNames;
    };
    streamServerUdpPorts = config.services.gameSignal.streamUdpPorts;
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
