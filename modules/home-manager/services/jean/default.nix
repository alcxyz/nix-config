{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.jean;
  inherit
    (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  authArgs =
    if cfg.disableTokenAuth
    then [
      "--no-token"
      "--allow-unsafe-no-token"
    ]
    else [];
in {
  options.services.jean = {
    enable = mkEnableOption "Jean headless server";

    package = mkOption {
      type = types.package;
      default = pkgs.jean;
      defaultText = lib.literalExpression "pkgs.jean";
      description = "Jean server package to run.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address on which Jean listens.";
    };

    port = mkOption {
      type = types.port;
      default = 3456;
      description = "TCP port on which Jean listens.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.local/share/jean";
      description = "Persistent Jean application data directory.";
    };

    disableTokenAuth = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Disable Jean's built-in token authentication. Only use this when an
        authenticated reverse proxy and source-restricted firewall protect the
        listener.
      '';
    };

    allowNativeOpen = mkOption {
      type = types.bool;
      default = false;
      description = "Allow web clients to launch editors, terminals, and file managers on the host.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.disableTokenAuth
          || builtins.elem cfg.host [
            "127.0.0.1"
            "localhost"
            "::1"
          ];
        message = "services.jean requires token authentication for non-loopback listeners";
      }
    ];

    systemd.user.services.jean = {
      Unit = {
        Description = "Jean headless server";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
      };

      Service = {
        Environment = [
          "JEAN_DATA_DIR=${cfg.dataDir}"
          "PATH=${
            lib.makeBinPath [
              pkgs.bash
              pkgs.bubblewrap
              pkgs.coreutils
              pkgs.git
              pkgs.nodejs_22
              pkgs.openssh
              pkgs.which
              pkgs.claude-code
              pkgs.codex-cli
            ]
          }"
        ];
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/jean-server"
            "--host"
            cfg.host
            "--port"
            (toString cfg.port)
          ]
          ++ authArgs
          ++ lib.optional cfg.allowNativeOpen "--allow-native-open"
        );
        Restart = "on-failure";
        RestartSec = 3;
      };

      Install.WantedBy = ["default.target"];
    };
  };
}
