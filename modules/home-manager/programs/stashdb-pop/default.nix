{
  config,
  inputs,
  lib,
  pkgs,
  username,
  ...
}: let
  cfg = config.programs.stashdb-pop;
  configPath = "${config.programs.workspace.root}/infra/nix-secrets/users/${username}/configs/stashdb-pop/config";
in {
  options.programs.stashdb-pop = {
    enable = lib.mkEnableOption "stashdb-pop tooling";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.stashdb-pop;
      description = "Package providing the stashdb-pop command.";
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

    # Keep this mutable: editing the local nix-secrets checkout updates
    # stashdb-pop without needing a nix-config rebuild.
    xdg.configFile."stashdb-pop/config".source =
      config.lib.file.mkOutOfStoreSymlink configPath;

    home.sessionVariables = {
      STASHDB_GRAPHQL_ENDPOINT_FILE = config.sops.secrets.stashdb_graphql_endpoint.path;
      STASHDB_GRAPHQL_URL_FILE = config.sops.secrets.stashdb_graphql_endpoint.path;
      STASHDB_API_KEY_FILE = config.sops.secrets.stashdb_api_key.path;
    };
  };
}
