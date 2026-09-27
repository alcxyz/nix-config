{
  config,
  inputs,
  lib,
  pkgs,
  hostRole,
  ...
}: let
  cfg = config.programs.workspace;
  allRepos = inputs.nix-secrets.repoInventory.workspaceRepos;
  privateDirectories = inputs.nix-secrets.repoInventory.workspaceDirectories or [];
  privateLinks = inputs.nix-secrets.repoInventory.workspaceLinks or [];
  hasSelectedProfile = item: builtins.any (profile: builtins.elem profile cfg.profiles) item.profiles;
  selectedRepos = builtins.filter hasSelectedProfile cfg.repos;
  selectedLinks = builtins.filter hasSelectedProfile cfg.links;
  reposJson = builtins.toJSON selectedRepos;
  repoInventoryJson = builtins.toJSON inputs.nix-secrets.repoInventory;
  baseDirectories = [
    "apps"
    "platform"
    "infra"
    "tools"
    "tools/dms-plugins"
    "forks"
    "clones"
    "sites"
    "personal"
    "lib"
    "scratch"
  ];

  workspaceManifest = pkgs.writeText "workspace-manifest.json" (
    builtins.toJSON {
      directories = cfg.directories;
      repositories = selectedRepos;
      links = selectedLinks;
    }
  );

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
in {
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

    directories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.unique (baseDirectories ++ privateDirectories);
      description = "Workspace-relative directories, including private layout supplied by the inventory.";
    };

    links = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "Workspace-relative path for the link.";
            };
            target = lib.mkOption {
              type = lib.types.str;
              description = "Canonical workspace-relative target path.";
            };
            profiles = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Workspace profiles that include this link.";
            };
          };
        }
      );
      default = privateLinks;
      description = "Workspace links supplied by the private inventory.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [workspaceSync];

    home.activation.workspaceDirs = lib.hm.dag.entryAfter ["writeBoundary"] ''
      ${workspaceSync}/bin/workspace-sync --directories
    '';

    xdg.configFile."workspace/repos.json".text = reposJson;
    xdg.configFile."workspace/repo-inventory.json".text = repoInventoryJson;
    xdg.configFile."workspace/profiles.json".text = builtins.toJSON cfg.profiles;
  };
}
