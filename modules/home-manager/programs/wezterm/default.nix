# modules/home-manager/programs/wezterm/default.nix
{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.programs.wezterm; # Use the built-in module's enable option
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;

  # Define a color scheme based on the nix-colors palette
  # The key "PaletteScheme" is the name you give this scheme
  paletteColorScheme = {
    # ANSI colors (standard 0-7)
    ansi = [
      colors.base00 # black
      colors.base08 # red
      colors.base0B # green
      colors.base0A # yellow
      colors.base0D # blue
      colors.base0E # magenta
      colors.base0C # cyan
      colors.base05 # white
    ];

    # Bright ANSI colors (bright 0-7)
    brights = [
      colors.base03 # bright black
      colors.base08 # bright red (often same)
      colors.base0B # bright green (often same)
      colors.base0A # bright yellow (often same)
      colors.base0D # bright blue (often same)
      colors.base0E # bright magenta (often same)
      colors.base0C # bright cyan (often same)
      colors.base07 # bright white
    ];

    background = colors.base00;
    foreground = colors.base05;

    # Cursor colors (example mapping)
    cursor_bg = colors.base05;
    cursor_border = colors.base05;
    cursor_fg = colors.base00;

    # Selection colors (example mapping)
    selection_bg = colors.base03;
    selection_fg = colors.base05;
  };

in
{
  config = mkIf cfg.enable {
    # The built-in programs.wezterm module is enabled in users/alc/home.nix.
    # No need to set programs.wezterm.enable = true here.

    # Define the color scheme using the programs.wezterm.colorSchemes option
    programs.wezterm.colorSchemes = {
      "PaletteScheme" = paletteColorScheme;
    };

    # Provide additional Lua configuration via programs.wezterm.extraConfig
    programs.wezterm.extraConfig = ''
      -- Set the active color scheme by name
      config.color_scheme = "PaletteScheme"

      -- Add other WezTerm configuration settings here using Lua syntax
      config.font = wezterm.font("JetBrains Mono Nerd Font", { weight = "Regular" })
      config.font_size = 12.0

      -- config.initial_rows = 24
      -- config.initial_cols = 80

      -- Add any other configuration variables from your WezTerm config
    '';

  };
}
