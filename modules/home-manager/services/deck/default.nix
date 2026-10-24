# modules/home-manager/services/deck/default.nix
#
# deck (nix-packages ADR-0012) serves a live dashboard of T3 Code threads. It
# reads them only through the t3-thread-* commands that programs.ai installs
# (ADR-0091), so it runs as a user service beside the T3 servers whose state
# databases those commands read. Its backlog view (nix-packages ADR-0014)
# runs backlog-inventory (ADR-0093) through the wrapper below, with the
# credentials the consumer names: a read-only Forgejo token and, for GitHub,
# a GitHub App's read-only installation tokens.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.deck;
  bl = cfg.backlog;
  toml = pkgs.formats.toml {};
  inherit (lib) escapeShellArg escapeShellArgs;
  github = bl.github.appId != null;
  # The personal scope only: an empty scope file, so no private group's
  # repositories reach this view. The thread inventory is optional, as in
  # the backlog overview skill.
  backlogInventory = pkgs.writeShellApplication {
    name = "deck-backlog-inventory";
    runtimeInputs = [pkgs.coreutils] ++ lib.optional github bl.github.package;
    text = ''
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      printf '{"groups":{}}\n' >"$tmp/scope.json"
      args=(--related 30 ${escapeShellArgs (lib.concatMap (login: ["--own" login]) bl.own)})
      if t3-thread-inventory --days ${toString bl.threadDays} >"$tmp/threads.json" 2>/dev/null; then
        args+=(--threads "$tmp/threads.json")
      else
        echo "deck-backlog-inventory: no thread inventory; continuing without it" >&2
      fi
      FORGEJO_API_TOKEN_FILE=${escapeShellArg bl.forgejoTokenFile}
      BACKLOG_SCOPE_FILE="$tmp/scope.json"
      export FORGEJO_API_TOKEN_FILE BACKLOG_SCOPE_FILE
      ${
        if github
        then ''
          GH_APP_ID=${escapeShellArg (toString bl.github.appId)}
          GH_APP_KEY_FILE=${escapeShellArg bl.github.keyFile}
          GH_APP_OWNER=${escapeShellArg bl.github.owner}
          export GH_APP_ID GH_APP_KEY_FILE GH_APP_OWNER
          gh-app read-only -- backlog-inventory "''${args[@]}" --github-user ${escapeShellArg bl.github.owner}
        ''
        else ''
          backlog-inventory "''${args[@]}" --no-github
        ''
      }
    '';
  };
  # One issue's text for a verdict, read with the same credentials.
  backlogItem = pkgs.writeShellApplication {
    name = "deck-backlog-item";
    runtimeInputs = lib.optional github bl.github.package;
    text = ''
      FORGEJO_API_TOKEN_FILE=${escapeShellArg bl.forgejoTokenFile}
      export FORGEJO_API_TOKEN_FILE
      ${
        if github
        then ''
          GH_APP_ID=${escapeShellArg (toString bl.github.appId)}
          GH_APP_KEY_FILE=${escapeShellArg bl.github.keyFile}
          GH_APP_OWNER=${escapeShellArg bl.github.owner}
          export GH_APP_ID GH_APP_KEY_FILE GH_APP_OWNER
          exec gh-app read-only -- backlog-inventory item "$@"
        ''
        else ''
          # Without the App, gh would read GitHub as the operator: refuse.
          for arg in "$@"; do
            case $arg in
            gh:*)
              echo "deck-backlog-item: GitHub is off for this view" >&2
              exit 64
              ;;
            esac
          done
          exec backlog-inventory item "$@"
        ''
      }
    '';
  };
  settings = lib.recursiveUpdate cfg.settings (lib.optionalAttrs bl.enable {
    backlog.commands = {
      inventory = lib.getExe backlogInventory;
      item = lib.getExe backlogItem;
    };
  });
  configFile = toml.generate "deck.toml" settings;
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
        service's PATH unless `commands` names them. With `backlog.enable`,
        `backlog.commands` are the wrappers this module builds (the inventory,
        and one issue's text for verdicts); the rest of the `backlog` table
        may be set here.
      '';
    };

    backlog = {
      enable = lib.mkEnableOption "deck's backlog view (nix-packages ADR-0014)";

      forgejoTokenFile = lib.mkOption {
        type = lib.types.str;
        description = ''
          Path of the Forgejo token the inventory reads at run time; it is
          never copied to the store. Give it read:issue, read:repository and
          read:user only: the view never writes.
        '';
      };

      github = {
        appId = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = ''
            GitHub App whose read-only installation tokens (`gh-app read-only`)
            read GitHub; null leaves GitHub out of the view.
          '';
        };
        keyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Path of the App's private key, read at run time.";
        };
        owner = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Account the App is installed on. The inventory also reads GitHub
            as this user, since an installation token cannot say who it is.
          '';
        };
        package = lib.mkPackageOption pkgs "gh-app" {};
      };

      own = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["app/example-app" "example-app[bot]"];
        description = ''
          Authors counted as the user's own (backlog-inventory `--own`), such
          as the App acting for the user: gh names it app/NAME, the REST API
          NAME[bot].
        '';
      };

      threadDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Days of T3 threads joined to the inventory, to find the thread holding each item.";
      };
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
      {
        assertion = bl.enable -> (bl.github.keyFile != null) == github && (bl.github.owner != null) == github;
        message = "services.deck.backlog.github: set appId, keyFile and owner together, or none of them.";
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
        # The t3-thread-* commands and backlog-inventory come from the Home
        # Manager profile; the model CLIs make the summaries through the
        # shared roles (light by default, standard or deep when picked for
        # one refresh).
        Environment = [
          "PATH=${config.home.profileDirectory}/bin:${lib.makeBinPath [pkgs.claude-code pkgs.codex-cli pkgs.coreutils]}"
          "HOME=${config.home.homeDirectory}"
        ];
      };
      Install.WantedBy = ["default.target"];
    };
  };
}
