{
  config,
  pkgs,
  inputs,
  username,
  hostName,
  hostRole,
  configDir,
  lib,
  ...
}:
let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };

  amdDisplayPci = "0000:79:00.0";
  amdDisplayPciId = "1002:13C0";
  amdDisplayDrmDevice = "/dev/dri/amd-display-card";

  hyprPluginPkgs = inputs.hyprland-plugins.packages.${pkgs.stdenv.hostPlatform.system};
  hyprPluginDir = pkgs.symlinkJoin {
    name = "hyprland-plugins";
    paths = with hyprPluginPkgs; [ ];
  };
in
{
  # ==================== Users ====================
  users.users.${username} = {
    extraGroups = [
      "vfio"
      "video"
    ];
  };

  services.accounts-daemon.enable = true;

  system.activationScripts.accountsServiceProfileIcon.text = ''
    icon_target="/var/lib/AccountsService/icons/${username}"
    user_target="/var/lib/AccountsService/users/${username}"

    install -Dm0644 "${configDir}/users/${username}/profile.jpg" "$icon_target"
    install -d -m 0700 /var/lib/AccountsService/users

    tmp="$(mktemp)"
    if [ -f "$user_target" ]; then
      cp "$user_target" "$tmp"
      if ${pkgs.gnugrep}/bin/grep -q '^Icon=' "$tmp"; then
        ${pkgs.gnused}/bin/sed -i "s|^Icon=.*|Icon=$icon_target|" "$tmp"
      elif ${pkgs.gnugrep}/bin/grep -q '^\[User\]' "$tmp"; then
        ${pkgs.gnused}/bin/sed -i "/^\[User\]/a Icon=$icon_target" "$tmp"
      else
        {
          printf '[User]\n'
          printf 'Icon=%s\n' "$icon_target"
          cat "$tmp"
        } > "$tmp.new"
        mv "$tmp.new" "$tmp"
      fi
    else
      {
        printf '[User]\n'
        printf 'Icon=%s\n' "$icon_target"
      } > "$tmp"
    fi

    install -m 0600 "$tmp" "$user_target"
    rm -f "$tmp"
  '';

  # ==================== System Packages ====================
  environment.systemPackages = pkgsets.system.${hostRole.systemPackageSet};

  environment.sessionVariables = {
    HYPR_PLUGIN_DIR = "${hyprPluginDir}";

    # Force Hyprland to use only the AMD DRM device. This udev-created name is
    # bound to the AMD iGPU PCI slot, vendor/device ID, and driver; never to
    # /dev/dri/card* order.
    AQ_DRM_DEVICES = amdDisplayDrmDevice;

    # Force Mesa userspace (avoid GLVND picking NVIDIA)
    __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json";
    __GLX_VENDOR_LIBRARY_NAME = "mesa";
    LIBVA_DRIVER_NAME = "radeonsi";
  };

  environment.etc."fuse.conf".text = ''
    user_allow_other
  '';

  boot.supportedFilesystems.ntfs = true;

  # ==================== Emulation (for aarch64 remote builds) ====================
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # ==================== Hardware ====================
  hardware.nvidia.enable = true;
  hardware.amd.enable = true;
  hardware.enableRedistributableFirmware = true;

  services.udev.extraRules = ''
    SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DEVPATH=="*/${amdDisplayPci}/drm/card[0-9]*", ATTRS{vendor}=="0x1002", ATTRS{device}=="0x13c0", DRIVERS=="amdgpu", SYMLINK+="dri/amd-display-card"
  '';

  # ==================== Security & PAM ====================
  security.pam.services = {
    login.u2fAuth = true;
    sudo.u2fAuth = true;
  };

  # ==================== Desktop Environment ====================
  services.xserver.enable = true;

  #services.displayManager.gdm.enable = true;

  # Disable GDM
  services.displayManager.gdm.enable = false;

  # Enable greetd
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        # Use tuigreet (a TTY-based greeter)
        #command = "bash -l -c '${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd \"uwsm start hyprland-uwsm.desktop\"'";
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --sessions /run/current-system/sw/share/wayland-sessions";
        user = "greeter";
      };
    };
  };

  systemd.services.gpu-display-guard = {
    description = "Verify the display compositor is pinned to the AMD iGPU";
    requiredBy = [ "greetd.service" ];
    before = [ "greetd.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail

      ${pkgs.systemd}/bin/udevadm settle --timeout=10

      if [ ! -e ${amdDisplayDrmDevice} ]; then
        echo "Missing ${amdDisplayDrmDevice}; expected AMD iGPU at PCI ${amdDisplayPci}" >&2
        exit 1
      fi

      resolved="$(${pkgs.coreutils}/bin/readlink -f ${amdDisplayDrmDevice})"
      card="$(${pkgs.coreutils}/bin/basename "$resolved")"
      uevent="/sys/class/drm/$card/device/uevent"

      if ! ${pkgs.gnugrep}/bin/grep -qx "PCI_SLOT_NAME=${amdDisplayPci}" "$uevent"; then
        echo "${amdDisplayDrmDevice} resolves to $resolved, not PCI ${amdDisplayPci}" >&2
        exit 1
      fi

      if ! ${pkgs.gnugrep}/bin/grep -qx "PCI_ID=${amdDisplayPciId}" "$uevent"; then
        echo "${amdDisplayDrmDevice} resolves to $resolved, not PCI ID ${amdDisplayPciId}" >&2
        exit 1
      fi

      if ! ${pkgs.gnugrep}/bin/grep -qx "DRIVER=amdgpu" "$uevent"; then
        echo "${amdDisplayDrmDevice} resolves to $resolved, but it is not bound to amdgpu" >&2
        exit 1
      fi
    '';
  };

  # Ensure TTYs are handled correctly for tuigreet
  systemd.services.greetd.serviceConfig = {
    Type = "idle";
    StandardInput = "tty";
    StandardOutput = "tty";
    StandardError = "journal";
    TTYReset = true;
    TTYVHangup = true;
    TTYVTDisallocate = true;
  };

  /*
    programs.dankMaterialShell.greeter = {
      enable = true;
      compositor.name = "hyprland";
      configHome = "/home/${username}";
      logs = {
        save = true;
        path = "/tmp/dms-greeter.log";
      };
      quickshell.package = inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default;
    };
  */

  programs.niri.enable = true;
  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true;
    #package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    #portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
  };

  services.gnome.sushi.enable = true;
  services.udisks2.enable = true;
  services.gvfs.enable = true;
  security.polkit.enable = true;
  # DMS provides the graphical authentication agent, but pkexec still needs
  # the privileged NixOS wrapper to hand approved commands to Polkit.
  security.wrappers.pkexec.enable = lib.mkForce true;
  programs.dconf.enable = true;

  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [ xdg-desktop-portal-gtk ];
    config.common.default = [ "gtk" ];
    config.hyprland.default = [
      "hyprland"
      "gtk"
    ];
    xdgOpenUsePortal = true;
  };

  # ==================== Services ====================

  # GPU runtime
  hardware.nvidia-container-toolkit.enable = true;
  # This oneshot uses NVML and fails during live switches when the NVIDIA
  # userspace package changes but the old kernel module is still loaded.
  # Let it regenerate CDI specs on boot, after the matching module is loaded.
  systemd.services.nvidia-container-toolkit-cdi-generator.restartIfChanged = false;

  # ==================== Keyboard Remapping ====================
  services.kanata = {
    enable = true;
    package = pkgs.kanata;
    keyboards.main = {
      configFile = "${configDir}/users/${username}/configs/kanata/kanata.kbd";
    };
  };
  systemd.services.kanata-main.serviceConfig = {
    Restart = "on-failure";
    RestartSec = "2s";
  };

  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      log-driver = "journald";
      features = {
        cdi = true;
      };
    };
  };
}
