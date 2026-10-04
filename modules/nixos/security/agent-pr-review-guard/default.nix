# modules/nixos/security/agent-pr-review-guard/default.nix
#
# Runs the agent PR review guard (ADR-0078) as a managed Codex hook. Codex runs
# hooks from ~/.codex/hooks.json only after they are trusted in /hooks, and
# skips them silently until then; hooks in the system requirements file are
# trusted by policy and cannot be disabled from the user hook browser.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.security.agentPrReviewGuard;
  hooksDir = "/etc/codex/hooks";
  hookCommand = "${hooksDir}/agent-pr-review-guard";
  # Home Manager (programs.ai) builds the guard per user with the user's Forgejo
  # MCP allowlist; this hook runs that guard. Users in cfg.users are blocked
  # when it is missing, so a broken profile cannot silently disable the guard.
  hookScript = ''
    #!${pkgs.runtimeShell}
    user=$(${lib.getExe' pkgs.coreutils "id"} -un)
    for guard in "/etc/profiles/per-user/$user/bin/agent-pr-review-guard" "$HOME/.nix-profile/bin/agent-pr-review-guard"; do
      if [ -x "$guard" ]; then
        exec "$guard"
      fi
    done
    case " ${lib.concatStringsSep " " cfg.users} " in
      *" $user "*)
        echo "Blocked by the agent PR review guard: agent-pr-review-guard is not installed for $user; activate Home Manager with programs.ai enabled." >&2
        exit 2
        ;;
    esac
  '';
  guardHook = matcher: {
    inherit matcher;
    hooks = [
      {
        type = "command";
        command = hookCommand;
        timeout = 120;
      }
    ];
  };
  requirements = (pkgs.formats.toml {}).generate "codex-requirements.toml" {
    # Pinned on, so users cannot turn off the managed hooks.
    features.hooks = true;
    hooks = {
      managed_dir = hooksDir;
      PreToolUse = [
        (guardHook "^Bash$")
        (guardHook "^mcp__forgejo__")
      ];
    };
  };
in {
  options.security.agentPrReviewGuard = {
    enable = lib.mkEnableOption "the agent PR review guard as a managed Codex hook (ADR-0078)";

    users = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z_][a-z0-9_-]*[$]?");
      default = [];
      example = ["operator"];
      description = ''
        Users whose Codex tool calls are blocked when their Home Manager
        profile has no agent-pr-review-guard. Other users without the guard
        are not affected.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc = {
      "codex/requirements.toml".source = requirements;
      # A copy, not a store symlink, so the command stays inside managed_dir.
      "codex/hooks/agent-pr-review-guard" = {
        text = hookScript;
        mode = "0555";
      };
    };
  };
}
