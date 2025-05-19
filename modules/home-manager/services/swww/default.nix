{
  options,
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
with lib;

let
  cfg = config.services.swww.managed;
in
{
  options.services.swww.managed = {
    enable = mkEnableOption "SWWW wallpaper daemon";
  };

  config = mkIf cfg.enable {
    home.packages = [ 
      pkgs.swww 
      
      (pkgs.writeShellScriptBin "wallpaper" ''
        #!${pkgs.stdenv.shell}
        # Ensure coreutils is in PATH if shuf is used
        export PATH="${lib.getBin pkgs.swww}/bin:${lib.getBin pkgs.coreutils}/bin:$PATH"
        swww query >/dev/null 2>&1 || swww init >/dev/null 2>&1
        WALLPAPER_DIR="${config.xdg.configHome or (config.home.homeDirectory + "/.config")}/wallpapers"

        if [ ! -d "$WALLPAPER_DIR" ]; then
          echo "Wallpaper directory $WALLPAPER_DIR not found." >&2
          exit 1
        fi

        wallpaper_file=$(${pkgs.findutils}/bin/find "$WALLPAPER_DIR" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0 | \
          ${pkgs.coreutils}/bin/shuf -zn1 | ${pkgs.coreutils}/bin/tr -d '\0')
        # shuf -zn1 outputs one random NUL-terminated filename.
        # tr -d '\0' removes the NUL character for safer assignment to the shell variable.

        if [ -n "$wallpaper_file" ]; then
          swww img "$wallpaper_file" --transition-fps 60 --transition-type any --transition-duration 1
          echo "Set wallpaper to $wallpaper_file"
        else
          echo "No wallpapers found in $WALLPAPER_DIR" >&2
          exit 1 # It's good practice to exit with an error if no wallpaper is found
        fi
      '')

    ];
  };
}
