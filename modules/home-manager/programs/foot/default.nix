# modules/home-manager/programs/foot/default.nix
{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.programs.foot;
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;
in
{
  config = mkIf cfg.enable {
    programs.foot.settings = {
      "colors-dark" = {
        foreground = colors.base05;
        background = colors.base00;

        regular0 = colors.base00;
        regular1 = colors.base08;
        regular2 = colors.base0B;
        regular3 = colors.base0A;
        regular4 = colors.base0D;
        regular5 = colors.base0E;
        regular6 = colors.base0C;
        regular7 = colors.base05;

        bright0 = colors.base03;
        bright1 = colors.base08;
        bright2 = colors.base0B;
        bright3 = colors.base0A;
        bright4 = colors.base0D;
        bright5 = colors.base0E;
        bright6 = colors.base0C;
        bright7 = colors.base07;
      };

      main = {
        font = "JetBrains Mono Nerd Font:size=12";
        pad = "5x5";
      };
    };
  };
}
