{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib;

let
  # Use the specific enable flag for wlogout
  cfg = config.programs.wlogout; # Updated path
  colorscheme = inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme};
  colors = colorscheme.palette;
in
{
  # The option 'options.programs.wlogout.enable' will be defined in
  # a new or existing programs aggregator module (e.g. modules/home-manager/programs/default.nix)

  config = mkIf cfg.enable {
    programs.wlogout.enable = true; 

    home.configFile."wlogout/style.css".text = '''
       * {
         all: unset;
         font-family: JetBrains Mono Nerd Font;
       }

       window {
         background-color: #${colors.base00};
       }

       button {
         color: #${colors.base01};
         font-size: 64px;
         background-color: rgba(0,0,0,0);
         outline-style: none;
         margin: 5px;
      }

       button:focus, button:active, button:hover {
         color: #${colors.base0D};
         transition: ease 0.4s;
       }
    ''';

    home.configFile."wlogout/layout".text = '''
      {
        "label" : "lock",
        "action" : "hyprlock",
        "text" : "󰌾",
        "keybind" : ""
      }
      {
        "label" : "logout",
        "action" : "loginctl terminate-user $USER",
        "text" : "󰗽",
        "keybind" : ""
      }
      {
        "label" : "shutdown",
        "action" : "systemctl poweroff",
        "text" : "󰐥",
        "keybind" : ""
      }
      {
        "label" : "reboot",
        "action" : "systemctl reboot",
        "text" : "󰑓",
        "keybind" : ""
      }
    ''';
  };
}
