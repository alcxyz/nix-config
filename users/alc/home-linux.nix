# users/alc/home-linux.nix
{
  config,
  pkgs,
  lib,
  username,
  inputs,
  hostName,
  ...
}:

with lib;

{
  imports = [
    ./common.nix # <--- Import the common configuration first

    # Linux-specific imports (Hyprland, Waybar, etc.)
    ../../modules/home-manager/programs/foot/default.nix
    ../../modules/home-manager/programs/hyprland/default.nix
    ../../modules/home-manager/programs/waybar/default.nix
    ../../modules/home-manager/programs/wofi/default.nix
    ../../modules/home-manager/programs/wlogout/default.nix
    ../../modules/home-manager/services/swww/default.nix
    ../../modules/home-manager/services/hypridle/default.nix
    ../../modules/home-manager/services/hyprlock/default.nix

    ../../modules/home-manager/suites/gaming/default.nix
  ];

  # ==================== Linux-Specific Options ====================
  # No need for home.username, home.homeDirectory, colorscheme, etc., as they are in common.nix
  # home.stateVersion is also in common.nix

  # Linux-specific packages
  home.packages = with pkgs; [
    #wl-clipboard # For Wayland clipboard
    #xclip        # For X11 clipboard
    nitch
  ];

  programs.atuin.daemon.enable = true; # Enable Atuin daemon on Linux

  # This is the Linux-specific part of extraConfig.
  # It will be concatenated AFTER the common part from shell/default.nix.
  programs.nushell.extraConfig = ''
    # --- Linux-Specific Nushell Additions (Part 2) ---
    # (No specific PATH modifications needed for Linux beyond common, usually)

    # Linux clipboard helper
    #def clipboard [action: string] {
    #    if $action == "copy" {
    #        if (which wl-copy | is-not-empty) { wl-copy }
    #        else if (which xclip | is-not-empty) { xclip -selection clipboard }
    #        else { print "Error: No clipboard tool (wl-copy or xclip) found for copy." }
    #    } else if $action == "paste" {
    #        if (which wl-paste | is-not-empty) { wl-paste }
    #        else if (which xclip | is-not-empty) { xclip -selection clipboard -o }
    #        else { print "Error: No clipboard tool (wl-paste or xclip) found for paste." }
    #    } else { print "Usage: clipboard <copy|paste>" }
    #}
    # --- End Linux-Specific Nushell Additions (Part 2) ---
  '';

  home.shellAliases = {
    pbcopy = "clipboard copy";
    pbpaste = "clipboard paste";
  };

  home.file.".config/wallpapers" = { # This is Linux-specific if you use it for Wayland
    source = ./wallpapers; # Relative to users/alc/
    recursive = true;
  };

  # Enable Linux-specific programs

  # Deploy SSH key pair using the convenience option
  secrets.ssh.keyPair = 
    if hostName == "xyz" then {
      enable = true;
      baseName = "xyz_id_ed25519";
      forceRefresh = false;
      # Uses default file names: id_ed25519 and id_ed25519.pub
    } else if hostName == "nuc" then {
      enable = true;
      baseName = "nuc_id_ed25519";
      forceRefresh = false;
    } else {
      enable = false;
    };

  # Configure git signing key to use the deployed public key
  programs.git.managed = {
    signingKey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
    
    # You can also set up conditional configs for different projects if needed
    conditionalSigningConfigs = {
      # Example: Use a different key for work projects
      # "gitdir:~/work/" = {
      #   "user.signingkey" = "${config.home.homeDirectory}/.ssh/id_work.pub";
      # };
    };
  };

  programs.chromium.enable = true;
  programs.foot.enable = true;
  programs.hyprland.managed.enable = true;

  programs.waybar.managed = {
    enable = true;
    #variant = "alternative";
  };

  programs.wofi.managed.enable = true;

  programs.wlogout.managed = {
    enable = true;
    #style = "enhanced";
  };

  services.swww.managed = {
    enable = true;
    systemd.enable = true;
  };

  services.hypridle.managed.enable = true;
  services.hyprlock.enable = true;
  services.hyprlock.wallpaper.useStandardDir = true;
  services.gpg-agent.pinentry.package = pkgs.pinentry-gtk2;

  suites.gaming = {
    enable = true;
    gamingWorkspace = "1";
    hostBypassApps = [ "zen" "brave" "firefox" "spotify" "discord" "vlc" ];
  };

}
