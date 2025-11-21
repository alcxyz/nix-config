{
  options,
  config,
  lib,
  pkgs,
  pkgs-unstable,
  inputs,
  ...
}:
with lib;
{
  options.suites.wayland-desktop= with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Wayland desktop ecosystem packages";
    };
  };

  config = mkIf config.suites.wayland-desktop.enable {

    environment.systemPackages = with pkgs; [
      waybar
      swww
      wofi
      wlogout
      swayidle
      swaynotificationcenter
      libnotify

      # ndrop from custom-packages flake
      (inputs.custom-packages.packages.${pkgs.system}.ndrop)
      xwayland-satellite

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
    ]

    ++ (with pkgs-unstable; [
      mangowc
    ]);
  };
}
