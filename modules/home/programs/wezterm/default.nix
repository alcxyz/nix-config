{ options
, config
, pkgs
, lib
, inputs
, ...
}:
with lib;
let
  cfg = config.programs.wezterm;
  colors = (inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme}).palette;
in
{
  options.programs.wezterm = with types; {
    enable = mkBoolOpt false "Enable or disable the wezterm terminal Home Manager configuration."; # Updated option path and description
  };

  config = mkIf cfg.enable {
    # System package installation for wezterm should be done at the system level.
    # For example, in modules/system/suites/desktop/packages.nix

    home.programs.wezterm = {
      enable = true;

      # Configure colors using the nix-colors palette
      colors = {
        foreground = colors.base05;
        background = colors.base00;
        cursor_fg = colors.base05;
        cursor_bg = colors.base05;
        # Add more color mappings as needed based on WezTerm documentation and nix-colors palette
        # For example, the 16 ANSI colors:
        black = colors.base00;
        red = colors.base08;
        green = colors.base0B;
        yellow = colors.base0A;
        blue = colors.base0D;
        magenta = colors.base0E;
        cyan = colors.base0C;
        white = colors.base05;

        # Bright ANSI colors
        bright_black = colors.base03;
        bright_red = colors.base08;
        bright_green = colors.base0B;
        bright_yellow = colors.base0A;
        bright_blue = colors.base0D;
        bright_magenta = colors.base0E;
        bright_cyan = colors.base0C;\
        bright_white = colors.base07;
      };

      extraConfig = ''
    return {
      font = wezterm.font("JetBrains Mono"),
      font_size = 13.0,
      hide_tab_bar_if_only_one_tab = true,
      -- color_scheme is set via home.programs.wezterm.colors
    }
    '';
    };
  };
}