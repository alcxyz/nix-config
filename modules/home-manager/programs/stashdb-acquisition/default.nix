{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.stashdb-acquisition;
in {
  options.programs.stashdb-acquisition = {
    enable = lib.mkEnableOption "StashDB acquisition list tooling";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.stashdb-acquisition-list;
      description = "Package providing the stashdb-acquisition-list command.";
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

    home.sessionVariables = {
      STASHDB_GRAPHQL_ENDPOINT_FILE = config.sops.secrets.stashdb_graphql_endpoint.path;
      STASHDB_GRAPHQL_URL_FILE = config.sops.secrets.stashdb_graphql_endpoint.path;
      STASHDB_API_KEY_FILE = config.sops.secrets.stashdb_api_key.path;
    };
  };
}
