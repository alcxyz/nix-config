# modules/home-manager/services/swww/default.nix
{
  options,
  config,
  pkgs,
  lib,
  inputs, # Unused in this snippet, can be removed if not used elsewhere in the file
  ...
}:
with lib;
let
  cfg = config.services.swww.managed;

  wallpaperScriptPkg = pkgs.writeShellScriptBin "wallpaper" ''
    #!${pkgs.stdenv.shell}
    export PATH="${lib.getBin pkgs.swww}/bin:${lib.getBin pkgs.coreutils}/bin:$PATH"

    if ! swww query >/dev/null 2>&1; then
      echo "Initializing SWWW daemon..."
      swww init >/dev/null 2>&1
      sleep 0.5
      if ! swww query >/dev/null 2>&1; then
        echo "Failed to initialize SWWW daemon." >&2
        exit 1
      fi
    fi

    WALLPAPER_DIR="${config.xdg.configHome or (config.home.homeDirectory + "/.config")}/wallpapers"

    if [ ! -d "$WALLPAPER_DIR" ]; then
      echo "Wallpaper directory $WALLPAPER_DIR not found." >&2
      exit 1
    fi

    # MODIFIED LINE: Added -L to find to dereference symlinks
    wallpaper_file=$(${pkgs.findutils}/bin/find -L "$WALLPAPER_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' \) -print0 | \
      ${pkgs.coreutils}/bin/shuf -zn1 | ${pkgs.coreutils}/bin/tr -d '\0')
    # Added -maxdepth 1 to prevent find from descending into subdirectories if any symlinks point to directories.
    # If you want to search subdirectories, remove -maxdepth 1.

    if [ -n "$wallpaper_file" ]; then
      echo "Setting wallpaper to $wallpaper_file"
      swww img "$wallpaper_file" --transition-fps 60 --transition-type any --transition-duration 1
    else
      echo "No valid wallpaper files (or symlinks to files) found in $WALLPAPER_DIR" >&2 # Clarified message
      exit 1
    fi
  '';

in
{
  options.services.swww.managed = {
    enable = mkEnableOption "SWWW wallpaper daemon and script"; # Clarified option description

    # Options for the systemd user service
    systemd = {
      enable = mkEnableOption "systemd user service to run wallpaper script on session start";
      # You could add more options here later, e.g., to customize transitions for the service
      # transitionType = mkOption {
      #   type = types.str;
      #   default = "any";
      #   description = "Transition type for the initial wallpaper set by the service.";
      # };
    };
  };

  config = mkIf cfg.enable {
    # Install swww and the wallpaper script
    home.packages = [
      pkgs.swww
      wallpaperScriptPkg # Add the script package
    ];

    # Systemd User Service definition
    systemd.user.services.swww-wallpaper = mkIf cfg.systemd.enable {
      Unit = {
        Description = "SWWW Initial Wallpaper Setter";
        # Documentation = "man:swww(1)"; # If swww had a man page
        # Start after the graphical session is mostly ready
        After = [ "graphical-session-pre.target" ];
        PartOf = [ "graphical-session.target" ]; # Tie to graphical session lifecycle
      };

      Service = {
        Type = "oneshot"; # The script runs once and exits
        RemainAfterExit = true; # Keeps the service status "active"

        # Execute the wallpaper script.
        # wallpaperScriptPkg provides the path to the script's directory.
        ExecStart = "${wallpaperScriptPkg}/bin/wallpaper";

        # Optional: Restart if the script fails (e.g., no wallpapers found initially)
        Restart = "on-failure";
        RestartSec = "15s"; # Wait 15 seconds before retrying

        # Environment variables:
        # Home Manager's systemd services usually inherit a good base environment,
        # including XDG_RUNTIME_DIR, DISPLAY, WAYLAND_DISPLAY.
        # XDG_CONFIG_HOME should also be available from the user session.
        # If not, you might need to pass them explicitly:
        # Environment = [
        #   "XDG_CONFIG_HOME=${config.xdg.configHome or (config.home.homeDirectory + "/.config")}"
        #   "PATH=${config.home.profileDirectory}/bin:${pkgs.swww}/bin:${pkgs.coreutils}/bin:/run/current-system/sw/bin" # Example
        # ];
        # However, the script itself sets its PATH, which is good.
      };

      Install = {
        WantedBy = [ "graphical-session.target" ]; # Start when graphical session begins
      };
    };
  };
}
