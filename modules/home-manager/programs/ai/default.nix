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
    light_reviewers = cfg.prReview.lightReviewers;
    agent_identities = cfg.prReview.agentIdentities;
    fast_forward_repositories = cfg.prReview.fastForwardRepositories;
  });
  prReview = pkgs.writeShellApplication {
    name = "pr-review";
    runtimeInputs = [pkgs.python3 pkgs.gh pkgs.git];
    text = ''PR_REVIEW_CONFIG=${prReviewConfig} exec python3 ${./pr-review.py} "$@"'';
  };
  # Pushes to listed GitHub repositories are checked by a pre-push hook in the
  # user's Git configuration (ADR-0078), so it runs beside each repository's
  # own hooks and covers pushes from scripts, aliases and runners. It checks
  # only agent processes, which Claude Code marks with CLAUDECODE and T3's
  # agent sessions (services.t3code runs sessionCommands) and agent-job with
  # PR_REVIEW_AGENT_SESSION; it returns at once for other URLs.
  githubFastForward = any (name: hasPrefix "github.com/" (toLower name)) cfg.prReview.fastForwardRepositories;
  prReviewGuard = pkgs.writeShellApplication {
    name = "agent-pr-review-guard";
    runtimeInputs = [pkgs.python3 pkgs.gh pkgs.git];
    text = ''PR_REVIEW_CONFIG=${prReviewConfig} AGENT_FORGEJO_MCP_URL=${escapeShellArg mcp.url} AGENT_MCP_STATE_DIR=${escapeShellArg "${config.xdg.stateHome}/agent-mcp"} exec python3 ${./pr-review.py} guard'';
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
  # The guard also checks Forgejo MCP merges (ADR-0081); other MCP tools pass.
  prReviewHooks = {
    PreToolUse = [(guardHook "Bash")] ++ optional mcp.enable (guardHook "mcp__forgejo__.*");
  };

  # Forgejo MCP client for agents (ADR-0081). The wrapper reads the token file
  # at start, so the token never appears in arguments or client configuration.
  # The session's FORGEJO_API_TOKEN_FILE chooses the file, so the server acts
  # as whoever the session acts as: the agent forge account in T3 sessions,
  # the operator in a terminal (#722). tokenFile serves sessions without it.
  # A named file that yields no token fails rather than fall back.
  mcp = cfg.forgejoMcp;
  forgejoMcpAgent = pkgs.writeShellApplication {
    name = "forgejo-mcp-agent";
    runtimeInputs = [pkgs.forgejo-mcp];
    text = ''
      token_file=''${FORGEJO_API_TOKEN_FILE:-${escapeShellArg (toString mcp.tokenFile)}}
      if [ ! -f "$token_file" ] || [ ! -r "$token_file" ]; then
        echo "forgejo-mcp-agent: cannot read the Forgejo token file $token_file" >&2
        exit 1
      fi
      FORGEJO_ACCESS_TOKEN=$(<"$token_file")
      if [ -z "''${FORGEJO_ACCESS_TOKEN//[[:space:]]/}" ]; then
        echo "forgejo-mcp-agent: no token in $token_file" >&2
        exit 1
      fi
      export FORGEJO_ACCESS_TOKEN
      exec forgejo-mcp -t stdio -url ${escapeShellArg mcp.url}
    '';
  };
  # Not on PATH: the guard sees MCP merges only as client tool calls, not when
  # a shell drives the wrapper directly.
  forgejoMcpCommand = "${forgejoMcpAgent}/bin/forgejo-mcp-agent";
  # Codex passes MCP servers only a fixed set of variables unless named here;
  # Claude Code passes its whole environment.
  codexMcpServers = pkgs.writeText "codex-mcp-servers.json" (builtins.toJSON (optionalAttrs mcp.enable {
    forgejo = {
      command = forgejoMcpCommand;
      env_vars = ["FORGEJO_API_TOKEN_FILE"];
    };
  }));
  # A locked or restarted keyring blocks Codex session start indefinitely, so
  # MCP OAuth tokens live in a private file beside auth.json (ADR-0084).
  codexSettings = pkgs.writeText "codex-settings.json" (builtins.toJSON {
    mcp_oauth_credentials_store = "file";
  });
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
  # A managed T3 Code restart kills the Claude Code process behind a thread.
  # On resume the notice hook names the unit and time, for sessions running
  # inside a T3 unit's cgroup only. The hook is always installed: a removed
  # managed hook entry would otherwise keep pointing at a missing command.
  t3Units =
    ["t3code.service"]
    ++ map (name: "t3code-${name}.service") (attrNames (config.services.t3code.instances or {}));
  t3RestartLog = config.services.t3code.restartLog or "${config.xdg.stateHome}/t3code/managed-restarts.log";
  t3RestartNotice = pkgs.writeShellApplication {
    name = "t3code-restart-notice";
    runtimeInputs = [pkgs.python3];
    text = ''
      exec python3 -I ${../../services/t3code/restart-notice.py} \
        "''${T3CODE_RESTART_LOG:-${t3RestartLog}}" \
        "''${T3CODE_NOTICE_STATE:-${config.xdg.stateHome}/t3code/notified}" \
        "''${T3CODE_CGROUP_FILE:-/proc/self/cgroup}" ${escapeShellArgs t3Units}
    '';
  };
  t3RestartNoticeHooks = {
    SessionStart = [
      {
        matcher = "startup|resume|compact";
        hooks = [
          {
            type = "command";
            command = "${config.home.profileDirectory}/bin/t3code-restart-notice";
            timeout = 30;
          }
        ];
      }
    ];
  };
  # The T3 thread overview and status skills (ADR-0091) read thread state
  # through t3-thread-inventory and t3-thread-status, which try every T3
  # instance's state database and keep the one holding the thread asked about.
  t3StateDbs = map (dir: "${dir}/userdata/statev2.sqlite") (
    [(config.services.t3code.baseDir or "${config.home.homeDirectory}/.t3")]
    ++ map (instance: instance.baseDir) (attrValues (config.services.t3code.instances or {}))
  );
  t3ThreadInventory = pkgs.writeShellApplication {
    name = "t3-thread-inventory";
    runtimeInputs = [pkgs.sqlite pkgs.jq];
    text = ''
      common_sql=${./t3-thread-common.sql}
      inventory_sql=${./t3-thread-inventory.sql}
      default_dbs=${escapeShellArg (concatStringsSep ":" t3StateDbs)}
      ack_file_default=${escapeShellArg t3OverviewAckFile}
      ${builtins.readFile ./t3-thread-id.sh}
      ${builtins.readFile ./t3-state-db.sh}
      ${builtins.readFile ./t3-thread-inventory.sh}
    '';
  };
  t3ThreadStatus = pkgs.writeShellApplication {
    name = "t3-thread-status";
    runtimeInputs = [pkgs.sqlite pkgs.jq pkgs.git];
    text = ''
      common_sql=${./t3-thread-common.sql}
      status_sql=${./t3-thread-status.sql}
      default_dbs=${escapeShellArg (concatStringsSep ":" t3StateDbs)}
      ${builtins.readFile ./t3-thread-id.sh}
      ${builtins.readFile ./t3-state-db.sh}
      ${builtins.readFile ./t3-thread-status.sh}
    '';
  };
  t3ThreadOverviewRender = pkgs.writeShellApplication {
    name = "t3-thread-overview-render";
    runtimeInputs = [pkgs.jq];
    text = ''
      overview_template=${./t3-thread-overview.html}
      ${builtins.readFile ./t3-page.sh}
      ${builtins.readFile ./t3-thread-overview-render.sh}
    '';
  };
  # Settled threads the user accepted as done in the overview (ADR-0091).
  t3OverviewAckFile = "${config.xdg.stateHome}/t3-thread-overview/acknowledged.json";
  t3ThreadOverviewAck = pkgs.writeShellApplication {
    name = "t3-thread-overview-ack";
    runtimeInputs = [pkgs.jq pkgs.flock];
    text = ''
      ack_file_default=${escapeShellArg t3OverviewAckFile}
      ${builtins.readFile ./t3-thread-id.sh}
      ${builtins.readFile ./t3-thread-overview-ack.sh}
    '';
  };
  t3ThreadStatusRender = pkgs.writeShellApplication {
    name = "t3-thread-status-render";
    runtimeInputs = [pkgs.jq];
    text = ''
      status_card=${./t3-thread-status-card.html}
      ${builtins.readFile ./t3-page.sh}
      ${builtins.readFile ./t3-thread-status-render.sh}
    '';
  };
  # The thread time skill (ADR-0091, #676) breaks a thread's time down by kind
  # of work from the same state databases.
  t3ThreadTime = pkgs.writeShellApplication {
    name = "t3-thread-time";
    runtimeInputs = [pkgs.python3];
    text = ''
      T3_STATE_DBS=''${T3_STATE_DBS:-${escapeShellArg (concatStringsSep ":" t3StateDbs)}}
      export T3_STATE_DBS
      exec python3 -I ${./t3-thread-time.py} "$@"
    '';
  };
  t3ThreadTimeRender = pkgs.writeShellApplication {
    name = "t3-thread-time-render";
    runtimeInputs = [pkgs.jq];
    text = ''
      time_template=${./t3-thread-time.html}
      ${builtins.readFile ./t3-page.sh}
      ${builtins.readFile ./t3-thread-time-render.sh}
    '';
  };
  # The backlog overview skill (ADR-0093) lists open issues and PRs across
  # Forgejo and the user's GitHub repositories. The Forgejo token is read from
  # its file inside the process; gh keeps its own credentials. Scope groups
  # come from a privately supplied file; this flake ships none.
  backlogInventory = pkgs.writeShellApplication {
    name = "backlog-inventory";
    runtimeInputs = [pkgs.python3 pkgs.gh];
    text = ''
      ${optionalString (mcp.tokenFile != null) ''
        FORGEJO_API_TOKEN_FILE=''${FORGEJO_API_TOKEN_FILE:-${escapeShellArg (toString mcp.tokenFile)}}
        export FORGEJO_API_TOKEN_FILE
      ''}
      ${optionalString (cfg.backlog.scopeFile != null) ''
        BACKLOG_SCOPE_FILE=''${BACKLOG_SCOPE_FILE:-${escapeShellArg "${cfg.backlog.scopeFile}"}}
        export BACKLOG_SCOPE_FILE
      ''}
      BACKLOG_FORGEJO_URL=${escapeShellArg mcp.url} exec python3 -I ${./backlog-inventory.py} "$@"
    '';
  };
  backlogOverviewRender = pkgs.writeShellApplication {
    name = "backlog-overview-render";
    runtimeInputs = [pkgs.jq];
    text = ''
      backlog_template=${./backlog-overview.html}
      ${builtins.readFile ./t3-page.sh}
      ${builtins.readFile ./backlog-overview-render.sh}
    '';
  };
  # The worktree audit (ADR-0093, amended for #701) lists every linked Git
  # worktree under ~/src with cleanup facts. It reads the Forgejo token the
  # same way as backlog-inventory; gh keeps its own credentials. Read-only:
  # removal stays with the skill and `git worktree remove`.
  worktreeAudit = pkgs.writeShellApplication {
    name = "worktree-audit";
    runtimeInputs = [pkgs.python3 pkgs.gh pkgs.git];
    text = ''
      ${optionalString (mcp.tokenFile != null) ''
        FORGEJO_API_TOKEN_FILE=''${FORGEJO_API_TOKEN_FILE:-${escapeShellArg (toString mcp.tokenFile)}}
        export FORGEJO_API_TOKEN_FILE
      ''}
      WORKTREE_AUDIT_FORGEJO_URL=${escapeShellArg mcp.url} exec python3 -I ${./worktree-audit.py} "$@"
    '';
  };
  # Runs work that must outlive an agent session as a transient systemd user
  # unit (nix-config #612). No runtimeInputs: the job inherits the caller's
  # PATH unchanged, and systemd-run must match the running user manager.
  agentJob = pkgs.writeShellApplication {
    name = "agent-job";
    text = ''
      record_path=${pkgs.coreutils}/bin
      ${builtins.readFile ./agent-job.sh}
    '';
  };
  claudeManagedSettings = pkgs.writeText "claude-managed-settings.json" (
    builtins.toJSON {
      hooks = prReviewHooks // t3RestartNoticeHooks;
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
  reviewerType = types.submodule {
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
  };
  lightReviewers = optionals (cfg.roles ? light) [
    {
      name = "gpt-light";
      client = "codex";
      inherit (cfg.roles.light.codex) model effort;
    }
    {
      name = "claude-light";
      client = "claude";
      inherit (cfg.roles.light.claude) model effort;
    }
  ];
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
  # The reviewer defaults read the agent roles (ADR-0079); repo-review.nix
  # installs revkit for whole-repository reviews (nix-packages ADR-0011);
  # agent-forge.nix declares the agent sessions' forge account (ADR-0081).
  imports = [./roles.nix ./repo-review.nix ./agent-forge.nix ./agent-github.nix];

  options.programs.ai = {
    enable = mkEnableOption "Module for vibe coding stuff";

    prReview = {
      reviewers = mkOption {
        type = types.listOf reviewerType;
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
      lightReviewers = mkOption {
        type = types.listOf reviewerType;
        # Small documentation-only changes get these instead (ADR-0078).
        default = lightReviewers;
        defaultText = literalExpression "the `light` role's models and efforts from programs.ai.roles, or none";
        description = "Reviewers for small documentation-only PRs; when empty, every PR gets `reviewers`.";
      };
      timeout = mkOption {
        type = types.ints.positive;
        default = 1800;
        description = "Seconds before a reviewer is stopped and recorded as timed out.";
      };
      agentIdentities = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["agent@example.invalid"];
        description = ''
          Commit author and committer emails of agent forge accounts (ADR-0078).
          `pr-review run` carries no review to a head with such a commit, and the
          guard refuses merges of them into `fastForwardRepositories`.
        '';
      };
      selftest = {
        enable = mkEnableOption ''
          an hourly `pr-review selftest` that runs every reviewer with the real
          clients on a built-in change and sends a desktop notification when one
          fails (Linux only). It reruns only after a client, reviewer or
          `pr-review` change, or once `staleHours` have passed
        '';
        staleHours = mkOption {
          type = types.ints.positive;
          default = 24;
          description = "Hours a self-test result stays current when the clients and reviewers are unchanged.";
        };
      };
      fastForwardRepositories = mkOption {
        type = types.listOf (types.strMatching "[^/[:space:]]+/[^/[:space:]]+/[^/[:space:]]+");
        default = [];
        example = ["git.example.org/owner/repo" "github.com/owner/repo"];
        description = ''
          Repositories, as `host/owner/repo`, whose agent merges the guard also
          requires to be fast-forward, without leftover `fixup!`, `squash!` or
          `amend!` commits and without commits by `agentIdentities` (ADR-0078).
          Forgejo merges must use the style fast-forward-only. For GitHub
          repositories (`github.com/owner/repo`) agents merge by pushing the
          reviewed PR head to its base branch: the guard refuses GitHub-side
          merges, API ref updates and changes to the agent pre-push hook,
          which the user's Git configuration registers and which checks each
          push from an agent process to a protected branch as the merge.
          Other repositories are not affected.
        '';
      };
      sessionCommands = mkOption {
        type = types.lines;
        internal = true;
        readOnly = true;
        default = optionalString (cfg.enable && githubFastForward) "export PR_REVIEW_AGENT_SESSION=1\n";
        description = ''
          Bash commands that mark an agent session for the agent pre-push
          hook; empty unless a GitHub repository is in
          `fastForwardRepositories`.
        '';
      };
    };

    backlog.scopeFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression ''
        pkgs.writeText "backlog-scopes.json" (builtins.toJSON {
          groups.example.repos = ["gh:example-org/service" "example-org/forge-side"];
        })'';
      description = "JSON file with the groups `backlog-inventory --scope` accepts (ADR-0093); null for none.";
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
        description = "File holding the Forgejo API token, read when the server starts if the session sets no FORGEJO_API_TOKEN_FILE. Provisioned privately.";
      };
    };
  };

  config = mkIf cfg.enable {
    warnings = optional (cfg.prReview.reviewers == deepReviewers && any (reviewer: !(elem reviewer.effort ["high" "xhigh" "max"])) deepReviewers) "pr-review reviewers follow the `deep` agent role, which runs below high effort (ADR-0078 expects high).";

    assertions = [
      {
        assertion = !mcp.enable || mcp.tokenFile != null;
        message = "programs.ai.forgejoMcp needs a tokenFile (ADR-0081).";
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

    programs.git.settings = mkIf githubFastForward {
      hook.agent-pr-review = {
        command = "${prReview}/bin/pr-review pre-push";
        event = "pre-push";
      };
    };

    home.packages = [agentJob backlogInventory backlogOverviewRender prReview prReviewGuard t3RestartNotice t3ThreadInventory t3ThreadOverviewAck t3ThreadOverviewRender t3ThreadStatus t3ThreadStatusRender t3ThreadTime t3ThreadTimeRender worktreeAudit];

    # The agent skills that call these commands live in nix-secrets
    # shared/skills and are linked by its agentSkills module (nix-secrets
    # ADR-0016, amended 2026-10-11).

    # Codex runs user hooks only after they are trusted in /hooks. NixOS hosts
    # enforce the guard through security.agentPrReviewGuard instead; this file
    # serves other hosts once trusted.
    home.file.".codex/hooks.json".text = builtins.toJSON {hooks = prReviewHooks;};

    # Catches a client update or an expired sign-in that would fail every
    # review before an agent needs one (#718). Reviewers use the same clients
    # as agent sessions: the AI stack profile when present (ADR-0077), else
    # the Home Manager profile.
    systemd.user.services = mkIf (cfg.prReview.selftest.enable && pkgs.stdenv.hostPlatform.isLinux) {
      pr-review-selftest = {
        Unit = {
          Description = "Test pr-review's reviewer clients (ADR-0078)";
          OnFailure = "pr-review-selftest-failure.service";
        };
        Service = {
          Type = "oneshot";
          Environment = "PATH=${config.home.homeDirectory}/.local/state/nix/profiles/ai-stack/bin:${config.home.profileDirectory}/bin:/run/current-system/sw/bin";
          ExecStart = "${prReview}/bin/pr-review selftest --if-stale ${toString cfg.prReview.selftest.staleHours}";
        };
      };
      pr-review-selftest-failure = {
        Unit.Description = "Report a failed pr-review self-test";
        Service = {
          Type = "oneshot";
          ExecStart = ''${pkgs.libnotify}/bin/notify-send --urgency=critical --app-name=pr-review "pr-review cannot run reviews" "A reviewer client failed its self-test. See: journalctl --user -u pr-review-selftest"'';
        };
      };
    };
    systemd.user.timers.pr-review-selftest = mkIf (cfg.prReview.selftest.enable && pkgs.stdenv.hostPlatform.isLinux) {
      Unit.Description = "Hourly pr-review self-test, skipped while clients and reviewers are unchanged";
      Timer = {
        OnCalendar = "hourly";
        RandomizedDelaySec = 600;
        Persistent = true;
      };
      Install.WantedBy = ["timers.target"];
    };

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
      run ${mergeCodexTables}/bin/merge-codex-tables \
        "${config.home.homeDirectory}/.codex/config.toml" \
        "${config.xdg.stateHome}/agent-mcp/codex-settings-managed.json" ${codexSettings} . \
        || warnEcho "Codex settings were not updated; see the message above."
      run ${mergeClaudeMcp}/bin/merge-claude-mcp \
        "${config.home.homeDirectory}/.claude.json" \
        "${config.xdg.stateHome}/agent-mcp/claude-managed.json" ${claudeMcpServers} \
        || warnEcho "Claude Code MCP servers were not updated; see the message above."
    '';
  };
}
