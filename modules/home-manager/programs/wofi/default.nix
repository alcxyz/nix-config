{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib;

let
  cfg = config.programs.wofi.managed;
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;
  
  # Simple string replacement approach (no deprecated functions)
  substituteColors = text: 
    let
      # Create substitution pairs with lowercase placeholders
      colorPlaceholders = [
        "@base00@" "@base01@" "@base02@" "@base03@"
        "@base04@" "@base05@" "@base06@" "@base07@"
        "@base08@" "@base09@" "@base0a@" "@base0b@"
        "@base0c@" "@base0d@" "@base0e@" "@base0f@"
      ];
      colorValues = [
        colors.base00 colors.base01 colors.base02 colors.base03
        colors.base04 colors.base05 colors.base06 colors.base07
        colors.base08 colors.base09 colors.base0A colors.base0B
        colors.base0C colors.base0D colors.base0E colors.base0F
      ];
    in
    builtins.replaceStrings colorPlaceholders colorValues text;
    
  # Read template and process it
  styleTemplate = builtins.readFile ./style.css.template;
  processedStyle = substituteColors styleTemplate;
in
{
  options.programs.wofi.managed = {
    enable = mkEnableOption "Wofi application launcher";
  };

  config = mkIf cfg.enable {
    programs.wofi.enable = true;

    xdg.configFile."wofi/config".source = ./config;
    xdg.configFile."wofi/style.css".text = processedStyle;
  };
}
