# A persistent, read-only Nix store per runner host that Podman pool jobs
# mount as the lower layer of their /nix/store, filled only by a
# credential-free host service (ADR-0109, #1038).
{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  canary = cfg.podmanCanary;
  cache = canary.nixCache;
  enabled = cfg.enable && canary.enable && cache.enable;
  apiUnit = "forgejo-runner-podman.service";
  prepareUnit = "forgejo-nix-cache-prepare.service";
  fillerUser = "forgejo-nix-cache";
  fillRuntime = "/run/forgejo-nix-cache-fill";
  # The fill's start, after which the drop directory's older entries go.
  fillStamp = "/run/forgejo-nix-cache-fill.stamp";
  prepareArgs = action:
    utils.escapeSystemdExecArgs [
      (lib.getExe prepare)
      action
      cache.dataPath
      cache.path
      cache.dropPath
      cache.dropSize
      fillerUser
      "forgejo-podman-builder"
      "forgejo-podman"
      (lib.getExe init)
    ];
  sizeBytes = size: let
    number = lib.toInt (lib.removeSuffix "G" (lib.removeSuffix "M" size));
  in
    if lib.hasSuffix "G" size
    then number * 1024 * 1024 * 1024
    else number * 1024 * 1024;

  prepare = pkgs.writeShellApplication {
    name = "forgejo-nix-cache-prepare";
    runtimeInputs = with pkgs; [coreutils getent gnugrep util-linux];
    text = builtins.readFile ./nix-cache-prepare.sh;
  };
  init = pkgs.writeShellApplication {
    name = "forgejo-nix-cache-init";
    runtimeInputs = with pkgs; [coreutils sqlite cache.package];
    text = builtins.readFile ./nix-cache-init.sh;
  };
  fill = pkgs.writeShellApplication {
    name = "forgejo-nix-cache-fill";
    runtimeInputs = with pkgs; [coreutils curl diffutils findutils gawk git gnugrep gnused jq sqlite cache.package];
    text = builtins.readFile ./nix-cache-fill.sh;
  };
  # The filler's whole Nix configuration: no host nix.conf, netrc, access
  # tokens, registries or remote builders, signatures required, no builds.
  nixConf = pkgs.writeTextDir "nix.conf" ''
    substituters = ${lib.concatStringsSep " " cache.substituters}
    trusted-substituters =
    trusted-public-keys = ${lib.concatStringsSep " " cache.trustedPublicKeys}
    require-sigs = true
    max-jobs = 0
    builders =
    netrc-file = /dev/null
    access-tokens =
    flake-registry =
    experimental-features = nix-command flakes
    build-users-group =
    sandbox = false
    fallback = false
    connect-timeout = 10
    warn-dirty = false
  '';
in {
  options.services.forgejo-actions-runner.podmanCanary.nixCache = {
    enable = lib.mkEnableOption ''
      a persistent, read-only Nix store that Podman pool jobs mount as the
      lower layer of their /nix/store, so cached paths are neither
      downloaded nor written again; filled only by a credential-free host
      service (ADR-0109)
    '';
    path = lib.mkOption {
      type = lib.types.str;
      default = "/run/forgejo-nix-cache";
      readOnly = true;
      description = ''
        Read-only, ID-mapped view of the store root that workflows mount:
        `''${path}/nix/store` as an overlay (`:O`) at /nix/store, and
        `''${path}/job` (the database snapshot and the `nix` link) read-only.
      '';
    };
    dataPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/forgejo-ci-nix-cache";
      example = "/ext4/ci/forgejo-nix-cache";
      description = ''
        Store root, owned by the filler, preferably on the CI disk. Every
        ancestor must be a directory only root can change: the preparation
        refuses the store otherwise, so it can never sit under
        /var/lib/forgejo-podman, which the Podman API's user owns. The
        Podman store reset leaves it alone.
      '';
    };
    dropPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/forgejo-nix-cache-drop";
      readOnly = true;
      description = "Directory, writable only by the filler and root, holding path lists (`*.paths`) and flake locks (`*.lock`) for the filler (ADR-0109).";
    };
    dropSize = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*[MG]";
      default = "64M";
      description = "Size of the drop directory's tmpfs.";
    };
    sizeCap = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*[MG]";
      default = "30G";
      description = ''
        Bound of the store, as the sum of its NAR sizes. The filler stops
        adding paths for the run once the store reaches it, so a run
        overshoots by at most one closure, and its collection drops the
        oldest GC roots until the store fits again. It counts toward the CI
        disk's use for the store reset and the runner hold.
      '';
    };
    runLimit = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*[MG]";
      default = "5G";
      description = ''
        Most a single fill adds to the store, as NAR size; the run stops
        adding past it and overshoots by at most one closure. It bounds what
        one list can make a fill write, beside `sizeCap`, which bounds the
        store.
      '';
    };
    stageSize = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*[MG]";
      default = "4G";
      description = ''
        Size of the filler's private tmpfs for fetching flake inputs and
        Nix's download cache. Each input is staged and checked there and the
        staging is emptied after it, so a rejected input leaves nothing
        behind; an input larger than this fails. The tmpfs is charged to the
        filler, whose memory limit is this size plus 2G.
      '';
    };
    minFreePercent = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 20;
      description = ''
        Free space the filler leaves on the CI filesystem: it stops adding
        paths for the run once less is free, as it does at `sizeCap`.
      '';
    };
    maxAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = "Days a path stays after the last list that named it.";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = "Time between filler runs.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nix;
      defaultText = lib.literalExpression "pkgs.nix";
      description = ''
        Nix that the filler runs and that it keeps in the store for jobs
        (`''${path}/job/nix`). It must be in the substituters, signed.
      '';
    };
    substituters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["https://cache.nixos.org"];
      description = "The only caches the filler substitutes from.";
    };
    trustedPublicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="];
      description = "The only keys whose signatures admit a path into the store.";
    };
    offers = {
      forge = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "https://[A-Za-z0-9.-]+(:[0-9]+)?");
        default = null;
        example = "https://git.example.org";
        description = ''
          Forgejo instance whose CI runs may offer paths. The filler looks
          runs up through its anonymous API and takes an offer only from a
          run it verified: in one of `repos`, finished, and a push to the
          repository's default branch or a pull request whose head and base
          are that repository, never a fork (ADR-0109).
        '';
      };
      repos = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9._-]+/[A-Za-z0-9._-]+");
        default = [];
        example = ["owner/packages"];
        description = ''
          Public repositories, as owner/name, whose verified runs offer
          paths: the `nix-cache-offer <store path>` lines in their job logs,
          and the flake lock at the run's commit.
        '';
      };
      maxRuns = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = "Most recent runs per repository the filler looks at on each run; each is read once.";
      };
    };
    jobVolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      # Not the drop directory: the runner cannot tell a fork's job, which
      # controls its own workflow, from a trusted one (ADR-0109).
      default = lib.optionals cache.enable [
        "${cache.path}/nix/store"
        "${cache.path}/job"
      ];
      description = "Host paths the pool runner lets jobs mount.";
    };
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = cache.offers.repos == [] || cache.offers.forge != null;
        message = "podmanCanary.nixCache.offers.repos needs offers.forge.";
      }
      {
        assertion = lib.hasPrefix "/" cache.dataPath && !(lib.hasPrefix "/var/lib/forgejo-podman/" cache.dataPath) && cache.dataPath != "/var/lib/forgejo-podman";
        message = "podmanCanary.nixCache.dataPath must be absolute and outside /var/lib/forgejo-podman, whose owner is the Podman API's user.";
      }
    ];

    users.groups.${fillerUser} = {};
    users.users.${fillerUser} = {
      isSystemUser = true;
      group = fillerUser;
      description = "Credential-free filler of the CI Nix store";
    };

    systemd.services.forgejo-nix-cache-prepare = {
      description = "Expose the CI Nix store read-only to Podman jobs";
      wantedBy = ["multi-user.target"];
      before = [apiUnit];
      unitConfig.RequiresMountsFor = [cache.dataPath];
      # A restart publishes the store mount at /run/forgejo-nix-cache again
      # (the placeholder in between); a deploy leaves it alone.
      restartIfChanged = false;
      # The filler's Nix configuration, for the store's initialisation.
      environment = {
        NIX_CONF_DIR = "${nixConf}";
        NIX_USER_CONF_FILES = "${nixConf}/nix.conf";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = prepareArgs "start";
        # Stopped or removed, it leaves the empty read-only placeholder, so
        # jobs that still bind the paths start and fall back until the
        # runner restarts without them.
        ExecStop = prepareArgs "stop";
      };
    };

    # The API starts after the mounts; only a want, so a deploy that adds
    # them stops nothing.
    systemd.services.forgejo-runner-podman = {
      wants = [prepareUnit];
      after = [prepareUnit];
    };

    systemd.services.forgejo-nix-cache-fill = {
      description = "Fill and collect the CI Nix store";
      requires = [prepareUnit];
      after = [prepareUnit "network-online.target"];
      wants = ["network-online.target"];
      unitConfig.RequiresMountsFor = [cache.dataPath];
      environment = {
        CACHE_ROOT = cache.dataPath;
        DROP_DIR = cache.dropPath;
        OFFER_FORGE = lib.optionalString (cache.offers.forge != null) cache.offers.forge;
        OFFER_REPOS = lib.concatStringsSep " " cache.offers.repos;
        OFFER_MAX_RUNS = toString cache.offers.maxRuns;
        NIX_PACKAGE = "${cache.package}";
        MAX_AGE_DAYS = toString cache.maxAgeDays;
        SIZE_CAP_BYTES = toString (sizeBytes cache.sizeCap);
        MIN_FREE_PERCENT = toString cache.minFreePercent;
        RUN_LIMIT_BYTES = toString (sizeBytes cache.runLimit);
        HOME = fillRuntime;
        # Nix's download caches, inside the size-limited staging tmpfs.
        XDG_CACHE_HOME = "/var/tmp/cache";
        XDG_CONFIG_HOME = "${fillRuntime}/config";
        NIX_CONF_DIR = "${nixConf}";
        NIX_USER_CONF_FILES = "${nixConf}/nix.conf";
        NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        GIT_SSL_CAINFO = "/etc/ssl/certs/ca-certificates.crt";
        # Git must never find a credential, prompt or key.
        GIT_CONFIG_NOSYSTEM = "1";
        GIT_CONFIG_GLOBAL = "/dev/null";
        GIT_TERMINAL_PROMPT = "0";
        GIT_ASKPASS = "${pkgs.coreutils}/bin/false";
        SSH_ASKPASS = "${pkgs.coreutils}/bin/false";
        GIT_SSH_COMMAND = "${pkgs.coreutils}/bin/false";
      };
      serviceConfig = {
        Type = "oneshot";
        User = fillerUser;
        Group = fillerUser;
        UMask = "0022";
        Slice = "forgejobuilds.slice";
        Nice = 19;
        IOSchedulingClass = "idle";
        TimeoutStartSec = "3h";
        RuntimeDirectory = "forgejo-nix-cache-fill";
        RuntimeDirectoryMode = "0700";
        # The queue of listed paths and inputs not yet dealt with, private
        # to the filler.
        StateDirectory = "forgejo-nix-cache-fill";
        StateDirectoryMode = "0700";
        # The staging tmpfs is charged to the filler.
        MemoryMax = toString (sizeBytes cache.stageSize + 2 * 1024 * 1024 * 1024);
        # Keep the previous fill's start as the sweep's horizon, then stamp
        # this one.
        ExecStartPre = "+${pkgs.writeShellScript "forgejo-nix-cache-fill-stamp" ''
          if [ -e ${fillStamp} ]; then ${pkgs.coreutils}/bin/mv -f ${fillStamp} ${fillStamp}.prev; fi
          ${pkgs.coreutils}/bin/touch ${fillStamp}
        ''}";
        ExecStart = lib.getExe fill;
        # The filler removes only the lists it reads. Root drops anything else
        # that has lain in the drop directory since before the previous fill
        # started, by change time and never following links, so a list still
        # being written, which is newer, survives.
        ExecStartPost = "-+${pkgs.writeShellScript "forgejo-nix-cache-drop-sweep" ''
          if [ -e ${fillStamp}.prev ]; then
            ${pkgs.findutils}/bin/find ${cache.dropPath} -mindepth 1 ! -cnewer ${fillStamp}.prev -delete
          fi
        ''}";
        ReadWritePaths = [cache.dataPath cache.dropPath];
        # No credentials: neither the host's Nix configuration and netrc nor
        # any secret, key or home directory is visible.
        InaccessiblePaths = [
          "-/etc/nix"
          "-/etc/ssh"
          "-/etc/gitconfig"
          "-/root"
          "-/run/secrets"
          "-/run/secrets-for-users"
          "-/run/credentials"
          "-/run/forgejo-podman"
          "-/var/lib/sops-nix"
          "-/var/lib/forgejo-podman-runner"
          "-/var/lib/forgejo-actions-runner"
        ];
        ProtectSystem = "strict";
        ProtectHome = true;
        # Private, size-limited /tmp and /var/tmp: the staging of flake
        # inputs and Nix's caches stay within stageSize.
        TemporaryFileSystem = ["/tmp:size=64M,mode=1777" "/var/tmp:size=${cache.stageSize},mode=1777"];
        PrivateDevices = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        LockPersonality = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        SystemCallArchitectures = "native";
      };
    };

    systemd.timers.forgejo-nix-cache-fill = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitInactiveSec = cache.interval;
      };
    };
  };
}
