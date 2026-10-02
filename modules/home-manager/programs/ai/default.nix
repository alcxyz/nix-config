# modules/home-manager/programs/ai/default.nix
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.programs.ai;
  # Agent PR reviews (ADR-0078): `pr-review` runs and records the reviews, and
  # the guard blocks agent merges without a comment for the PR's head. The hook
  # command uses the stable profile path so managed hook entries do not change
  # with each generation. Reviewer clients (codex, claude) come from PATH.
  prReviewConfig = pkgs.writeText "pr-review.json" (builtins.toJSON {
    inherit (cfg.prReview) reviewers timeout;
  });
  prReview = pkgs.writeShellApplication {
    name = "pr-review";
    runtimeInputs = [pkgs.python3 pkgs.gh pkgs.git];
    text = ''PR_REVIEW_CONFIG=${prReviewConfig} exec python3 ${./pr-review.py} "$@"'';
  };
  prReviewGuard = pkgs.writeShellApplication {
    name = "agent-pr-review-guard";
    runtimeInputs = [pkgs.python3 pkgs.gh pkgs.git];
    text = ''exec python3 ${./pr-review.py} guard'';
  };
  prReviewHooks = {
    PreToolUse = [
      {
        matcher = "Bash";
        hooks = [
          {
            type = "command";
            command = "${config.home.profileDirectory}/bin/agent-pr-review-guard";
            timeout = 120;
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
  deepReviewers = optionals (cfg.roles ? deep) [
    {
      name = "gpt";
      client = "codex";
      inherit (cfg.roles.deep.codex) model effort;
    }
    {
      name = "opus";
      client = "claude";
      inherit (cfg.roles.deep.claude) model effort;
    }
  ];
in {
  # The reviewer defaults read the agent roles (ADR-0079).
  imports = [./roles.nix];

  options.programs.ai = {
    enable = mkEnableOption "Module for vibe coding stuff";

    prReview = {
      reviewers = mkOption {
        type = types.listOf (types.submodule {
          options = {
            name = mkOption {
              type = types.strMatching "[A-Za-z0-9_-]+";
              description = "Short name for the reviewer's result files; not prompt, status or lock.";
            };
            client = mkOption {
              type = types.enum ["codex" "claude"];
              description = "CLI that runs the reviewer read-only.";
            };
            model = mkOption {type = types.str;};
            effort = mkOption {
              type = types.str;
              default = "high";
            };
          };
        });
        # ADR-0079: reviewers follow the `deep` agent role when it is defined.
        default =
          if cfg.roles ? deep
          then deepReviewers
          else [
            {
              name = "gpt";
              client = "codex";
              model = "gpt-6.1-sol";
            }
            {
              name = "opus";
              client = "claude";
              model = "claude-opus-5-5";
            }
          ];
        defaultText = literalExpression "the `deep` role's models and efforts from programs.ai.roles (set its efforts explicitly; roles default to medium), or gpt-6.1-sol and claude-opus-5-5 at high effort";
        description = "Read-only reviewers that `pr-review run` starts in parallel (ADR-0078).";
      };
      timeout = mkOption {
        type = types.ints.positive;
        default = 1800;
        description = "Seconds before a reviewer is stopped and recorded as timed out.";
      };
    };
  };

  config = mkIf cfg.enable {
    warnings = optional (cfg.prReview.reviewers == deepReviewers && any (reviewer: !(elem reviewer.effort ["high" "xhigh" "max"])) deepReviewers) "pr-review reviewers follow the `deep` agent role, which runs below high effort (ADR-0078 expects high).";

    assertions = [
      {
        assertion = let
          names = map (reviewer: reviewer.name) cfg.prReview.reviewers;
        in
          names != [] && length names == length (unique names) && !(any (name: elem name ["prompt" "status" "lock"]) names);
        message = "programs.ai.prReview.reviewers needs at least one reviewer, unique names, and no reserved names (prompt, status, lock).";
      }
    ];

    programs.opencode = {
      enable = true;
      tui = {
        theme = "opencode";
      };
    };

    # programs.gemini-cli = {
    #   enable = true;
    # };

    home.packages = [prReview prReviewGuard];

    # Codex merges hooks from every source, so a managed user-level file is
    # enough; repository hooks keep working alongside it.
    home.file.".codex/hooks.json".text = builtins.toJSON {hooks = prReviewHooks;};

    home.activation.claudeStatusline = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run ${mergeClaudeSettings}/bin/merge-claude-settings \
        "${config.home.homeDirectory}/.claude/settings.json" "${claudeManagedSettings}"
    '';
  };
}
