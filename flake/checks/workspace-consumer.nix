{
  inputs,
  pkgs,
}: let
  lib = pkgs.lib;
  # Resolve these relative fixture paths inside the build's temporary directory.
  root = "workspace root 'quoted' $literal";
  inventory = {
    workspaceDirectories = ["canonical" "aliases" "scratch"];
    workspaceRepos = [
      {
        path = "apps/selected";
        url = "source repository";
        branch = "fixture-branch";
        profiles = ["selected" "other"];
      }
      {
        path = "apps/excluded";
        url = "must-not-clone";
        profiles = ["other"];
      }
    ];
    workspaceLinks = [
      {
        path = "aliases/selected";
        target = "canonical";
        profiles = ["selected"];
      }
      {
        path = "aliases/excluded";
        target = "canonical";
        profiles = ["other"];
      }
    ];
  };
  evaluate = extra:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        inputs.nix-secrets.repoInventory = inventory;
        hostRole.workspaceProfiles = ["selected"];
      };
      modules = [
        ../../modules/home-manager/workspace/default.nix
        {
          home.username = "fixture";
          home.homeDirectory = "/home/fixture";
          home.stateVersion = "26.05";
          programs.workspace = {
            enable = true;
            inherit root;
          };
        }
        extra
      ];
    };
  home = evaluate {};
  otherProfile = evaluate {programs.workspace.profiles = ["other"];};
  noProfiles = evaluate {programs.workspace.profiles = [];};
  disabled = evaluate {programs.workspace.enable = lib.mkForce false;};
  wrapper = lib.findFirst (p: p.name == "workspace-sync") null home.config.home.packages;
  activation = home.config.home.activation.workspaceDirs;
  selectedRepos = builtins.fromJSON home.config.xdg.configFile."workspace/repos.json".text;
  selectedProfiles = builtins.fromJSON home.config.xdg.configFile."workspace/profiles.json".text;
  cases = pkgs.writeText "workspace-consumer-cases.json" (builtins.toJSON {
    inherit root;
    wrapper = "${wrapper}/bin/workspace-sync";
    activation = pkgs.writeText "workspace-directory-activation.sh" activation.data;
    git = "${pkgs.git}/bin/git";
    executable = lib.getExe pkgs.workspace-sync;
    expectedDirectories = home.config.programs.workspace.directories;
    expectedRepositories = selectedRepos;
    expectedLinks = [(lib.head inventory.workspaceLinks)];
  });
in
  assert wrapper != null;
  assert selectedProfiles == ["selected"];
  assert map (r: r.path) selectedRepos == ["apps/selected"];
  assert (lib.head selectedRepos).branch == "fixture-branch";
  assert map (r: r.path) (builtins.fromJSON otherProfile.config.xdg.configFile."workspace/repos.json".text)
  == ["apps/selected" "apps/excluded"];
  assert (builtins.elemAt (builtins.fromJSON otherProfile.config.xdg.configFile."workspace/repos.json".text) 1).branch == null;
  assert builtins.fromJSON noProfiles.config.xdg.configFile."workspace/repos.json".text == [];
  assert home.config.programs.workspace.directories
  == lib.unique ([
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
    ]
    ++ inventory.workspaceDirectories);
  assert activation.after == ["writeBoundary"];
  assert !(disabled.config.home.activation ? workspaceDirs);
  assert !(lib.any (p: p.name == "workspace-sync") disabled.config.home.packages);
    pkgs.runCommand "workspace-consumer-contract" {
      nativeBuildInputs = [pkgs.python3 pkgs.bash pkgs.coreutils];
    } ''
      python3 ${./test-workspace-consumer.py} ${cases}
      touch "$out"
    ''
