# modules/home-manager/programs/tea/default.nix
#
# Runs tea with the activated Forgejo API token instead of a token stored in
# its own config. The wrapper reads the file named by FORGEJO_API_TOKEN_FILE at
# each start and passes it through tea's environment login (GITEA_INSTANCE_URL
# and GITEA_TOKEN), which takes precedence over stored logins unless `--login`
# names one. The token never appears in arguments or in ~/.config/tea, and a
# rotated file reaches tea without further changes. Callers that unset the
# variable, such as pr-review's reviewers, get no credential from the wrapper.
#
# T3 Code's Forgejo integration only uses stored logins: it matches one from
# `tea login list` against the repository remote and passes it with `--login`.
# Activation therefore keeps a stored login for the instance in tea's config
# with its URL and SSH host, adding no token, and the wrapper drops
# `--login <that login>` whenever it has the token, so T3's calls use the
# environment login too (#704). While the token file is set, naming that login
# therefore no longer selects it; unset FORGEJO_API_TOKEN_FILE to use a token
# stored in it. The t3code-forgejo-login-contract check runs
# T3's own matching against that login, so a T3 update that changes it fails
# package promotion.
#
# tea builds the environment login without a username: give repositories as
# owner/repo rather than a bare name, and expect commands scoped to the login's
# user, such as `tea org list`, to fail (use `tea api` paths instead).
# `tea clone <url>` looks up a stored login by host and ignores the environment
# login; clone with git instead.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.tea;
  # tea's xdg library puts its config here, relative to HOME, unless
  # XDG_CONFIG_HOME is set.
  configHome =
    if pkgs.stdenv.hostPlatform.isDarwin
    then "Library/Application Support"
    else ".config";
  urlHost = lib.head (lib.splitString "/" (lib.removePrefix "http://" (lib.removePrefix "https://" cfg.url)));
  teaWithTokenFile = pkgs.writeShellApplication {
    name = "tea";
    text = ''
      tea_bin=${pkgs.tea}/bin/tea
      tea_url=${lib.escapeShellArg cfg.url}
      tea_login=${lib.escapeShellArg cfg.login.name}
      ${builtins.readFile ./tea-with-token-file.sh}
    '';
  };
  ensureLogin = pkgs.writeShellApplication {
    name = "tea-ensure-login";
    runtimeInputs = with pkgs; [coreutils diffutils yq-go];
    text = ''
      tea_url=${lib.escapeShellArg cfg.url}
      tea_login=${lib.escapeShellArg cfg.login.name}
      tea_ssh_host=${lib.escapeShellArg cfg.login.sshHost}
      tea_config_home=${lib.escapeShellArg configHome}
      ${builtins.readFile ./ensure-login.sh}
    '';
  };
in {
  options.programs.tea = {
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://git.alc.xyz";
      description = "Forgejo instance tea's environment login points at.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = config.home.sessionVariables.FORGEJO_API_TOKEN_FILE or null;
      defaultText = lib.literalExpression "config.home.sessionVariables.FORGEJO_API_TOKEN_FILE or null";
      description = ''
        Session token file that enables the wrapper. At run time the wrapper
        reads FORGEJO_API_TOKEN_FILE, not this value, so a caller that unsets
        the variable runs tea without the token. When null, tea is left
        unwrapped and uses its stored logins.
      '';
    };
    login = {
      name = lib.mkOption {
        type = lib.types.str;
        default = urlHost;
        defaultText = lib.literalExpression "the host of programs.tea.url";
        description = "Name of the stored login for the instance that activation keeps and the wrapper replaces with the environment login.";
      };
      sshHost = lib.mkOption {
        type = lib.types.str;
        default = urlHost;
        defaultText = lib.literalExpression "the host of programs.tea.url";
        description = "SSH host of the instance's Git remotes, which T3 Code matches against the stored login.";
      };
    };
  };

  # hiPrio: the wrapper wins over pkgs.tea from the package sets, whose
  # completions and other files still apply.
  config = lib.mkIf (cfg.tokenFile != null) {
    home.packages = [(lib.hiPrio teaWithTokenFile)];

    home.activation.teaManagedLogin = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run ${ensureLogin}/bin/tea-ensure-login
    '';
  };
}
