{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hardware.displayDeviceGuard;
  displayDevice = "/dev/dri/${cfg.deviceName}";
  vendor = lib.toLower (builtins.substring 0 4 cfg.pciId);
  device = lib.toLower (builtins.substring 5 4 cfg.pciId);
in {
  options.hardware.displayDeviceGuard = {
    enable = lib.mkEnableOption "a stable DRM device alias and display startup guard";
    pciAddress = lib.mkOption {
      type = lib.types.strMatching "[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\\.[0-7]";
      description = "PCI address of the display device.";
    };
    pciId = lib.mkOption {
      type = lib.types.strMatching "[0-9A-F]{4}:[0-9A-F]{4}";
      description = "Uppercase PCI vendor and device identifier.";
    };
    driver = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9_-]+";
      description = "Kernel driver required for the selected device.";
    };
    deviceName = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9_-]+";
      description = "Stable device alias created under /dev/dri.";
    };
    deviceDescription = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9 _-]+";
      default = "selected display device";
      description = "Human-readable device description used in diagnostics.";
    };
    requiredBy = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Services that must wait for successful device verification.";
    };
  };
  config = lib.mkIf cfg.enable {
    services.udev.extraRules = ''
      SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DEVPATH=="*/${cfg.pciAddress}/drm/card[0-9]*", ATTRS{vendor}=="0x${vendor}", ATTRS{device}=="0x${device}", DRIVERS=="${cfg.driver}", SYMLINK+="dri/${cfg.deviceName}"
    '';
    systemd.services.gpu-display-guard = {
      description = "Verify the display compositor is pinned to the ${cfg.deviceDescription}";
      requiredBy = cfg.requiredBy;
      before = cfg.requiredBy;
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail

        ${pkgs.systemd}/bin/udevadm settle --timeout=10

        if [ ! -e ${displayDevice} ]; then
          echo "Missing ${displayDevice}; expected ${cfg.deviceDescription} at PCI ${cfg.pciAddress}" >&2
          exit 1
        fi

        resolved="$(${pkgs.coreutils}/bin/readlink -f ${displayDevice})"
        card="$(${pkgs.coreutils}/bin/basename "$resolved")"
        uevent="/sys/class/drm/$card/device/uevent"

        if ! ${pkgs.gnugrep}/bin/grep -qx "PCI_SLOT_NAME=${cfg.pciAddress}" "$uevent"; then
          echo "${displayDevice} resolves to $resolved, not PCI ${cfg.pciAddress}" >&2
          exit 1
        fi

        if ! ${pkgs.gnugrep}/bin/grep -qx "PCI_ID=${cfg.pciId}" "$uevent"; then
          echo "${displayDevice} resolves to $resolved, not PCI ID ${cfg.pciId}" >&2
          exit 1
        fi

        if ! ${pkgs.gnugrep}/bin/grep -qx "DRIVER=${cfg.driver}" "$uevent"; then
          echo "${displayDevice} resolves to $resolved, but it is not bound to ${cfg.driver}" >&2
          exit 1
        fi
      '';
    };
  };
}
