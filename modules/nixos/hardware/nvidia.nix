# nix-config/modules/nixos/hardware/nvidia.nix
{
  options,
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.hardware.nvidia;
in {
  options.hardware.nvidia.enable = mkEnableOption "Nvidia Hardware Support";

  config = mkIf cfg.enable {
    services.xserver.videoDrivers = ["nvidia"];

    hardware.nvidia = {
      modesetting.enable = true;
      open = false;
      nvidiaSettings = true;
      # patchelf 0.19.2 breaks non-PIE binaries when one call sets both the
      # interpreter and the rpath: nvidia-smi then segfaults in the loader
      # (NixOS/nixpkgs#576412). Re-patch the untouched origBin copies in two
      # calls, as NixOS/nixpkgs#576397 does; drop this once the nixpkgs pin
      # includes that fix.
      package = config.boot.kernelPackages.nvidiaPackages.legacy_580.overrideAttrs (old: {
        postInstall =
          toString (old.postInstall or "")
          + ''
            if [ -n "''${bin:-}" ] && [ -d "$bin/origBin" ]; then
              for i in "$bin"/origBin/*; do
                n=$(basename "$i")
                install -m755 "$i" "$bin/bin/$n"
                patchelf --set-rpath "$out/lib:$libPath" "$bin/bin/$n"
                patchelf --interpreter "$(cat "$NIX_CC/nix-support/dynamic-linker")" "$bin/bin/$n"
              done
            fi
          '';
      });
    };

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [libva-utils egl-wayland nvidia-vaapi-driver];
    };

    boot.kernelParams = ["nvidia-drm.modeset=1" "nvidia-drm.fbdev=1"];
  };
}
