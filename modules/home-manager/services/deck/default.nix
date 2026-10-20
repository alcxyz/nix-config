# modules/home-manager/services/deck/default.nix
#
# deck (nix-packages ADR-0012) serves a live dashboard of T3 Code threads. It
# reads them only through the t3-thread-* commands that programs.ai installs
# (ADR-0091), so it runs as a user service beside the T3 servers whose state
# databases those commands read.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.deck;
  toml = pkgs.formats.toml {};
  configFile = toml.generate "deck.toml" cfg.settings;
in {
  options.services.deck = {
    enable = lib.mkEnableOption "the deck T3 thread dashboard";

    package = lib.mkPackageOption pkgs "deck" {};

    settings = lib.mkOption {
      inherit (toml) type;
      default = {};
      example = lib.literalExpression ''
        {
          listen = "0.0.0.0:3775";
          publicOrigin = "https://deck.example.com";
          auth = {
            issuer = "https://id.example.com";
            clientID = "deck";
            group = "admins";
          };
          threads.instance = [
            {
              name = "main";
              db = "''${config.home.homeDirectory}/.t3/userdata/statev2.sqlite";
              webURL = "https://t3.example.com";
            }
          ];
        }
      '';
      description = ''
        deck's configuration file, as described in its README in nix-packages
        (`tools/deck/README.md`). The t3-thread-* commands are found on the
        service's PATH unless `commands` names them.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.programs.ai.enable or false;
        message = "services.deck reads threads through the t3-thread-* commands of programs.ai; enable it too.";
      }
      {
        assertion = (cfg.settings.threads.instance or []) != [];
        message = "services.deck.settings.threads.instance must list at least one T3 instance.";
      }
    ];

    systemd.user.services.deck = {
      Unit = {
        Description = "deck, the live T3 thread dashboard";
        After = ["network-online.target"];
      };
      Service = {
        ExecStart = "${lib.getExe cfg.package} serve -config ${configFile}";
        Restart = "on-failure";
        RestartSec = 10;
        # The t3-thread-* commands come from the Home Manager profile; the
        # model CLIs make the summaries through the shared light role.
        Environment = [
          "PATH=${config.home.profileDirectory}/bin:${lib.makeBinPath [pkgs.claude-code pkgs.codex-cli pkgs.coreutils]}"
          "HOME=${config.home.homeDirectory}"
        ];
      };
      Install.WantedBy = ["default.target"];
    };
  };
}
