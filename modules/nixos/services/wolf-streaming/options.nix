{
  lib,
  kdeConnectInputDefaults,
}: let
  registryImage = lib.types.strMatching "git[.]alc[.]xyz/alcxyz/[a-z0-9][a-z0-9._/-]*:(main|dev|editorial-dev)-[0-9]{8}[tT][0-9]{6}[zZ]-[0-9a-f]+@sha256:[0-9a-f]{64}";
in {
  enable = lib.mkEnableOption "Wolf Moonlight application streaming";

  image = lib.mkOption {
    type = registryImage;
    description = "Forgejo channel tag and digest for the amd64 Wolf container image.";
  };

  stateDirectory = lib.mkOption {
    type = lib.types.str;
    default = "/var/lib/wolf";
    description = "Persistent Wolf certificates, pairings, profiles, and application state.";
  };

  renderNode = lib.mkOption {
    type = lib.types.str;
    default = "/dev/dri/renderD128";
    description = "DRM render node used for virtual desktops and video encoding.";
  };

  defaultRunUid = lib.mkOption {
    type = lib.types.ints.unsigned;
    default = 1000;
    description = "Default UID assigned to newly paired Wolf application profiles.";
  };

  defaultRunGid = lib.mkOption {
    type = lib.types.ints.unsigned;
    default = 1000;
    description = "Default GID assigned to newly paired Wolf application profiles.";
  };

  openFirewall = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Open Wolf's documented Moonlight protocol ports.";
  };

  sessionIdleTimeoutSeconds = lib.mkOption {
    type = lib.types.ints.unsigned;
    default = 0;
    description = ''
      Seconds a disconnected stream or empty resumable lobby may remain
      available before Wolf stops it. Reconnecting to the stream or joining
      the lobby cancels the deadline. Zero disables idle expiry.
    '';
  };

  publicCoordinator = lib.mkOption {
    type = lib.types.enum [
      "host"
      "external"
    ];
    default = "host";
    description = ''
      Select whether this module runs the public Wolf coordinator itself or
      supplies node-local images, runtime assets, and helpers to an external
      single-writer supervisor such as Kubernetes.
    '';
  };

  publicRuntimeDirectory = lib.mkOption {
    type = lib.types.str;
    default = "/run/wolf-streaming/runtime";
    description = ''
      Host runtime directory containing the public Wolf coordinator socket.
      External coordinators must set this to their node-local runtime path.
    '';
  };

  vramWatchdog = {
    enable = lib.mkEnableOption "automatic recovery from sustained Wolf GPU-memory growth";

    maxUsedPercent = lib.mkOption {
      type = lib.types.ints.between 1 99;
      default = 80;
      description = "Percentage of total GPU memory Wolf may retain before recovery is considered.";
    };

    consecutiveSamples = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Consecutive high-memory samples required before Wolf is restarted.";
    };

    interval = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "30s";
      description = "Systemd time span between Wolf GPU-memory checks.";
    };
  };

  pipelineWatchdog = {
    enable = lib.mkEnableOption "automatic recovery from fatal Wolf video-pipeline failures";

    interval = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "15s";
      description = "Systemd time span between Wolf video-pipeline health checks.";
    };

    staleControlConnectionThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 32;
      description = ''
        Number of abandoned HTTP control connections that proves Wolf's
        coordinator is wedged even when its API still reports sessions.
        Reaching this threshold allows pipeline recovery to override stale
        session records instead of waiting indefinitely.
      '';
    };
  };

  prunedApplicationTitles = lib.mkOption {
    type = lib.types.listOf lib.types.nonEmptyStr;
    default = [];
    description = ''
      Application titles to remove from Wolf's direct Moonlight profile
      during reconciliation. Persistent application homes are not deleted.
    '';
  };

  browserImages = {
    enable = lib.mkEnableOption "registry-backed Wolf browser application images";

    keyboardLayouts = lib.mkOption {
      type = lib.types.nonEmptyListOf (
        lib.types.enum [
          "no"
          "us"
        ]
      );
      default = [
        "no"
        "us"
      ];
      description = "Ordered XKB layouts exposed inside each streamed browser; Alt+Shift cycles them.";
    };

    helium = {
      enable = lib.mkEnableOption "the Helium Wolf application image";
      publish = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Publish Helium directly in the Moonlight application list.";
      };
      cooperativeDefault = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Route the Helium catalog entry into one persistent multi-user
          lobby and publish Helium (Individual) as the opt-in isolated
          session.
        '';
      };
      pi3Compatibility = lib.mkEnableOption ''
        a software-encoded Helium catalog entry for Raspberry Pi 3 clients
      '';
      kdeConnect = {
        enable = lib.mkEnableOption ''
          KDE Connect inside the shared Helium desktop session. The single
          cooperative runner uses host networking so KDE Connect receives the
          original LAN peer address.
        '';
        pointerSensitivity = lib.mkOption {
          type = lib.types.numbers.positive;
          default = kdeConnectInputDefaults.pointerSensitivity;
          description = ''
            Maximum relative KDE Connect pointer gain inside the cooperative
            Helium desktop, reached during fast motion. The hidden X pointer
            and Sway cursor are moved together so clicks remain aligned.
          '';
        };
        pointerPrecisionSensitivity = lib.mkOption {
          type = lib.types.numbers.positive;
          default = kdeConnectInputDefaults.pointerPrecisionSensitivity;
          description = ''
            Relative KDE Connect pointer gain for slow, precise motion inside
            the cooperative Helium desktop.
          '';
        };
        pointerAccelerationStart = lib.mkOption {
          type = lib.types.numbers.nonnegative;
          default = kdeConnectInputDefaults.pointerAccelerationStart;
          description = ''
            Pointer speed in pixels per second where KDE Connect acceleration
            starts increasing above the precision gain.
          '';
        };
        pointerAccelerationFull = lib.mkOption {
          type = lib.types.numbers.positive;
          default = kdeConnectInputDefaults.pointerAccelerationFull;
          description = ''
            Pointer speed in pixels per second where KDE Connect reaches its
            maximum pointer gain.
          '';
        };
        scrollIntervalMs = lib.mkOption {
          type = lib.types.ints.between 0 1000;
          default = kdeConnectInputDefaults.scrollIntervalMs;
          description = ''
            Minimum interval between KDE Connect XTest wheel steps inside
            Helium. Zero preserves upstream packet-for-packet scrolling.
          '';
        };
      };
      image = lib.mkOption {
        type = registryImage;
        description = "Immutable registry image reference used by the Helium Wolf application.";
      };
    };

    brave = {
      enable = lib.mkEnableOption "the Brave Wolf application image";
      publish = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Publish Brave directly in the Moonlight application list; leave disabled for protected profiles.";
      };
      image = lib.mkOption {
        type = registryImage;
        description = "Immutable registry image reference used by the Brave Wolf application.";
      };
    };

    chromium = {
      enable = lib.mkEnableOption "the Chromium Wolf application image";
      image = lib.mkOption {
        type = registryImage;
        description = "Immutable registry image reference used by the protected Chromium application.";
      };
    };

    firefox = {
      enable = lib.mkEnableOption "the Firefox Wolf application image";
      image = lib.mkOption {
        type = registryImage;
        description = "Immutable registry image reference used by the protected Firefox application.";
      };
    };

    zen = {
      enable = lib.mkEnableOption "the Zen Wolf application image";
      image = lib.mkOption {
        type = registryImage;
        description = "Immutable registry image reference used by the protected Zen application.";
      };
    };
  };

  protectedProfile = {
    isolateBackend = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run the protected selector and browser capsules on an independent
        Wolf coordinator. A failure or restart on this backend cannot
        interrupt the public browser stream.
      '';
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/wolf-protected";
      description = "Persistent state for the isolated protected Wolf coordinator.";
    };

    portOffset = lib.mkOption {
      type = lib.types.ints.between 1 10000;
      default = 1000;
      description = ''
        Offset added to Wolf's standard Moonlight ports for the isolated
        protected coordinator.
      '';
    };

    definitionFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/credentials/docker-wolf.service/protected-profile";
      description = ''
        Root-only runtime JSON file defining the protected Wolf profile id,
        internal name, and PIN. Keep this file outside the Nix store. When
        set, protected browser applications are published only inside that
        profile and the file is loaded as a systemd credential before Wolf
        starts.
      '';
    };

    displayName = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "User";
      description = ''
        Neutral public label shown for the protected profile in Wolf UI.
        This deliberately overrides the private credential's internal name.
      '';
    };
  };
}
