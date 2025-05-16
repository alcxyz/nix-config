{ options
, config
, pkgs
, lib
, inputs
, ...
}:
with lib;
with lib.custom; let
  cfg = config.apps.wez;
  #inherit (inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme}) colors;
  colors = (inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme}).palette;
in
{
  options.apps.wez= with types; {
    enable = mkBoolOpt false "Enable or disable the wezterm terminal.";
  };

  config = mkIf cfg.enable {
    #environment.systemPackages = [ pkgs.wezterm];
    home.programs.wezterm.enable = true;

    home.programs.wezterm.extraConfig = ''
    return {
      font = wezterm.font("JetBrains Mono"),
      font_size = 13.0,
      color_scheme = "Catppuccin Mocha",
      hide_tab_bar_if_only_one_tab = true,
    }
    '';
  };
}
