# nix-config/modules/nixos/services/nixfleet-reboot-guard/default.nix
#
# nixfleet-reboot-guard tells nixfleet whether someone is using an interactive
# host before nixfleet reboots it (nix-packages #548). The inventory names the
# command (packages/nix-deploy); the hosts' roles enable it.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nixfleet-reboot-guard;
  word = lib.types.strMatching "[^[:space:]]+";
  boolFlag = value:
    if value
    then "1"
    else "0";
  prelude = ''
    host_name=${lib.escapeShellArg config.networking.hostName}
    desktop_sessions=${boolFlag cfg.desktopSessions}
    game_user=${lib.escapeShellArg cfg.game.user}
    game_verb=${
      if cfg.game.blocksReboot
      then "block"
      else "busy"
    }
    game_helper=${../game-signal/game-scan.sh}
    game_wine_argv0_basenames=(${lib.escapeShellArgs cfg.game.wineArgv0Basenames})
    game_process_names=(${lib.escapeShellArgs cfg.game.processNames})
    moonlight_user=${lib.escapeShellArg cfg.moonlightClient.user}
    moonlight_units=(${lib.escapeShellArgs cfg.moonlightClient.units})
    stream_udp_ports=(${lib.escapeShellArgs (map toString cfg.streamServerUdpPorts)})
    busy_units=(${lib.escapeShellArgs cfg.backupUnits})
    operator_user=${lib.escapeShellArg cfg.operator.user}
    operator_agent_jobs=${boolFlag cfg.operator.agentJobs}
    operator_tmux=${boolFlag cfg.operator.tmux}
    t3code_idle_check=${
      if cfg.operator.t3code.idleCheck == null
      then "''"
      else lib.getExe cfg.operator.t3code.idleCheck
    }
    t3code_names=(${lib.escapeShellArgs (map (instance: instance.name) cfg.operator.t3code.instances)})
    t3code_units=(${lib.escapeShellArgs (map (instance: instance.unit) cfg.operator.t3code.instances)})
    remote_nix_clients=${boolFlag cfg.remoteNixClients}
    static_notes=(${lib.escapeShellArgs cfg.notes})
  '';
  guard = pkgs.writeShellApplication {
    name = "nixfleet-reboot-guard";
    runtimeInputs =
      [
        pkgs.coreutils
        pkgs.getent
        pkgs.gnugrep
        pkgs.gnused
        pkgs.iproute2
        pkgs.jq
        pkgs.procps
        pkgs.systemd
        pkgs.util-linux
      ]
      ++ lib.optional cfg.desktopSessions config.programs.hyprland.package
      ++ lib.optional cfg.operator.tmux pkgs.tmux;
    text = prelude + builtins.readFile ./reboot-guard.sh;
  };
in {
  options.services.nixfleet-reboot-guard = {
    enable = lib.mkEnableOption "the nixfleet reboot guard command";

    package = lib.mkOption {
      type = lib.types.package;
      default = guard;
      readOnly = true;
      description = "The nixfleet-reboot-guard command.";
    };

    desktopSessions = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Report an active local desktop session, busy unless Hyprland reports it locked.";
    };

    game = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Account whose games are detected; empty disables game detection.";
      };
      blocksReboot = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether a running game blocks the reboot instead of only making the host busy.";
      };
      wineArgv0Basenames = lib.mkOption {
        type = lib.types.listOf word;
        default = [];
        description = "Wine game executables, detected with the game signal's scan.";
      };
      processNames = lib.mkOption {
        type = lib.types.listOf word;
        default = [];
        description = "Exact process names (comm) of the user that mean a game runs.";
      };
    };

    moonlightClient = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Account whose Moonlight stream units are checked.";
      };
      units = lib.mkOption {
        type = lib.types.listOf word;
        default = [];
        description = "User units that run while a Moonlight stream is active.";
      };
    };

    streamServerUdpPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [];
      description = "UDP ports a game stream server binds only while a client streams.";
    };

    backupUnits = lib.mkOption {
      type = lib.types.listOf word;
      default = [];
      description = "System units whose current run makes the host busy.";
    };

    operator = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Operator account whose agent jobs, T3 Code turns and tmux sessions are reported.";
      };
      agentJobs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Note the operator's running agent jobs.";
      };
      tmux = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Note the operator's tmux sessions.";
      };
      t3code = {
        idleCheck = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          description = "The operator's t3code-idle-check, which exits 75 while an instance has live work.";
        };
        instances = lib.mkOption {
          type = lib.types.listOf (lib.types.submodule {
            options = {
              name = lib.mkOption {type = word;};
              unit = lib.mkOption {type = word;};
            };
          });
          default = [];
          description = "T3 Code instances whose running turns make the host busy.";
        };
      };
    };

    remoteNixClients = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Note remote Nix clients (builds or cache reads) connected over SSH.";
    };

    notes = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[^\n]+");
      default = [];
      description = "Notes always shown before the reboot, such as which other hosts depend on this one.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.operator.t3code.instances == [] || cfg.operator.t3code.idleCheck != null;
        message = "services.nixfleet-reboot-guard.operator.t3code.instances needs idleCheck.";
      }
    ];
    environment.systemPackages = [guard];
  };
}
