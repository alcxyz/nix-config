# modules/home-manager/programs/ai/agent-github.nix
#
# Agent GitHub App (ADR-0099): agent sessions act on the repositories a GitHub
# App is installed on through its one-hour installation tokens, while every
# other GitHub repository keeps the operator's own `gh` login. Commits keep the
# operator's Git identity. Like programs.ai.agentForge, this applies only to
# the processes T3 Code starts; services.t3code runs sessionCommands in its
# session wrapper. T3's package puts its own `gh` first on PATH, so that `gh`
# is gh-app's pass-through (nix-packages `gh-app-gh`), which routes only when
# the session sets the App's variables below.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.programs.ai.agentGithub;
  ghApp = getExe cfg.package;
  gh = getExe cfg.ghPackage;
  appEnv = "GH_APP_ID=${escapeShellArg (toString cfg.appId)} GH_APP_KEY_FILE=${escapeShellArg cfg.keyFile} GH_APP_OWNER=${escapeShellArg cfg.owner}";
  # Git passes the repository path to helpers only with useHttpPath. An empty
  # value resets the helpers configured so far for github.com; the App's
  # helper answers for installed repositories and stays silent otherwise, so
  # Git asks the operator's gh login next.
  gitConfig = [
    {
      key = "credential.https://github.com.useHttpPath";
      value = "true";
    }
    {
      key = "credential.https://github.com.helper";
      value = "";
    }
    {
      key = "credential.https://github.com.helper";
      value = "!${appEnv} ${escapeShellArg ghApp} credential";
    }
    {
      key = "credential.https://github.com.helper";
      value = "!${escapeShellArg gh} auth git-credential";
    }
    # An SSH push would authenticate with the operator's key, so pushes to the
    # owner's repositories go over HTTPS, and the HTTPS form maps to itself to
    # win over a host-wide insteadOf that sends HTTPS to SSH (as in
    # agent-forge.nix). Other owners keep their transport.
    {
      key = "url.https://github.com/${cfg.owner}/.pushInsteadOf";
      value = "https://github.com/${cfg.owner}/";
    }
    {
      key = "url.https://github.com/${cfg.owner}/.pushInsteadOf";
      value = "git@github.com:${cfg.owner}/";
    }
    {
      key = "url.https://github.com/${cfg.owner}/.pushInsteadOf";
      value = "ssh://git@github.com/${cfg.owner}/";
    }
  ];
  # gh-app's pass-through `gh` and agent-job read these; Git's helper has
  # them in its command.
  sessionCommands = ''
    GH_APP_ID=${escapeShellArg (toString cfg.appId)}
    GH_APP_KEY_FILE=${escapeShellArg cfg.keyFile}
    GH_APP_OWNER=${escapeShellArg cfg.owner}
    export GH_APP_ID GH_APP_KEY_FILE GH_APP_OWNER
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
  options.programs.ai.agentGithub = {
    enable = mkEnableOption ''
      a GitHub App for agent sessions: T3 Code's session wrapper sets the
      App's variables, so the `gh` in T3's package (gh-app's pass-through)
      uses the App's installation token for the owner's installed repositories
      and the operator's login elsewhere, and Git pushes to those repositories
      over HTTPS with the App's token. Set
      GH_AS_OPERATOR=1 on a command to run it as the operator. Attribution
      and an accident guard, not a privilege boundary (ADR-0099)'';
    appId = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "The GitHub App's numeric ID.";
    };
    keyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "File holding the App's PEM private key, read at use. Provisioned privately.";
    };
    owner = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "GitHub account the App is installed on; only its repositories use the App.";
    };
    package = mkPackageOption pkgs "gh-app" {
      extraDescription = "Its `credential` command answers Git with the App's installation token.";
    };
    ghPackage = mkOption {
      type = types.package;
      default = config.programs.gh.package or pkgs.gh;
      defaultText = literalExpression "config.programs.gh.package or pkgs.gh";
      description = "The `gh` whose login answers Git for repositories outside the App.";
    };
    sessionCommands = mkOption {
      type = types.lines;
      internal = true;
      readOnly = true;
      default = optionalString cfg.enable sessionCommands;
      description = "Bash commands that give an agent session the GitHub App; empty when disabled.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.appId != null && cfg.keyFile != null && hasPrefix "/" cfg.keyFile && cfg.owner != null && builtins.match "[A-Za-z0-9-]+" cfg.owner != null;
        message = "programs.ai.agentGithub needs an appId, an absolute keyFile and an owner login.";
      }
    ];
  };
}
