{lib}: let
  evaluate = policy: let
    evaluated = lib.evalModules {
      specialArgs = {
        inputs = {};
        pkgs = {
          git = "/git";
          coreutils = "/coreutils";
          forge-mirror = "/forge-mirror";
          writeShellScript = _: text: text;
          writeText = _: text:
            assert text == lib.concatStringsSep "\n" (policy.githubPrimaryRepositories or []) + "\n"; "/repository-policy";
        };
      };
      modules = [
        ../../modules/nixos/services/forge-mirror-audit
        {
          options = {
            assertions = lib.mkOption {type = lib.types.listOf lib.types.attrs;};
            sops = lib.mkOption {type = lib.types.attrsOf (lib.types.attrsOf (lib.types.attrsOf lib.types.anything));};
            systemd = lib.mkOption {type = lib.types.attrs;};
          };
          config = {
            services.forge-mirror-audit = {enable = true;} // policy;
            sops.secrets = {
              forge_mirror_forgejo_token.path = "/credentials/forgejo";
              forge_mirror_github_token.path = "/credentials/github";
              forge_mirror_codeberg_token.path = "/credentials/codeberg";
            };
          };
        }
      ];
    };
  in
    evaluated.config.systemd.services.forge-mirror-audit.serviceConfig.ExecStart;
  populated = evaluate {githubPrimaryRepositories = ["public-app" "upstream-fork"];};
  empty = evaluate {githubPrimaryRepositories = [];};
  hasPolicy = lib.hasInfix "export FORGE_MIRROR_GITHUB_PRIMARY_REPOS_FILE=/repository-policy";
in
  assert hasPolicy populated;
  assert hasPolicy empty;
  assert lib.hasInfix "exec /forge-mirror/bin/forge-mirror audit" populated;
  assert !(builtins.tryEval (evaluate {})).success; true
