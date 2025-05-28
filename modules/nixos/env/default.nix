{
  options,
  config,
  lib,
  ...
}:
with lib;
# Removed 'with lib.custom;'
let
  # cfg now directly refers to config.system.env, which is the option itself.
  # This is fine for the 'extraInit' part as it reads the final value of the option.
  cfg = config.system.env;
in {
  options.system.env = with lib.types; # Explicitly use lib.types
    lib.mkOption { # This is already the standard lib.mkOption
      type = attrsOf (oneOf [str path (listOf (either str path))]);
      apply = mapAttrs (_n: v:
        if isList v
        then concatMapStringsSep ":" toString v
        else (toString v));
      default = {};
      description = "A set of environment variables to set.";
    };

  config = {
    environment = {
      sessionVariables = {
        XDG_CACHE_HOME = "$HOME/.cache";
        XDG_CONFIG_HOME = "$HOME/.config";
        XDG_DATA_HOME = "$HOME/.local/share";
        XDG_BIN_HOME = "$HOME/.local/bin";
        # To prevent firefox from creating ~/Desktop.
        XDG_DESKTOP_DIR = "$HOME";
      };
      variables = {
        # Make some programs "XDG" compliant.
        LESSHISTFILE = "$XDG_CACHE_HOME/less.history";
        WGETRC = "$XDG_CONFIG_HOME/wgetrc";
      };
      # cfg here refers to the final evaluated value of options.system.env
      extraInit =
        concatStringsSep "
"
        (mapAttrsToList (n: v: ''export ${n}="${v}"'') cfg);
    };
  };
}
