{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib;

let
  # Use the specific enable flag for wofi from the parent hyprland module
  cfg = config.programs.wofi; # Updated path
  colorscheme = inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme};
  colors = colorscheme.palette;
in
{
  # The option 'options.programs.wofi.enable' will be defined in 
  # a new or existing programs aggregator module (e.g. modules/home-manager/programs/default.nix)

  config = mkIf cfg.enable {
    # Enable the core Home Manager wofi program.
    programs.wofi.enable = true;

    # Configure Wofi configuration files via Home Manager
    home.configFile."wofi/config".source = ./config; # Path relative to this module
    home.configFile."wofi/style.css".text = '''
      window {
          margin: 5px;
          border: 5px solid #181926;
          background-color: #${colors.base00};
          border-radius: 15px;
          font-family: "JetBrainsMono";
          font-size: 14px;
        }

        #input {
          all: unset;
          min-height: 36px;
          padding: 4px 10px;
          margin: 4px;
          border: none;
          color: #${colors.base05};
          font-weight: bold;
          background-color: #${colors.base01};
          outline: none;
          border-radius: 15px;
          margin: 10px;
          margin-bottom: 2px;
        }

        #inner-box {
          margin: 4px;
          padding: 10px;
          font-weight: bold;
          border-radius: 15px;
        }

        #outer-box {
          margin: 0px;
          padding: 3px;
          border: none;
          border-radius: 15px;
          border: 5px solid #${colors.base01};
        }

        #scroll {
          margin-top: 5px;
          border: none;
          border-radius: 15px;
          margin-bottom: 5px;
        }

        #text:selected {
          color: #${colors.base01};
          margin: 0px 0px;
          border: none;
          border-radius: 15px;
        }

        #entry {
          margin: 0px 0px;
          border: none;
          border-radius: 15px;
          background-color: transparent;
        }

        #entry:selected {
          margin: 0px 0px;
          border: none;
          border-radius: 15px;
          background: #${colors.base0D};
          background-size: 400% 400%;
        }
    ''';
  };
}
