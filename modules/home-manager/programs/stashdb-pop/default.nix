{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.stashdb-pop;
in {
  options.programs.stashdb-pop = {
    enable = lib.mkEnableOption "stashdb-pop tooling";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.stashdb-pop;
      description = "Package providing the stashdb-pop command.";
    };

    dbPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/share/stashdb/acquisition-list.sqlite";
      description = "SQLite database path used by stashdb-pop.";
    };

    listenAddr = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:8765";
      description = "Default listen address for the stashdb-pop web UI.";
    };

    pageSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 100;
      description = "Default StashDB page size for refreshes.";
    };

    sleep = lib.mkOption {
      type = lib.types.str;
      default = "200ms";
      description = "Default delay between StashDB pages.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [cfg.package];

    sops.secrets.stashdb_graphql_endpoint = {
      sopsFile = inputs.nix-secrets.secrets.files.apps;
      key = "stashdb_graphql_endpoint";
    };

    sops.secrets.stashdb_api_key = {
      sopsFile = inputs.nix-secrets.secrets.files.apps;
      key = "stashdb_api_key";
    };

    xdg.configFile."stashdb-pop/config".text = ''
      db_path = ${cfg.dbPath}
      listen_addr = ${cfg.listenAddr}
      page_size = ${toString cfg.pageSize}
      sleep = ${cfg.sleep}
      stashdb_graphql_endpoint_file = ${config.sops.secrets.stashdb_graphql_endpoint.path}
      stashdb_api_key_file = ${config.sops.secrets.stashdb_api_key.path}
    '';

    home.sessionVariables = {
      STASHDB_GRAPHQL_ENDPOINT_FILE = config.sops.secrets.stashdb_graphql_endpoint.path;
      STASHDB_GRAPHQL_URL_FILE = config.sops.secrets.stashdb_graphql_endpoint.path;
      STASHDB_API_KEY_FILE = config.sops.secrets.stashdb_api_key.path;
    };
  };
}
