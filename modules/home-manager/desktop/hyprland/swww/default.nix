{
  options
, config
, pkgs
, lib
, ...
}:
with lib;

let
  cfg = config.programs.swww; # Use programs.swww as the option path
in
{
  options.programs.swww = with types; { # Define programs.swww.enable
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the Home Manager configuration for SWWW.";
    };
  };

  config = mkIf cfg.enable {
    # SWWW package should be installed at the system level.
    # environment.systemPackages = [ pkgs.swww ];

    # Install the custom wallpaper script at the user level
    home.packages = [
      (pkgs.writeShellScriptBin "wallpaper" ''
        # Ensure swww is in the user's path when this script runs
        ${pkgs.swww}/bin/swww query || ${pkgs.swww}/bin/swww init
        ${pkgs.coreutils}/bin/ls ~/.config/wallpapers/ | ${pkgs.gnugrep}/bin/grep -E '\.png$|\.jpg$|\.jpeg$' | ${pkgs.coreutils}/bin/sort -R | ${pkgs.coreutils}/bin/head -1 |while read file; do
            ${pkgs.swww}/bin/swww img ~/.config/wallpapers/$file --transition-fps 255 --transition-type wipe
            echo "$file"
        done
      '')
    ];

    # Uncomment the following block if you want Home Manager to manage the persistence of the SWWW cache directory
    # home.persist.directories = [
    #   ".cache/swww"
    # ];
  };
}