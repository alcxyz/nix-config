{ options,
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib;
let
  # Assuming config.desktop.colorscheme is accessible via config or passed through
  # If not directly available, we might need to pass it as an extraSpecialArg
  # For now, let's assume it's available or passed.
  colorscheme = inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme};
  colors = colorscheme.palette;

in {
  options.programs.foot = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable or disable the foot terminal user configuration.";
    };
  };

  config = mkIf config.programs.foot.enable {
    # Install Foot package at user level via Home Manager
    home.packages = [ pkgs.foot ];

    # Set up the Foot configuration file
    home.configFile."foot/foot.ini".text = ''
      font=JetBrains Mono Nerd Font:size=12
      pad=5x5
      [colors]
      foreground=${colors.base05}
      background=${colors.base00}
      regular0=${colors.base03}
      regular1=${colors.base08}
      regular2=${colors.base0B}
      regular3=${colors.base0A}
      regular4=${colors.base0D}
      regular5=${colors.base0F}
      regular6=${colors.base0C}
      regular7=${colors.base05}
      bright0=${colors.base04}
      bright1=${colors.base08}
      bright2=${colors.base0B}
      bright3=${colors.base0A}
      bright4=${colors.base0D}
      bright5=${colors.base0F}
      bright6=${colors.base0C}
      bright7=${colors.base05}
    '';

    # Ensure the .config/foot directory exists
    # Home Manager usually handles this for config files, but being explicit doesn't hurt.
    # xdg.configFile."foot".source = ""; # This is one way, but home.configFile handles the parent dirs.

  };
}
