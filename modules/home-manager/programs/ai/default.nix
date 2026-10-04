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
    text = ''AGENT_FORGEJO_MCP_TOOLS=${forgejoMcpTools} exec python3 ${./pr-review.py} guard'';
  };
  guardHook = matcher: {
    inherit matcher;
    hooks = [
      {
        type = "command";
        command = "${config.home.profileDirectory}/bin/agent-pr-review-guard";
        timeout = 120;
      }
    ];
  };
  # The guard also holds Forgejo MCP calls to the allowlist (ADR-0081). Codex
  # already hides other tools through enabled_tools; Claude Code has no
  # per-server tool filter, and hooks still run when permissions are bypassed.
  prReviewHooks = {
    PreToolUse = [(guardHook "Bash")] ++ optional mcp.enable (guardHook "mcp__forgejo__.*");
  };

  # Forgejo MCP client for agents (ADR-0081). The wrapper reads the token file
  # at start, so the token never appears in arguments or client configuration.
  mcp = cfg.forgejoMcp;
  forgejoMcpTools = pkgs.writeText "forgejo-mcp-tools.json" (builtins.toJSON (
    optionals mcp.enable (mcp.readTools ++ mcp.writeTools)
  ));
  forgejoMcpAgent = pkgs.writeShellApplication {
    name = "forgejo-mcp-agent";
    runtimeInputs = [pkgs.forgejo-mcp];
    text = ''
      token_file=${escapeShellArg (toString mcp.tokenFile)}
      if [ ! -r "$token_file" ]; then
        echo "forgejo-mcp-agent: cannot read the Forgejo token file $token_file" >&2
        exit 1
      fi
      FORGEJO_ACCESS_TOKEN=$(<"$token_file")
      export FORGEJO_ACCESS_TOKEN
      exec forgejo-mcp -t stdio -url ${escapeShellArg mcp.url}
    '';
  };
  # Not on PATH: the wrapper serves every forgejo-mcp tool, so a shell could
  # reach merges the clients' allowlist hides.
  forgejoMcpCommand = "${forgejoMcpAgent}/bin/forgejo-mcp-agent";
  codexMcpServers = pkgs.writeText "codex-mcp-servers.json" (builtins.toJSON (optionalAttrs mcp.enable {
    forgejo = {
      command = forgejoMcpCommand;
      enabled_tools = mcp.readTools ++ mcp.writeTools;
      default_tools_approval_mode = "prompt";
      tools = genAttrs mcp.readTools (_: {approval_mode = "approve";});
    };
  }));
  claudeMcpServers = pkgs.writeText "claude-mcp-servers.json" (builtins.toJSON (optionalAttrs mcp.enable {
    forgejo = {
      type = "stdio";
      command = forgejoMcpCommand;
      args = [];
      env = {};
    };
  }));
  mergeCodexTables = pkgs.writeShellApplication {
    name = "merge-codex-tables";
    runtimeInputs = [(pkgs.python3.withPackages (ps: [ps.tomlkit]))];
    text = ''exec python3 ${./codex-roles.py} "$@"'';
  };
  mergeClaudeMcp = pkgs.writeShellApplication {
    name = "merge-claude-mcp";
    runtimeInputs = [pkgs.python3];
    text = ''exec python3 ${./claude-mcp.py} "$@"'';
  };
  claudeManagedSettings = pkgs.writeText "claude-managed-settings.json" (
    builtins.toJSON {
      hooks = prReviewHooks;
      # Reads run without a prompt; writes keep the client's approval.
      permissions.allow = map (tool: "mcp__forgejo__${tool}") (optionals mcp.enable mcp.readTools);
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

    forgejoMcp = {
      enable = mkEnableOption "the Forgejo MCP server for Claude Code and Codex (ADR-0081)";
      url = mkOption {
        type = types.str;
        default = "https://git.alc.xyz";
        description = "Forgejo instance the server talks to.";
      };
      tokenFile = mkOption {
        type = types.nullOr types.str;
        default = config.home.sessionVariables.FORGEJO_API_TOKEN_FILE or null;
        defaultText = literalExpression "config.home.sessionVariables.FORGEJO_API_TOKEN_FILE or null";
        description = "File holding the Forgejo API token, read when the server starts. Provisioned privately.";
      };
      readTools = mkOption {
        type = types.listOf types.str;
        default = [
          "get_issue_by_index"
          "get_issue_comment"
          "list_issue_comments"
          "list_repo_issues"
          "search_issues"
          "list_issue_dependencies"
          "list_issue_dependents"
          "get_pull_request_by_index"
          "get_pull_request_diff"
          "list_pull_request_files"
          "list_repo_pull_requests"
          "list_pull_reviews"
          "get_pull_review"
          "list_pull_review_comments"
          "get_repo"
          "search_repos"
          "list_my_repos"
          "get_my_user_info"
          "list_branches"
          "list_repo_commits"
          "get_file_content"
          "list_repo_contents"
          "get_repo_tree"
          "list_repo_labels"
          "list_repo_milestones"
          "list_releases"
          "get_latest_release"
          "get_release_by_tag"
          "list_workflow_runs"
          "get_workflow_run"
          "list_action_run_jobs"
          "get_action_job_logs"
        ];
        description = "Read-only tools agents may call without a prompt.";
      };
      writeTools = mkOption {
        type = types.listOf types.str;
        default = [
          "create_issue"
          "update_issue"
          "issue_state_change"
          "create_issue_comment"
          "edit_issue_comment"
          "add_issue_labels"
          "remove_issue_labels"
          "add_issue_dependency"
          "remove_issue_dependency"
          "create_pull_request"
          "update_pull_request"
        ];
        description = "Tools that change issues or PRs; they keep the client's approval. Never add merge_pull_request: merges go through the review guard (ADR-0078).";
      };
    };
  };

  config = mkIf cfg.enable {
    warnings = optional (cfg.prReview.reviewers == deepReviewers && any (reviewer: !(elem reviewer.effort ["high" "xhigh" "max"])) deepReviewers) "pr-review reviewers follow the `deep` agent role, which runs below high effort (ADR-0078 expects high).";

    assertions = [
      {
        assertion = !mcp.enable || (mcp.tokenFile != null && !(elem "merge_pull_request" (mcp.readTools ++ mcp.writeTools)));
        message = "programs.ai.forgejoMcp needs a tokenFile and must not enable merge_pull_request (ADR-0081).";
      }
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

    # Codex runs user hooks only after they are trusted in /hooks. NixOS hosts
    # enforce the guard through security.agentPrReviewGuard instead; this file
    # serves other hosts once trusted.
    home.file.".codex/hooks.json".text = builtins.toJSON {hooks = prReviewHooks;};

    home.activation.claudeStatusline = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run ${mergeClaudeSettings}/bin/merge-claude-settings \
        "${config.home.homeDirectory}/.claude/settings.json" "${claudeManagedSettings}"
    '';

    # Also runs when forgejoMcp is disabled, so earlier registrations are
    # removed; disabling programs.ai as a whole leaves them, like the hooks.
    home.activation.agentMcpServers = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run ${mergeCodexTables}/bin/merge-codex-tables \
        "${config.home.homeDirectory}/.codex/config.toml" \
        "${config.xdg.stateHome}/agent-mcp/codex-managed.json" ${codexMcpServers} mcp_servers \
        || warnEcho "Codex MCP servers were not updated; see the message above."
      run ${mergeClaudeMcp}/bin/merge-claude-mcp \
        "${config.home.homeDirectory}/.claude.json" \
        "${config.xdg.stateHome}/agent-mcp/claude-managed.json" ${claudeMcpServers} \
        || warnEcho "Claude Code MCP servers were not updated; see the message above."
    '';
  };
}
