# modules/home-manager/programs/ai/default.nix
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.programs.ai;
  # Agent PR review guard (ADR-0078). The hook command uses the stable profile
  # path so managed hook entries do not change with each generation.
  prReviewGuard = pkgs.writeShellApplication {
    name = "agent-pr-review-guard";
    runtimeInputs = [pkgs.python3 pkgs.gh];
    text = ''exec python3 ${./pr-review-guard.py} "$@"'';
  };
  prReviewHooks = {
    PreToolUse = [
      {
        matcher = "Bash";
        hooks = [
          {
            type = "command";
            command = "${config.home.profileDirectory}/bin/agent-pr-review-guard";
            timeout = 60;
          }
        ];
      }
    ];
  };
  claudeManagedSettings = pkgs.writeText "claude-managed-settings.json" (
    builtins.toJSON {
      hooks = prReviewHooks;
      statusLine = {
        type = "command";
        command = "dankaiusage claude-statusline";
        padding = 0;
      };
    }
  );
  mergeClaudeSettings = pkgs.writeShellApplication {
    name = "merge-claude-settings";
    runtimeInputs = [pkgs.coreutils pkgs.jq];
    text = builtins.readFile ./merge-settings.sh;
  };
in {
  options.programs.ai = {
    enable = mkEnableOption "Module for vibe coding stuff";
  };

  config = mkIf cfg.enable {
    programs.opencode = {
      enable = true;
      tui = {
        theme = "opencode";
      };
    };

    # programs.gemini-cli = {
    #   enable = true;
    # };

    home.packages = [prReviewGuard];

    # Codex merges hooks from every source, so a managed user-level file is
    # enough; repository hooks keep working alongside it.
    home.file.".codex/hooks.json".text = builtins.toJSON {hooks = prReviewHooks;};

    home.activation.claudeStatusline = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run ${mergeClaudeSettings}/bin/merge-claude-settings \
        "${config.home.homeDirectory}/.claude/settings.json" "${claudeManagedSettings}"
    '';
  };
}
