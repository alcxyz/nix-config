{
  config
, lib
, pkgs
, inputs
, ...
}:
with lib;

let
  # Depend on the parent desktop.hyprland.enable option
  parentCfg = config.desktop.hyprland;
  colorscheme = inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme};
  colors = colorscheme.palette;
in
{
  # This module configures wlogout when the Hyprland desktop suite is enabled.
  # It does not define its own enable option.

  config = mkIf parentCfg.enable {
    # wlogout package should be installed at the system level (already added).
    # environment.systemPackages = [ pkgs.wlogout ];

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