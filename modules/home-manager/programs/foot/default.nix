# modules/home-manager/programs/foot/default.nix
{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.programs.foot; # Use the built-in module's enable option
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;
in
{
  # This module *only* provides configuration values for the built-in
  # programs.foot module. It relies on programs.foot.enable being set
  # elsewhere (e.g., in users/alc/home.nix).
  # It does *not* declare its own options.

  config = mkIf cfg.enable {
    # The built-in programs.foot module is enabled in users/alc/home.nix.
    # No need to set programs.foot.enable = true here.

    # Configure settings for foot.ini using the structured attribute set format
    # expected by programs.foot.settings.
    programs.foot.settings = {
      # This maps to the [colors] section in foot.ini
      colors = {
        foreground = colors.base05;
        background = colors.base00;

        # Standard 16 ANSI colors mapping
        regular0 = colors.base00;   # black
        regular1 = colors.base08;   # red
        regular2 = colors.base0B;   # green
        regular3 = colors.base0A;   # yellow
        regular4 = colors.base0D;   # blue
        regular5 = colors.base0E;   # magenta
        regular6 = colors.base0C;   # cyan
        regular7 = colors.base05;   # white

        bright0 = colors.base03;    # bright black
        bright1 = colors.base08;    # bright red (often same as regular red)
        bright2 = colors.base0B;    # bright green (often same as regular green)
        bright3 = colors.base0A;    # bright yellow (often same as regular yellow)
        bright4 = colors.base0D;    # bright blue (often same as regular blue)
        bright5 = colors.base0E;    # bright magenta (often same as regular magenta)
        bright6 = colors.base0C;    # bright cyan (often same as regular cyan)
        bright7 = colors.base07;    # bright white
      };

      # This maps to the [main] section in foot.ini
      main = {
        font = "JetBrains Mono Nerd Font:size=12";
        pad = "5x5"; # Foot uses this string format in its config
        # Add other settings from your original foot.ini here as needed,
        # using the attribute set structure.
        # term = "foot"; # Example
      };

      # Add other sections (e.g., [scrollback], [tweak]) here as attribute sets
      # scrollback = {
      #   lines = 10000;
      # };
    };

    # The `xdg.configFile."foot/foot.ini"` definition should *not* be in your module.
    # The built-in programs.foot module handles writing the foot.ini based on
    # the programs.foot.settings option. Managing the file directly via xdg.configFile
    # when using the structured settings option is redundant and might cause conflicts.
    # If you had this in your custom module, remove it:
    # xdg.configFile."foot/foot.ini" = ...; # REMOVE THIS IF IT'S THERE
  };
}

#{ config, lib, pkgs, inputs, ... }:
#
#with lib;
#
#let
#  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
#  colors = colorscheme.palette;
#in
#{
#  # This module configures the built-in Home Manager programs.foot module.
#  # It does not define its own enable option, but depends on programs.foot.enable being set elsewhere.
#
#  config = mkIf config.programs.foot.enable { # Use the built-in enable option
#    # Configuration for programs.foot when it's enabled.
#    # Home Manager's programs.foot.enable handles package installation.
#
#    # Configure colors using the nix-colors palette, using programs.foot.colors option
#    programs.foot.colors = {
#      foreground = colors.base05;
#      background = colors.base00;
#
#      # Standard 16 ANSI colors mapping
#      regular0 = colors.base00; # black
#      regular1 = colors.base08; # red
#      regular2 = colors.base0B; # green
#      regular3 = colors.base0A; # yellow
#      regular4 = colors.base0D; # blue
#      regular5 = colors.base0E; # magenta
#      regular6 = colors.base0C; # cyan
#      regular7 = colors.base05; # white
#
#      bright0 = colors.base03; # bright black
#      bright1 = colors.base08; # bright red (often same as regular red)
#      bright2 = colors.base0B; # bright green (often same as regular green)
#      bright3 = colors.base0A; # bright yellow (often same as regular yellow)
#      bright4 = colors.base0D; # bright blue (often same as regular blue)
#      bright5 = colors.base0E; # bright magenta (often same as regular magenta)
#      bright6 = colors.base0C; # bright cyan (often same as regular cyan)
#      bright7 = colors.base07; # bright white
#    };
#
#    # Configure other foot settings using programs.foot options
#    programs.foot.settings = {
#      font = "JetBrains Mono Nerd Font:size=12";
#      # Foot uses a single 'pad' setting, not x and y separately in the config file,
#      # but Home Manager module might split it or take a string.
#      # Assuming it takes a string similar to the config file for now.
#      pad = "5x5";
#
#      # Add other settings from your original foot.ini here as needed,
#      # using the programs.foot.settings structure or other dedicated options.
#    };
#  };
#}
