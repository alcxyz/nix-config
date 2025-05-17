{ config, lib, pkgs, inputs, ... }:

with lib;

let
  colorscheme = inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme};
  colors = colorscheme.palette;
in
{
  # This module configures the built-in Home Manager programs.foot module.
  # It does not define its own enable option, but depends on programs.foot.enable being set elsewhere.

  config = mkIf config.programs.foot.enable { # Use the built-in enable option
    # Configuration for programs.foot when it's enabled.
    # Home Manager's programs.foot.enable handles package installation.

    # Configure colors using the nix-colors palette, using programs.foot.colors option
    programs.foot.colors = {
      foreground = colors.base05;
      background = colors.base00;

      # Standard 16 ANSI colors mapping
      regular0 = colors.base00; # black
      regular1 = colors.base08; # red
      regular2 = colors.base0B; # green
      regular3 = colors.base0A; # yellow
      regular4 = colors.base0D; # blue
      regular5 = colors.base0E; # magenta
      regular6 = colors.base0C; # cyan
      regular7 = colors.base05; # white

      bright0 = colors.base03; # bright black
      bright1 = colors.base08; # bright red (often same as regular red)
      bright2 = colors.base0B; # bright green (often same as regular green)
      bright3 = colors.base0A; # bright yellow (often same as regular yellow)
      bright4 = colors.base0D; # bright blue (often same as regular blue)
      bright5 = colors.base0E; # bright magenta (often same as regular magenta)
      bright6 = colors.base0C; # bright cyan (often same as regular cyan)
      bright7 = colors.base07; # bright white
    };

    # Configure other foot settings using programs.foot options
    programs.foot.settings = {
      font = "JetBrains Mono Nerd Font:size=12";
      # Foot uses a single 'pad' setting, not x and y separately in the config file,
      # but Home Manager module might split it or take a string.
      # Assuming it takes a string similar to the config file for now.
      pad = "5x5";

      # Add other settings from your original foot.ini here as needed,
      # using the programs.foot.settings structure or other dedicated options.
    };
  };
}