{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib;

let
  cfg = config.programs.wlogout.managed;
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;
  
  # Simple string replacement approach
  substituteColors = text: 
    let
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
    
  # Choose style based on variant
  styleFile = if cfg.style == "enhanced" then ./style-enhanced.css.template else ./style.css.template;
  
  # Read template and process it
  styleTemplate = builtins.readFile styleFile;
  processedStyle = substituteColors styleTemplate;
in
{
  options.programs.wlogout.managed = {
    enable = mkEnableOption "wlogout session exit UI";
    
    style = mkOption {
      type = types.enum [ "minimal" "enhanced" ];
      default = "minimal";
      description = ''
        Wlogout style variant:
        - minimal: Simple, clean style
        - enhanced: More detailed styling with hover effects and colors
      '';
    };
  };

  config = mkIf cfg.enable {
    programs.wlogout.enable = true; 

    # Dynamic CSS with color substitution
    xdg.configFile."wlogout/style.css".text = processedStyle;
    
    # Static layout file
    xdg.configFile."wlogout/layout".source = ./layout;
  };
}
