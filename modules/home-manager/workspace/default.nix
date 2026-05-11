{
  config,
  lib,
  pkgs,
  hostRole,
  configDir,
  ...
}: let
  cfg = config.programs.workspace;
  allRepos = import ./repos.nix;
  hasSelectedProfile = repo:
    builtins.any (profile: builtins.elem profile cfg.profiles) repo.profiles;
  selectedRepos = builtins.filter hasSelectedProfile cfg.repos;
  reposJson = builtins.toJSON selectedRepos;
  dirs = [
    "apps"
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

  workspaceSync = pkgs.writeShellApplication {
    name = "workspace-sync";
    runtimeInputs = [pkgs.coreutils pkgs.git pkgs.jq];
    text = ''
      set -euo pipefail

      root="${cfg.root}"
      mode="sync"

      case "''${1:-}" in
        --status)
          mode="status"
          ;;
        --help|-h)
          cat <<'USAGE'
      workspace-sync [--status]

      Bootstraps the declared ~/src workspace.

      Default behavior is conservative:
        - create missing parent directories
        - clone missing repositories
        - skip existing git repositories
        - warn and skip existing non-git paths
        - never pull, reset, clean, overwrite, or delete
      USAGE
          exit 0
          ;;
        "")
          ;;
        *)
          printf 'workspace-sync: unknown argument: %s\n' "$1" >&2
          exit 2
          ;;
      esac

      mkdir -p "$root"
      ${lib.concatMapStringsSep "\n" (dir: "mkdir -p \"$root/${dir}\"") dirs}

      repos_json='${reposJson}'

      existing=0
      cloned=0
      missing=0
      skipped=0
      failed=0
      failures=()

      while IFS= read -r repo; do
        path="$(printf '%s\n' "$repo" | jq -r '.path')"
        url="$(printf '%s\n' "$repo" | jq -r '.url')"
        branch="$(printf '%s\n' "$repo" | jq -r '.branch // empty')"
        target="$root/$path"

        if [ -d "$target/.git" ]; then
          printf 'exists: %s\n' "$target"
          existing=$((existing + 1))
          continue
        fi

        if [ -e "$target" ]; then
          printf 'skip: %s exists but is not a git repository\n' "$target" >&2
          skipped=$((skipped + 1))
          continue
        fi

        if [ "$mode" = "status" ]; then
          printf 'missing: %s -> %s\n' "$target" "$url"
          missing=$((missing + 1))
          continue
        fi

        mkdir -p "$(dirname "$target")"
        if [ -n "$branch" ]; then
          if git clone --branch "$branch" "$url" "$target"; then
            cloned=$((cloned + 1))
          else
            printf 'failed: %s -> %s (branch: %s)\n' "$target" "$url" "$branch" >&2
            failures+=("$path -> $url (branch: $branch)")
            failed=$((failed + 1))
          fi
        else
          if git clone "$url" "$target"; then
            cloned=$((cloned + 1))
          else
            printf 'failed: %s -> %s\n' "$target" "$url" >&2
            failures+=("$path -> $url")
            failed=$((failed + 1))
          fi
        fi
      done < <(printf '%s\n' "$repos_json" | jq -c '.[]')

      if [ "$mode" = "status" ]; then
        printf '\nworkspace-sync status: %d existing, %d missing, %d skipped\n' "$existing" "$missing" "$skipped"
      else
        printf '\nworkspace-sync summary: %d existing, %d cloned, %d skipped, %d failed\n' "$existing" "$cloned" "$skipped" "$failed"
        if [ "$failed" -gt 0 ]; then
          printf 'workspace-sync failed repositories:\n' >&2
          printf '  - %s\n' "''${failures[@]}" >&2
        fi
      fi
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
      type = lib.types.listOf (lib.types.submodule {
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
      });
      default = allRepos;
      description = "Declarative repository catalog.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [workspaceSync];

    home.activation.workspaceDirs = lib.hm.dag.entryAfter ["writeBoundary"] ''
      mkdir -p "${cfg.root}"
      ${lib.concatMapStringsSep "\n" (dir: "mkdir -p \"${cfg.root}/${dir}\"") dirs}
    '';

    xdg.configFile."workspace/repos.json".text = reposJson;
    xdg.configFile."workspace/profiles.json".text = builtins.toJSON cfg.profiles;
  };
}
