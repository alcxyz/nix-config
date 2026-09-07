{
  config,
  inputs,
  lib,
  pkgs,
  hostRole,
  ...
}:
let
  cfg = config.programs.workspace;
  allRepos = inputs.nix-secrets.repoInventory.workspaceRepos;
  hasSelectedProfile = repo: builtins.any (profile: builtins.elem profile cfg.profiles) repo.profiles;
  selectedRepos = builtins.filter hasSelectedProfile cfg.repos;
  reposJson = builtins.toJSON selectedRepos;
  repoInventoryJson = builtins.toJSON inputs.nix-secrets.repoInventory;
  dirs = [
    "apps"
    "platform"
    "infra"
    "tools"
    "tools/dms-plugins"
    "orgs"
    "orgs/alcorg"
    "orgs/bn-apps"
    "forks"
    "clones"
    "sites"
    "personal"
    "lib"
    "scratch"
  ];

  workspaceManifest = pkgs.writeText "workspace-manifest.json" (builtins.toJSON {
    directories = dirs;
    repositories = selectedRepos;
  });

  workspaceSync = pkgs.writeShellApplication {
    name = "workspace-sync";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.git
      pkgs.jq
    ];
    text = ''
      exec bash ${./workspace-sync.sh} ${lib.escapeShellArg cfg.root} ${workspaceManifest} "$@"
    '';
  };
in
{
  options.programs.workspace = {
    enable = lib.mkEnableOption "declarative source workspace bootstrap";

    root = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/src";
      description = "Root directory for source checkouts.";
    };

    profiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = hostRole.workspaceProfiles;
      description = "Workspace profiles selected for this host.";
    };

    repos = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "Path below the workspace root.";
            };

            url = lib.mkOption {
              type = lib.types.str;
              description = "Git clone URL.";
            };

            branch = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Branch to clone initially.";
            };

            profiles = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Workspace profiles that include this repository.";
            };
          };
        }
      );
      default = allRepos;
      description = "Declarative repository catalog from the private nix-secrets repo inventory.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ workspaceSync ];

    home.activation.workspaceDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "${cfg.root}"
      ${lib.concatMapStringsSep "\n" (dir: "mkdir -p \"${cfg.root}/${dir}\"") dirs}
    '';

    xdg.configFile."workspace/repos.json".text = reposJson;
    xdg.configFile."workspace/repo-inventory.json".text = repoInventoryJson;
    xdg.configFile."workspace/profiles.json".text = builtins.toJSON cfg.profiles;
  };
}
