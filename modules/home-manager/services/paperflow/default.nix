# modules/home-manager/services/paperflow/default.nix
{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.services.paperflow;
  isDarwin = pkgs.stdenv.isDarwin;
  paperflowPkg = inputs.paperflow.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  options.services.paperflow = {
    enable = mkEnableOption "Paperflow document organizer and Paperless ingestion";

    watchDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/Documents";
      description = "Directory to watch for new files.";
    };

    ingest = mkOption {
      type = types.enum [ "directory" "api" "none" ];
      default = "none";
      description = "Ingestion method: directory, api, or none.";
    };

    ingestDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/paperless-ingest";
      description = "Local directory for Paperless ingestion (when ingest = directory).";
    };

    paperlessUrl = mkOption {
      type = types.str;
      default = "";
      description = "Paperless-ngx base URL (when ingest = api).";
    };

    paperlessTokenFile = mkOption {
      type = types.str;
      default = "";
      description = "Path to file containing the Paperless API token (when ingest = api).";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      home.packages = [ paperflowPkg ];
    }

    # ---- Linux (systemd) ----
    (mkIf (!isDarwin) {
      systemd.user.services.paperflow = {
        Unit = {
          Description = "Paperflow document organizer";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };
        Service = {
          Type = "simple";
          ExecStart = builtins.concatStringsSep " " ([
            "${paperflowPkg}/bin/paperflow"
            "watch"
            "--watch" cfg.watchDir
            "--ingest" cfg.ingest
          ] ++ optionals (cfg.ingest == "directory") [
            "--ingest-dir" cfg.ingestDir
          ]);
          Restart = "on-failure";
          RestartSec = "5s";
          StandardOutput = "journal";
          StandardError = "journal";
        };
        Install.WantedBy = [ "default.target" ];
      };
    })

    # ---- macOS (launchd) ----
    (mkIf isDarwin {
      launchd.agents.paperflow = {
        enable = true;
        config = {
          ProgramArguments = [
            "${paperflowPkg}/bin/paperflow"
            "watch"
            "--watch" cfg.watchDir
            "--ingest" cfg.ingest
          ] ++ optionals (cfg.ingest == "api") [
            "--paperless-url" cfg.paperlessUrl
            "--paperless-token-file" cfg.paperlessTokenFile
          ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/paperflow.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/paperflow.log";
        };
      };
    })
  ]);
}
