{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nixPackagePromotion;
  promoter = pkgs.writeShellApplication {
    name = "nix-package-promotion";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      curl
      forge-mirror
      git
      gawk
      jq
      # `nix flake check --out-link` needs Nix 2.35; plain pkgs.nix lags.
      nixVersions.latest
      openssh
      python3
      util-linux
    ];
    text = ''
      exec ${../../../../scripts/ci/run-local-package-promotion.sh}
    '';
  };
  dmsUpdater = pkgs.writeShellApplication {
    name = "nix-dms-update";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      curl
      forge-mirror
      git
      gawk
      jq
      nix
      python3
      util-linux
    ];
    text = ''
      exec ${../../../../scripts/ci/run-local-dms-update.sh}
    '';
  };
  wolfContexts = pkgs.writeShellApplication {
    name = "nix-wolf-contexts";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      fd
      forge-mirror
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
in {
  options.services.nixPackagePromotion = {
    enable = lib.mkEnableOption "trusted local validation and promotion of package revisions";

    configRemote = lib.mkOption {
      type = lib.types.str;
      example = "https://code.example.net/operator/config.git";
      description = "Git remote for the trusted configuration branch that is validated with each package candidate.";
    };

    configBranch = lib.mkOption {
      type = lib.types.str;
      default = "dev";
      description = "Trusted configuration branch eligible for local validation and publication.";
    };

    packagesRemote = lib.mkOption {
      type = lib.types.str;
      example = "https://code.example.net/operator/packages.git";
      description = "Git remote whose trusted package branch is validated and promoted. Native Git credentials provide push access to the promoted branch.";
    };

    packagesBranch = lib.mkOption {
      type = lib.types.str;
      default = "dev";
      description = "Trusted package producer branch.";
    };

    packagesQueueApiUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://code.example.net/api/v1/repos/operator/packages/pulls?state=open&base=dev&limit=100";
      description = "Forgejo API URL used to defer while package update branches remain open.";
    };

    forgejo = {
      url = lib.mkOption {
        type = lib.types.str;
        example = "https://code.example.net";
        description = "Forgejo base URL for exact commit receipts.";
      };
      owner = lib.mkOption {
        type = lib.types.str;
        description = "Forgejo owner of the configuration repository.";
      };
      user = lib.mkOption {
        type = lib.types.str;
        description = "Forgejo account used by the native Git credential helper.";
      };
      repository = lib.mkOption {
        type = lib.types.str;
        description = "Forgejo configuration repository name.";
      };
      apiTokenFile = lib.mkOption {
        type = lib.types.str;
        description = "Activated credential file read internally when publishing commit statuses.";
      };
      statusContext = lib.mkOption {
        type = lib.types.str;
        default = "ci/local-configurations";
        description = "Commit status context used as the exact local validation receipt.";
      };
    };

    calendar = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd OnCalendar expression for local validation.";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "30m";
      description = "Maximum randomized delay applied to the timer.";
    };

    dms = {
      enable = lib.mkEnableOption "trusted local DMS plugin lock updates";
      calendar = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "systemd OnCalendar expression for native DMS lock updates.";
      };
      randomizedDelaySec = lib.mkOption {
        type = lib.types.str;
        default = "30m";
        description = "Maximum randomized delay applied to the DMS update timer.";
      };
      admissionUnit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional system unit that must be active before a DMS update starts.";
      };
    };

    wolf = {
      enable = lib.mkEnableOption "trusted native Wolf image context publication";
      calendar = lib.mkOption {
        type = lib.types.str;
        default = "*:0/15";
        description = "Schedule for preparing committed Wolf image contexts.";
      };
      admissionUnit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = cfg.dms.admissionUnit;
        description = "Optional system unit that must be active before a native Wolf build starts.";
      };
      dockerConfigFile = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.docker/config.json";
        description = "Docker client configuration used internally for package transport.";
      };
      stateDirectory = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.local/state/wolf-contexts";
        description = "Directory retaining only each channel's latest successful Nix output root.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.nix-package-promotion = {
      Unit = {
        Description = "Validate trusted package and configuration heads locally";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${promoter}/bin/nix-package-promotion";
        TimeoutStartSec = "8h";
        SuccessExitStatus = "75";
        UMask = "0077";
        Nice = 10;
        IOSchedulingClass = "idle";
        StandardOutput = "journal";
        StandardError = "journal";
        Environment = [
          "HOME=${config.home.homeDirectory}"
          "GIT_TERMINAL_PROMPT=0"
          "CONFIG_REMOTE=${cfg.configRemote}"
          "CONFIG_BRANCH=${cfg.configBranch}"
          "NIX_PACKAGES_REMOTE_URL=${cfg.packagesRemote}"
          "NIX_PACKAGES_BRANCH=${cfg.packagesBranch}"
          # The t3code updater and the deploy wrapper follow this name (ADR-0080).
          "NIX_PACKAGES_PROMOTED_BRANCH=promoted"
          "NIX_PACKAGES_QUEUE_API_URL=${cfg.packagesQueueApiUrl}"
          "FORGEJO_URL=${cfg.forgejo.url}"
          "FORGEJO_OWNER=${cfg.forgejo.owner}"
          "FORGEJO_USER=${cfg.forgejo.user}"
          "FORGEJO_REPO=${cfg.forgejo.repository}"
          "FORGEJO_API_TOKEN_FILE=${cfg.forgejo.apiTokenFile}"
          "FORGEJO_STATUS_CONTEXT=${cfg.forgejo.statusContext}"
          "CHECK_RESULTS_ROOT_DIR=${config.home.homeDirectory}/.local/state/nix-package-promotion/check-roots"
        ];
      };
    };

    systemd.user.timers.nix-package-promotion = {
      Unit.Description = "Schedule trusted local package and configuration validation";
      Timer = {
        OnCalendar = cfg.calendar;
        RandomizedDelaySec = cfg.randomizedDelaySec;
        Persistent = true;
        Unit = "nix-package-promotion.service";
      };
      Install.WantedBy = ["timers.target"];
    };

    systemd.user.services.nix-dms-update = lib.mkIf cfg.dms.enable {
      Unit = {
        Description = "Refresh and build DMS plugins on the trusted local Nix store";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
      };
      Service =
        {
          Type = "oneshot";
          ExecStart = "${dmsUpdater}/bin/nix-dms-update";
          TimeoutStartSec = "8h";
          SuccessExitStatus = "75";
          UMask = "0077";
          Nice = 10;
          IOSchedulingClass = "idle";
          StandardOutput = "journal";
          StandardError = "journal";
          Environment = [
            "HOME=${config.home.homeDirectory}"
            "GIT_TERMINAL_PROMPT=0"
            "CONFIG_REMOTE=${cfg.configRemote}"
            "CONFIG_BRANCH=${cfg.configBranch}"
            "FORGEJO_URL=${cfg.forgejo.url}"
            "FORGEJO_OWNER=${cfg.forgejo.owner}"
            "FORGEJO_REPO=${cfg.forgejo.repository}"
            "FORGEJO_API_TOKEN_FILE=${cfg.forgejo.apiTokenFile}"
          ];
        }
        // lib.optionalAttrs (cfg.dms.admissionUnit != null) {
          ExecCondition = "${pkgs.systemd}/bin/systemctl --system is-active --quiet ${lib.escapeShellArg cfg.dms.admissionUnit}";
        };
    };

    systemd.user.timers.nix-dms-update = lib.mkIf cfg.dms.enable {
      Unit.Description = "Schedule trusted local DMS plugin validation";
      Timer = {
        OnCalendar = cfg.dms.calendar;
        RandomizedDelaySec = cfg.dms.randomizedDelaySec;
        Persistent = false;
        Unit = "nix-dms-update.service";
      };
      Install.WantedBy = ["timers.target"];
    };

    systemd.user.services.nix-wolf-contexts = lib.mkIf cfg.wolf.enable {
      Unit = {
        Description = "Prepare committed Wolf image contexts on the native Nix store";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
      };
      Service =
        {
          Type = "oneshot";
          ExecStart = "${wolfContexts}/bin/nix-wolf-contexts";
          TimeoutStartSec = "8h";
          SuccessExitStatus = "75";
          UMask = "0077";
          Nice = 10;
          IOSchedulingClass = "idle";
          StandardOutput = "journal";
          StandardError = "journal";
          Environment = [
            "HOME=${config.home.homeDirectory}"
            "GIT_TERMINAL_PROMPT=0"
            "CONFIG_REMOTE=${cfg.configRemote}"
            "CONFIG_BRANCH=${cfg.configBranch}"
            "FORGEJO_URL=${cfg.forgejo.url}"
            "FORGEJO_OWNER=${cfg.forgejo.owner}"
            "FORGEJO_REPO=${cfg.forgejo.repository}"
            "FORGEJO_API_TOKEN_FILE=${cfg.forgejo.apiTokenFile}"
            "DOCKER_CONFIG_FILE=${cfg.wolf.dockerConfigFile}"
            "WOLF_CONTEXT_STATE_DIRECTORY=${cfg.wolf.stateDirectory}"
          ];
        }
        // lib.optionalAttrs (cfg.wolf.admissionUnit != null) {
          ExecCondition = "${pkgs.systemd}/bin/systemctl --system is-active --quiet ${lib.escapeShellArg cfg.wolf.admissionUnit}";
        };
    };

    systemd.user.timers.nix-wolf-contexts = lib.mkIf cfg.wolf.enable {
      Unit.Description = "Schedule trusted native Wolf image context preparation";
      Timer = {
        OnCalendar = cfg.wolf.calendar;
        RandomizedDelaySec = "2m";
        Persistent = false;
        Unit = "nix-wolf-contexts.service";
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
