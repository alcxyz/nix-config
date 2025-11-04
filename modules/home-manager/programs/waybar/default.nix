{
  options,
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
with lib;

let
  cfg = config.programs.waybar.managed; 
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;
  
  # Simple string replacement approach (same as wofi)
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
    
  # Choose config and style based on variant
  configFile = if cfg.variant == "alternative" then ./config-alt.jsonc else ./config.jsonc;
  styleFile = if cfg.variant == "alternative" then ./style-alt.css.template else ./style.css.template;
  
  # Read template and process it
  styleTemplate = builtins.readFile styleFile;
  processedStyle = substituteColors styleTemplate;
in
{
  options.programs.waybar.managed = {
    enable = mkEnableOption "Waybar status bar";
    
    variant = mkOption {
      type = types.enum [ "default" "alternative" ];
      default = "default";
      description = ''
        Waybar configuration variant to use:
        - default: Original configuration
        - alternative: Compact horizontal layout with colored icons
      '';
    };
  };

  config = mkIf cfg.enable {
    programs.waybar.enable = true;

    # Static config file (variant-dependent)
    xdg.configFile."waybar/config.jsonc" = {
      source = configFile;
      onChange = ''${pkgs.busybox}/bin/pkill -SIGUSR2 waybar'';
    };
    
    # Dynamic CSS with color substitution (variant-dependent)
    xdg.configFile."waybar/style.css" = {
      text = processedStyle;
      onChange = ''${pkgs.busybox}/bin/pkill -SIGUSR2 waybar'';
    };

    # Install scripts
    xdg.configFile."waybar/scripts/system-cycle.sh" = {
      source = ./scripts/system-cycle.sh;
      executable = true;
    };
    
    xdg.configFile."waybar/scripts/dual-clock.sh" = {
      source = ./scripts/dual-clock.sh;
      executable = true;
    };
  };
}
