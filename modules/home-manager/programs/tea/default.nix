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
  teaWithTokenFile = pkgs.writeShellApplication {
    name = "tea";
    text = ''
      token_file=''${FORGEJO_API_TOKEN_FILE:-}
      token=
      if [ -n "$token_file" ] && [ -f "$token_file" ] && [ -r "$token_file" ]; then
        token=$(<"$token_file")
      fi
      if [ -n "''${token//[[:space:]]/}" ]; then
        GITEA_TOKEN=$token
        GITEA_INSTANCE_URL=${lib.escapeShellArg cfg.url}
        export GITEA_TOKEN GITEA_INSTANCE_URL
      elif [ -n "$token_file" ]; then
        echo "tea: no token in $token_file; using stored logins" >&2
      fi
      unset token
      exec ${pkgs.tea}/bin/tea "$@"
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
  };

  # hiPrio: the wrapper wins over pkgs.tea from the package sets, whose
  # completions and other files still apply.
  config = lib.mkIf (cfg.tokenFile != null) {
    home.packages = [(lib.hiPrio teaWithTokenFile)];
  };
}
