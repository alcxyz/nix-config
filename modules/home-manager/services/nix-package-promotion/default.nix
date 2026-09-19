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
      nix
      openssh
      python3
      util-linux
    ];
    text = ''
      exec ${../../../../scripts/ci/run-local-package-promotion.sh}
    '';
  };
in {
  options.services.nixPackagePromotion = {
    enable = lib.mkEnableOption "trusted local validation and promotion of a package input lock";

    configRemote = lib.mkOption {
      type = lib.types.str;
      example = "https://code.example.net/operator/config.git";
      description = "Git remote for the trusted configuration branch. Native Git credentials provide push access.";
    };

    configBranch = lib.mkOption {
      type = lib.types.str;
      default = "dev";
      description = "Trusted configuration branch eligible for local validation and publication.";
    };

    packagesRemote = lib.mkOption {
      type = lib.types.str;
      example = "https://code.example.net/operator/packages.git";
      description = "Git remote whose trusted package branch is promoted into the configuration lock.";
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
          "NIX_PACKAGES_QUEUE_API_URL=${cfg.packagesQueueApiUrl}"
          "FORGEJO_URL=${cfg.forgejo.url}"
          "FORGEJO_OWNER=${cfg.forgejo.owner}"
          "FORGEJO_USER=${cfg.forgejo.user}"
          "FORGEJO_REPO=${cfg.forgejo.repository}"
          "FORGEJO_API_TOKEN_FILE=${cfg.forgejo.apiTokenFile}"
          "FORGEJO_STATUS_CONTEXT=${cfg.forgejo.statusContext}"
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
  };
}
