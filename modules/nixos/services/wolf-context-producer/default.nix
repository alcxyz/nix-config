# nix-config/modules/nixos/services/wolf-context-producer/default.nix
#
# Prepares the committed Wolf image build contexts on this host's Nix store and
# hands them to the Podman/Buildx publisher (ADR-0074, Wolf image build
# placement). Runs as a dedicated system user, so it needs no repository clone
# or operator session on the host. Evaluating the image products does not read
# the private nix-secrets input, which Nix fetches lazily.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.wolfContextProducer;
  requiredScalar = name: value:
    if value == null || value == ""
    then throw "services.wolfContextProducer.${name} must be set to a non-empty value."
    else value;
  producer = pkgs.writeShellApplication {
    name = "wolf-context-producer";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      fd
      git
      gnutar
      gawk
      jq
      nix
      python3
      ripgrep
      util-linux
      zstd
    ];
    text = ''
      exec ${../../../../scripts/ci/run-local-wolf-contexts.sh}
    '';
  };
  stateDirectory = "/var/lib/wolf-context-producer";
in {
  options.services.wolfContextProducer = {
    enable = lib.mkEnableOption "native Wolf image context preparation and publisher dispatch";

    configRemote = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://code.example.net/operator/config.git";
      description = "Git remote of the trusted configuration repository. Required when enabled.";
    };

    configBranch = lib.mkOption {
      type = lib.types.str;
      default = "dev";
      description = "Trusted configuration branch whose committed head is prepared.";
    };

    calendar = lib.mkOption {
      type = lib.types.str;
      default = "*:0/15";
      description = "Schedule for preparing committed Wolf image contexts.";
    };

    forgejo = {
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Forgejo base URL for the context packages and publisher dispatch. Required when enabled.";
      };
      owner = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Owner of the configuration repository and its context packages. Required when enabled.";
      };
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Forgejo account that owns the producer token. Required when enabled.";
      };
      repository = lib.mkOption {
        type = lib.types.str;
        default = "nix-config";
        description = "Repository whose publisher workflow is dispatched.";
      };
    };

    credentials = {
      sopsFile = lib.mkOption {
        type = lib.types.nullOr (lib.types.oneOf [lib.types.path lib.types.str]);
        default = null;
        description = "Private sops file holding the producer's Forgejo token.";
      };
      tokenKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Sops key of a Forgejo token with the write:package and write:repository scopes, used for context packages and publisher dispatch.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.credentials.sopsFile != null && cfg.credentials.tokenKey != null;
        message = "services.wolfContextProducer.credentials must be set privately.";
      }
      {
        assertion = cfg.configBranch == "dev";
        message = "services.wolfContextProducer.configBranch: only committed dev is enabled for native Wolf builds.";
      }
    ];

    users.groups.wolf-context-producer = {};
    users.users.wolf-context-producer = {
      isSystemUser = true;
      group = "wolf-context-producer";
      home = stateDirectory;
    };
    # The service builds through the daemon and keeps an indirect GC root.
    nix.settings.allowed-users = ["wolf-context-producer"];

    sops.secrets.wolf_context_producer_token = {
      sopsFile = cfg.credentials.sopsFile;
      key = cfg.credentials.tokenKey;
      mode = "0400";
    };

    systemd.services.wolf-context-producer = {
      description = "Prepare committed Wolf image contexts on the native Nix store";
      after = ["network-online.target" "nix-daemon.socket"];
      wants = ["network-online.target"];
      # A context build must not disturb the host's interactive or cluster
      # workloads; the Nix daemon carries most of its work (see the host).
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe producer;
        User = "wolf-context-producer";
        Group = "wolf-context-producer";
        StateDirectory = "wolf-context-producer";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "wolf-context-producer";
        # The build's out-link is an indirect GC root that the Nix daemon must
        # resolve, so working files cannot live in a private /tmp.
        CacheDirectory = "wolf-context-producer";
        CacheDirectoryMode = "0700";
        LoadCredential = ["forgejo-token:${config.sops.secrets.wolf_context_producer_token.path}"];
        TimeoutStartSec = "8h";
        SuccessExitStatus = "75";
        UMask = "0077";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
      environment = {
        HOME = stateDirectory;
        XDG_RUNTIME_DIR = "/run/wolf-context-producer";
        TMPDIR = "/var/cache/wolf-context-producer";
        GIT_TERMINAL_PROMPT = "0";
        CONFIG_REMOTE = requiredScalar "configRemote" cfg.configRemote;
        CONFIG_BRANCH = cfg.configBranch;
        FORGEJO_URL = requiredScalar "forgejo.url" cfg.forgejo.url;
        FORGEJO_OWNER = requiredScalar "forgejo.owner" cfg.forgejo.owner;
        FORGEJO_USER = requiredScalar "forgejo.user" cfg.forgejo.user;
        FORGEJO_REPO = cfg.forgejo.repository;
        # One token authenticates package transport and the dispatch.
        FORGEJO_API_TOKEN_FILE = "%d/forgejo-token";
        PACKAGE_TOKEN_FILE = "%d/forgejo-token";
        WOLF_CONTEXT_STATE_DIRECTORY = "${stateDirectory}/state";
      };
    };

    systemd.timers.wolf-context-producer = {
      description = "Schedule native Wolf image context preparation";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.calendar;
        RandomizedDelaySec = "2m";
        Persistent = false;
      };
    };
  };
}
