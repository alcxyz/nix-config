# One definition of "a game runs on this host" (ADR-0106). A root service
# scans for it and publishes the answer as a file that unprivileged units can
# test; the reboot guard reuses the same scan and lists.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.gameSignal;
  word = lib.types.strMatching "[A-Za-z0-9_.-]+";
  signal = pkgs.writeShellApplication {
    name = "game-signal";
    runtimeInputs = with pkgs; [coreutils iproute2 procps systemd];
    text = builtins.readFile ./game-signal.sh;
  };
in {
  options.services.gameSignal = {
    enable = lib.mkEnableOption "the host game signal";

    user = lib.mkOption {
      type = lib.types.strMatching "[a-z_][a-z0-9_-]*";
      description = "Account whose games are detected.";
    };

    wineArgv0Basenames = lib.mkOption {
      type = lib.types.listOf word;
      default = [];
      description = ''
        Wine games, by the basename of the first argument of the user's
        `wine64-preloader` processes. Only that argument is read, never other
        arguments or process environments.
      '';
    };

    processNames = lib.mkOption {
      type = lib.types.listOf word;
      default = [];
      description = "Exact process names (comm) of the user that run only while a game runs.";
    };

    streamUdpPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [];
      description = "UDP ports a game stream server binds only while a client streams.";
    };

    cooldownSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "How long the signal stays after the last game was seen.";
    };

    sampleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Interval between scans.";
    };

    uncertainSamples = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Consecutive uncertain scans that count as a game.";
    };

    file = lib.mkOption {
      type = lib.types.str;
      default = "/run/game-signal/active";
      readOnly = true;
      description = "File that exists while the signal reports a game.";
    };

    unit = lib.mkOption {
      type = lib.types.str;
      default = "game-signal.service";
      readOnly = true;
      description = "Unit that publishes the signal; consumers treat its absence as a game.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.wineArgv0Basenames != [] || cfg.processNames != [] || cfg.streamUdpPorts != [];
        message = "services.gameSignal needs at least one Wine game, process name or stream port.";
      }
    ];

    systemd.services.game-signal = {
      description = "Publish whether a game runs";
      wantedBy = ["multi-user.target"];
      environment = {
        SIGNAL_FILE = cfg.file;
        SAMPLE_SECONDS = toString cfg.sampleSeconds;
        COOLDOWN_SECONDS = toString cfg.cooldownSeconds;
        UNCERTAIN_SAMPLES = toString cfg.uncertainSamples;
        GAME_SCAN_FILE = "${./game-scan.sh}";
        GAME_USER = cfg.user;
        GAME_WINE_ARGV0_BASENAMES = lib.concatStringsSep " " cfg.wineArgv0Basenames;
        GAME_PROCESS_NAMES = lib.concatStringsSep " " cfg.processNames;
        GAME_STREAM_UDP_PORTS = lib.concatMapStringsSep " " toString cfg.streamUdpPorts;
      };
      serviceConfig = {
        # Ready after the first scan, so units ordered after it see a current
        # answer.
        Type = "notify";
        NotifyAccess = "all";
        ExecStart = lib.getExe signal;
        Restart = "always";
        RestartSec = "5s";
        RuntimeDirectory = "game-signal";
        RuntimeDirectoryMode = "0755";
        # A restart during a game keeps the signal until the next scan.
        RuntimeDirectoryPreserve = "yes";
      };
    };

    services.storage-health-monitor.units = lib.mkIf config.services.storage-health-monitor.enable [
      {
        name = "game-signal.service";
        mode = "active-not-degraded";
      }
    ];
  };
}
