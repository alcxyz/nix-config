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
in
{
  options.programs.wlogout.managed = {
    enable = mkEnableOption "wlogout session exit UI";
  };

  config = mkIf cfg.enable {
    programs.wlogout.enable = true; 

    xdg.configFile."wlogout/style.css".text = ''
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
    '';

    xdg.configFile."wlogout/layout".text = ''
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
    '';
  };
}
