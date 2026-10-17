# modules/home-manager/programs/ai/agent-forge.nix
#
# Agent forge account (#722, ADR-0081): agent sessions act on Forgejo as a
# separate account, while the operator's login shells keep the operator's
# credentials and commits keep the operator's Git identity. This module
# declares the account and the shell commands that set up an agent session;
# services.t3code runs them in its session wrapper after the Home Manager
# session variables. The Forgejo MCP server follows FORGEJO_API_TOKEN_FILE.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.programs.ai.agentForge;
  url = removeSuffix "/" cfg.url;
  # Git runs the helper through the shell with `get`, `store` or `erase`
  # appended. The token comes from the file, never from an argument or from a
  # FORGEJO_TOKEN the session may carry: forge-mirror treats an empty one as
  # unset, answers only `get`, and answers nothing without a token.
  credentialHelper = "!FORGEJO_TOKEN= FORGEJO_TOKEN_FILE=${escapeShellArg cfg.tokenFile} FORGEJO_USER=${escapeShellArg cfg.user} ${escapeShellArg "${cfg.package}/bin/forge-mirror"} credential-helper";
  gitConfig = [
    # An empty value resets the helpers configured so far for the forge, so
    # Git asks only the agent account's helper there; other hosts keep theirs.
    {
      key = "credential.${url}.helper";
      value = "";
    }
    {
      key = "credential.${url}.helper";
      value = credentialHelper;
    }
    # An SSH push would authenticate with the operator's key, so pushes go
    # over HTTPS. pushInsteadOf rewrites the remote's own URL before insteadOf
    # applies, so the HTTPS form maps to itself to win over a host-wide
    # insteadOf that sends HTTPS to SSH. Fetches keep their URLs.
    {
      key = "url.${url}/.pushInsteadOf";
      value = "${url}/";
    }
    {
      key = "url.${url}/.pushInsteadOf";
      value = "git@${cfg.sshHost}:";
    }
    {
      key = "url.${url}/.pushInsteadOf";
      value = "ssh://git@${cfg.sshHost}/";
    }
  ];
  # forge-mirror's own subcommands authenticate with FORGEJO_TOKEN
  # (preferred) or FORGEJO_TOKEN_FILE, so their API calls act as the account.
  # FORGEJO_USER stays the operator's: there it names the namespace whose
  # repositories forge-mirror works on, not the login.
  sessionCommands = ''
    FORGEJO_API_TOKEN_FILE=${escapeShellArg cfg.tokenFile}
    FORGEJO_TOKEN_FILE=${escapeShellArg cfg.tokenFile}
    export FORGEJO_API_TOKEN_FILE FORGEJO_TOKEN_FILE
    unset FORGEJO_TOKEN
    agent_git_config=''${GIT_CONFIG_COUNT:-0}
    [[ $agent_git_config =~ ^[0-9]+$ ]] || agent_git_config=0
    ${concatMapStrings (entry: ''
        export "GIT_CONFIG_KEY_$agent_git_config="${escapeShellArg entry.key} "GIT_CONFIG_VALUE_$agent_git_config="${escapeShellArg entry.value}
        agent_git_config=$((agent_git_config + 1))
      '')
      gitConfig}export GIT_CONFIG_COUNT=$agent_git_config
    unset agent_git_config
  '';
in {
  options.programs.ai.agentForge = {
    enable = mkEnableOption ''
      a separate forge account for agent sessions: T3 Code's session wrapper
      points FORGEJO_API_TOKEN_FILE and forge-mirror's FORGEJO_TOKEN_FILE at
      its token, keeping FORGEJO_USER, and sends Git pushes to the
      forge over HTTPS with its credentials; tea and the Forgejo MCP server
      follow FORGEJO_API_TOKEN_FILE. This is attribution and an accident
      guard, not a privilege boundary (ADR-0081). Login shells are not changed: `claude` or `codex`
      started from one act as the operator throughout (ADR-0081)'';
    tokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "File holding the agent account's API token, read at use. Provisioned privately.";
    };
    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Name of the agent account, given to Git with its token.";
    };
    url = mkOption {
      type = types.str;
      default = config.programs.ai.forgejoMcp.url;
      defaultText = literalExpression "config.programs.ai.forgejoMcp.url";
      description = "HTTPS URL of the forge, without a path; pushes to it use the agent account.";
    };
    sshHost = mkOption {
      type = types.nullOr types.str;
      default = config.programs.tea.login.sshHost or null;
      defaultText = literalExpression "config.programs.tea.login.sshHost or null";
      description = "SSH host of the forge's Git remotes, whose pushes are sent over HTTPS instead.";
    };
    package = mkPackageOption pkgs "forge-mirror" {
      extraDescription = "Its `credential-helper` answers Git with the agent account and token.";
    };
    sessionCommands = mkOption {
      type = types.lines;
      internal = true;
      readOnly = true;
      default = optionalString cfg.enable sessionCommands;
      description = "Bash commands that give an agent session the agent account; empty when disabled.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tokenFile != null && hasPrefix "/" cfg.tokenFile && cfg.user != null && cfg.sshHost != null && hasPrefix "https://" cfg.url;
        message = "programs.ai.agentForge needs an absolute tokenFile, a user, an sshHost and an https:// url.";
      }
    ];
  };
}
