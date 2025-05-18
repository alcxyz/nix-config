{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib;

let
  # Use the specific enable flag for wlogout from the parent hyprland module
  cfg = config.desktop.hyprland.wlogout; 
  colorscheme = inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme};
  colors = colorscheme.palette;
in
{
  # The option 'options.desktop.hyprland.wlogout.enable' is defined in 
  # modules/home-manager/desktop/hyprland/default.nix

  config = mkIf cfg.enable { // This now correctly uses config.desktop.hyprland.wlogout.enable
    # Enable the core Home Manager wlogout program if it exists,
    # or add the package to home.packages.
    # Wlogout has a home-manager module: programs.wlogout
    programs.wlogout.enable = true; 

    # Configure wlogout configuration files via Home Manager
    home.configFile."wlogout/style.css".text = ''
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

    home.configFile."wlogout/layout".text = ''
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
