{
  options,
  config,
  pkgs,
  lib,
  inputs, # Added inputs for consistency, may be used later
  ...
}:
with lib;

let
  # Use the enable flag defined in the parent hyprland module
  cfg = config.services.swww; # Updated path
in
{
  # The option 'options.services.swww.enable' will be defined in 
  # a new or existing services aggregator module (e.g. modules/home-manager/services/default.nix)

  config = mkIf cfg.enable {
    # Ensure swww package and the wallpaper script are available if this module is enabled.
    # home.packages is a list that Home Manager automatically merges across modules.
    home.packages = [ 
      pkgs.swww 
      (pkgs.writeShellScriptBin "wallpaper" '''
        #!${pkgs.stdenv.shell}
        # Ensure swww is in the user's PATH when this script runs
        # Using getBin to robustly get the path to the swww binary package.
        export PATH="${lib.getBin pkgs.swww}/bin:$PATH"
        
        # Initialize swww if it's not running
        swww query >/dev/null 2>&1 || swww init >/dev/null 2>&1
        
        # Define the wallpaper directory. 
        # Consider making this configurable via an option if it changes.
        # Using xdg.configHome if available, otherwise a default.
        WALLPAPER_DIR="${config.xdg.configHome or (config.home.homeDirectory + "/.config")}/wallpapers"

        if [ ! -d "$WALLPAPER_DIR" ]; then
          echo "Wallpaper directory $WALLPAPER_DIR not found." >&2
          exit 1
        fi

        # Find a random wallpaper file using find for robustness
        wallpaper_file=$(find "$WALLPAPER_DIR" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0 | \
          ${pkgs.gnugrep}/bin/grep -zZ -E '' | \
          ${pkgs.gawk}/bin/awk 'BEGIN{RS=" "; srand()} {printf "%.0f	%s ", rand()*1000000, $0}' | \
          ${pkgs.gnusort}/bin/sort -znk1,1 | \
          ${pkgs.gawk}/bin/awk -F'	' 'BEGIN{RS=" "} {print $2; exit}')

        if [ -n "$wallpaper_file" ]; then
          swww img "$wallpaper_file" --transition-fps 60 --transition-type any --transition-duration 1
          echo "Set wallpaper to $wallpaper_file"
        else
          echo "No wallpapers found in $WALLPAPER_DIR" >&2
        fi
      ''')
    ];

    # If you want SWWW to be started automatically by Hyprland, 
    # you would typically add something like this to your Hyprland config's startup execs:
    # exec-once = swww init
    # exec-once = wallpaper # (to set an initial wallpaper using your script)
    # This would be in modules/home-manager/programs/hyprland/hyprland.conf or a startup script.
  };
}
