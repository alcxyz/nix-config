{ options, config, lib, pkgs, inputs, username, ... }: # Added username
with lib;
let
  cfg = config.suites.desktop; # This refers to options.suites.desktop
  # For options defined within *this* module (like desktop.enable, desktop.autoLogin below)
  # we refer to them via config.desktop inside the config block.
  # For options from *other* modules (like config.users.users), we use them directly.

in
{
  # Option for enabling the entire suite
  options.suites.desktop = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the desktop suite configurations.";
    };
  };

  # Options previously in desktop/config.nix, now part of the suite's options
  # We namespace them under 'desktop' to match how they were accessed in the old config.nix
  # (e.g., config.desktop.enable, config.desktop.autoLogin)
  options.desktop = with types; {
    # This 'enable' is for the sub-configurations within the desktop suite, distinct from suites.desktop.enable
    # However, the config block below is already guarded by suites.desktop.enable (cfg.enable)
    # So, we might not strictly need config.desktop.enable if all configs are conditional on suites.desktop.enable
    # For clarity and to match the old structure, let's keep it for now.
    enable = mkOption {
      type = types.bool;
      default = false; # Usually, if suites.desktop.enable is true, this would also be true.
      description = "Enable specific desktop system configurations (services, features).";
    };
    autoLogin = mkOption {
      type = types.bool;
      default = false;
      description = "Enable automatic login for the desktop user.";
    };
  };

  # Removed imports of config.nix and packages.nix

  config = mkIf cfg.enable { # This is suites.desktop.enable
    # === Configurations previously in desktop/config.nix ===
    # The mkIf config.desktop.enable from the old config.nix is implicitly handled
    # if we assume that when suites.desktop.enable is true, then desktop.enable (the inner one) should also be true.
    # Or, we make the options truly independent.
    # For now, let's assume if the suite is on, its main config is on.

    # desktop.hyprland.enable = true; # This seems to be an option path, should be config.desktop.hyprland.enable
                                   # And its option should be defined somewhere, likely in a hyprland module.
                                   # If suites.hyprland.enable exists, this might be redundant or conflicting.
                                   # For now, commenting out as it needs clarification on where this option is defined and its purpose here.

    programs.firefox.enable = true;
    programs.steam.enable = true;
    services.flatpak.enable = true;

    services.xserver = {
      enable = true;
      displayManager.gdm.enable = true;
      desktopManager.gnome.enable = true;
      displayManager.autoLogin = mkIf config.desktop.autoLogin { # Uses options.desktop.autoLogin
        enable = true;
        user = username; # Directly use username passed as specialArg
      };
    };

    # === Packages previously in desktop/packages.nix ===
    environment.systemPackages = with pkgs; [
      inputs.zen-browser.packages.x86_64-linux.default
      brave
      thunderbird
      chromium
      teams-for-linux
      rustdesk
      spotify
      vlc
      obsidian
      obs-studio
      gimp3-with-plugins
      calibre
      cameractrls
      cameractrls-gtk4
      gparted
      discord
      lutris
      winetricks
      wineWowPackages.waylandFull
      ghostty
      nautilus
      grim
      slurp
      swappy
      imagemagick
      (writeShellScriptBin "screenshot" ''
        grim -g "$(slurp)" - | convert - -shave 1x1 PNG:- | wl-copy
      '')
      (writeShellScriptBin "screenshot-edit" ''
        wl-paste | swappy -f -
      '')
      pulseaudio
      git
      git-remote-gcrypt
      gh
      lazygit
      commitizen
    ];
  };
}
