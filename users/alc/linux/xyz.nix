# users/alc/linux/xyz.nix
{
  config,
  pkgs,
  lib,
  inputs,
  configDir,
  hostRole,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
  kdeConnectScrollThrottle =
    pkgs.callPackage "${configDir}/modules/nixos/services/kdeconnect-scroll-throttle" {};
  xwaylandPrimaryOutput = pkgs.writeShellApplication {
    name = "hyprland-xwayland-primary-output";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.xrandr
    ];
    text = ''
      for _ in $(seq 1 120); do
        if DISPLAY="''${DISPLAY:-:0}" xrandr --output DP-1 --primary >/dev/null 2>&1; then
          exit 0
        fi
        sleep 0.25
      done

      echo "Failed to mark DP-1 as the XWayland primary output" >&2
      exit 1
    '';
  };
in {
  # Import the common Linux configuration
  imports = [
    "${configDir}/users/alc/linux/operator.nix"

    "${configDir}/modules/home-manager/programs/wayland-common/default.nix"
    "${configDir}/modules/home-manager/programs/hyprland/default.nix"
    "${configDir}/modules/home-manager/programs/niri/default.nix"
    "${configDir}/modules/home-manager/services/dms/default.nix"
    "${configDir}/modules/home-manager/services/hyprlock/default.nix"
    "${configDir}/modules/home-manager/services/waynergy/default.nix"
    "${configDir}/modules/home-manager/programs/foot/default.nix"

    "${configDir}/modules/home-manager/programs/rclone/cloud-sync.nix"

    "${configDir}/modules/home-manager/programs/ai/default.nix"
    "${configDir}/modules/home-manager/programs/moonlight-wolf-client/default.nix"
    "${configDir}/modules/home-manager/programs/stashdb-pop/default.nix"

    "${configDir}/modules/home-manager/services/paperflow/default.nix"
    "${configDir}/modules/home-manager/services/paperless-filetype-index/default.nix"
    "${configDir}/modules/home-manager/services/devlog/default.nix"
    "${configDir}/modules/home-manager/services/t3code/default.nix"

    inputs.hyprscratch.homeModules.default
  ];

  # ==================== XYZ-Specific Settings ====================

  home.packages =
    pkgsets.home.${hostRole.homePackageSet}
    ++ [
      pkgs.paperweight
    ];

  # Keep launchers with cached pre-0.0.32 desktop commands working after the
  # upstream executable was renamed from t3code to t3code-desktop. DMS stores
  # the old arguments in its usage history, so discard the obsolete sandbox
  # flag and any unexpanded desktop-entry URL placeholders.
  home.file.".local/bin/t3code" = {
    executable = true;
    text = ''
      #!${pkgs.runtimeShell}
      filtered=()
      for arg in "$@"; do
        case "$arg" in
          --no-sandbox|%u|%U) ;;
          *) filtered+=("$arg") ;;
        esac
      done
      exec ${pkgs.t3code}/bin/t3code-desktop "''${filtered[@]}"
    '';
  };

  # DMS can retain the package entry's former bare command across upgrades.
  # Prefer a user entry with an immutable executable path.
  xdg.desktopEntries.t3code = {
    name = "T3 Code (Alpha)";
    comment = "Minimal web GUI for coding agents";
    icon = "t3code";
    # T3 Code does not currently consume files or URLs, and DMS can pass an
    # unexpanded %U placeholder through as an application argument.
    exec = "${pkgs.t3code}/bin/t3code-desktop";
    categories = ["Development"];
    settings.TryExec = "${pkgs.t3code}/bin/t3code-desktop";
  };

  # Symlink configs directly to repo checkout for live editing
  xdg.configFile."ncspot/config.toml".source =
    config.lib.file.mkOutOfStoreSymlink "${configDir}/users/alc/configs/ncspot/config.toml";

  # XYZ-specific aliases
  home.shellAliases = {
    pbcopy = "wl-copy";
    pbpaste = "wl-paste";
    # Single-layer remote rebuilds (deploy <host> does both)
    nxsw-nux = "deploy --nixos nux";
    nxsw-nex = "deploy --nixos nex";
    nxsw-rpi0 = "deploy --nixos rpi0";
    hmsw-nux = "deploy --hm nux";
    hmsw-nex = "deploy --hm nex";
    hmsw-rpi0 = "deploy --hm rpi0";
  };

  # Enable XYZ-specific programs
  programs.foot.enable = true;
  programs.hyprland.managed = {
    enable = true;
    # Match the qualified couch cursor policy. KDE Connect and other absolute
    # pointer paths can be classified as touch input by the compositor, even
    # though they are used as mice inside a windowed Moonlight stream.
    remotePointerInactiveTimeout = 8;
    remotePointerHideOnTouch = false;
    extraConfig = ''
      # Center the secondary display above the primary ultrawide. Its EDID
      # omits 1440p, so use a CVT reduced-blanking modeline to keep the iGPU's
      # compositing load below the native 4K mode. The small logical gap acts
      # as a soft pointer barrier for the auto-hiding bar: precise movement
      # stops at the bar while a deliberate upward movement still crosses.
      monitor = DP-1, 5120x1440@120, 0x1456, 1
      monitor = HDMI-A-1, modeline 241.50 2560 2608 2640 2720 1440 1443 1448 1481 +hsync -vsync, 1280x0, 1

      # `exec-once` does not run when Home Manager reloads Hyprland in an
      # existing session, leaving XWayland without a primary output until the
      # next login. Reassert it on reload as well as at session startup.
      exec = ${lib.getExe xwaylandPrimaryOutput}
      bind = CTRL SHIFT, R, exec, moonlight-wolf-ui-lan
    '';
  };
  programs.niri.managed.enable = true;
  programs.moonlightWolfClient.enable = true;

  programs.hyprscratch = {
    enable = true;
    settings = {
      daemon_options = "clean";

      dropterm = {
        title = "dropterm";
        command = "foot -w 2400x1400 --app-id dropterm --title dropterm";
        rules = "float; center";
        options = "persist";
      };
    };
  };

  services.dms.enable = true;
  services.dms.settings = {
    audioVisualizerEnabled = false;
    scrollTitleEnabled = false;
    waveProgressEnabled = false;
  };
  services.dms.idleLock = {
    enable = true;
    command = config.services.hyprlock.lockCommand;
    acMonitorTimeout = 360;
    batteryMonitorTimeout = 0;
    respectExternalInhibitors = true;
  };
  services.dms.pluginSettings.dankAIUsage.enabled = true;
  services.hyprlock = {
    enable = true;
    turnOffDisplaysOnLock = true;
    displayOffDelay = 360;
  };
  services.waynergy = {
    enable = true;
    screenName = "xyz";
    sourceKeyboard = "mac";
    requireLanAddress = true;
  };
  services.kdeconnect.enable = true;
  # Hyprland's portal does not provide RemoteDesktop. Run KDE Connect through
  # XWayland so phone pointer and keyboard events use XTest instead of evdev;
  # this also keeps them entirely outside Kanata's device-grab path.
  systemd.user.services.kdeconnect.Service = let
    defaults = import "${configDir}/modules/shared/kdeconnect-input.nix";
    hyprlandInput =
      pkgs.callPackage "${configDir}/modules/nixos/services/kdeconnect-hyprland-input" {};
  in {
    Type = "dbus";
    BusName = "org.kde.kdeconnect";
    Environment = [
      "QT_QPA_PLATFORM=xcb"
      "KDECONNECT_SCROLL_INTERVAL_MS=${toString defaults.scrollIntervalMs}"
      "KDECONNECT_POINTER_SENSITIVITY=${toString defaults.pointerSensitivity}"
      "KDECONNECT_POINTER_PRECISION_SENSITIVITY=${toString defaults.pointerPrecisionSensitivity}"
      "KDECONNECT_POINTER_ACCELERATION_START=${toString defaults.pointerAccelerationStart}"
      "KDECONNECT_POINTER_ACCELERATION_FULL=${toString defaults.pointerAccelerationFull}"
      "LD_PRELOAD=${hyprlandInput}/lib/libkdeconnect-hypr-pointer-shim.so"
    ];
    Restart = lib.mkForce "on-failure";
  };
  systemd.user.services.kdeconnect-hypr-pointer = let
    hyprlandInput =
      pkgs.callPackage "${configDir}/modules/nixos/services/kdeconnect-hyprland-input" {};
  in {
    Unit = {
      Description = "KDE Connect Hyprland pointer bridge";
    };
    Service = {
      ExecStart = lib.getExe hyprlandInput;
      Restart = "always";
      RestartSec = 1;
    };
    Install.WantedBy = ["default.target"];
  };
  # The package's stock D-Bus service starts a second unmanaged daemon. Route
  # activation to the supervised XWayland unit instead.
  xdg.dataFile."dbus-1/services/org.kde.kdeconnect.service".text = ''
    [D-BUS Service]
    Name=org.kde.kdeconnect
    Exec=${pkgs.systemd}/bin/systemctl --user start kdeconnect.service
    SystemdService=kdeconnect.service
  '';
  services.udiskie = {
    enable = true;
    tray = "never";
  };
  systemd.user.services.udiskie = {
    Unit = {
      After = lib.mkForce [];
      PartOf = lib.mkForce [];
    };
    Install.WantedBy = lib.mkForce ["default.target"];
  };

  services.devlog.enable = true;
  services.devlog.weekly.enable = true;

  services.t3code.enable = false;
  services.t3code.port = 3773;

  programs.ai.enable = true;
  programs.stashdb-pop.enable = true;

  services.cloud-sync = {
    enable = true;
    syncInterval = "15m";

    googleDrive = {
      enable = true;
      remote = "gdrive";
      localPath = "${config.home.homeDirectory}/Cloud/GoogleDrive";
    };

    dropbox = {
      enable = true;
      remote = "dropbox";
      localPath = "${config.home.homeDirectory}/Cloud/Dropbox";
    };
  };
}
