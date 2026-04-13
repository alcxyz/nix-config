# modules/home-manager/programs/wezterm/default.nix
{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.programs.wezterm; # Use the built-in module's enable option
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;

  # Define a color scheme based on the nix-colors palette
  paletteColorScheme = {
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

    brights = [
      colors.base03 # bright black
      colors.base08 # bright red
      colors.base0B # bright green
      colors.base0A # bright yellow
      colors.base0D # bright blue
      colors.base0E # bright magenta
      colors.base0C # bright cyan
      colors.base07 # bright white
    ];

    background = colors.base00;
    foreground = colors.base05;

    cursor_bg = colors.base05;
    cursor_border = colors.base05;
    cursor_fg = colors.base00;

    selection_bg = colors.base03;
    selection_fg = colors.base05;
  };

in
{
  config = mkIf cfg.enable {
    programs.wezterm.colorSchemes = {
      "PaletteScheme" = paletteColorScheme;
    };

    programs.wezterm.extraConfig = ''
      config.color_scheme = "PaletteScheme"

      config.font = wezterm.font("JetBrains Mono Nerd Font", { weight = "Regular" })
      config.font_size = 14.0

      -- Window appearance
      config.window_background_opacity = 0.85
      config.macos_window_background_blur = 20
      config.window_decorations = "RESIZE"
      config.window_padding = { left = 8, right = 8, top = 8, bottom = 8 }
      config.window_close_confirmation = "NeverPrompt"

      -- No tab bar for clean look
      config.enable_tab_bar = false

      -- Native fullscreen is slower (animates), use non-native
      config.native_macos_fullscreen_mode = false
    '';
  };
}
