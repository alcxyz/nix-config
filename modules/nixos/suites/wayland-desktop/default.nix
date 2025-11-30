{ options, config, lib, pkgs, inputs, ... }:
with lib;
let
  pkgsets = import ../../../pkgsets.nix { inherit pkgs inputs; };
in {
  options.suites.wayland-desktop = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Wayland desktop ecosystem packages";
    };
  };

  config = mkIf config.suites.wayland-desktop.enable {

    environment.systemPackages = [
        # Keep the helper convenience wrappers local to this module
        (pkgs.writeShellScriptBin "screenshot" ''
          grim -g "$(slurp)" - | ${pkgs.imagemagick}/bin/convert - -shave 1x1 PNG:- | ${pkgs.wl-clipboard}/bin/wl-copy
        '')
        (pkgs.writeShellScriptBin "screenshot-edit" ''
          ${pkgs.wl-clipboard}/bin/wl-paste | ${pkgs.swappy}/bin/swappy -f -
        '')
      ];
  };
}
