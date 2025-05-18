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
  cfg = config.services.swww;
in
{
  options.services.swww = {
    enable = mkEnableOption "SWWW wallpaper daemon";
  };

  config = mkIf cfg.enable {
    home.packages = [ 
      pkgs.swww 
      (pkgs.writeShellScriptBin "wallpaper" '''
        #!${pkgs.stdenv.shell}
        export PATH="${lib.getBin pkgs.swww}/bin:$PATH"
        swww query >/dev/null 2>&1 || swww init >/dev/null 2>&1
        WALLPAPER_DIR="${config.xdg.configHome or (config.home.homeDirectory + "/.config")}/wallpapers"
        if [ ! -d "$WALLPAPER_DIR" ]; then
          echo "Wallpaper directory $WALLPAPER_DIR not found." >&2
          exit 1
        fi
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
  };
}
