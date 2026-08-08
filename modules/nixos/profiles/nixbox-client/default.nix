{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nixbox-client;
in {
  imports = [../nixbox-session/default.nix];

  options.services.nixbox-client = {
    enable = lib.mkEnableOption "a compact controller-first Nixbox streaming client";

    user = lib.mkOption {
      type = lib.types.str;
      description = "Existing user that owns the graphical media session.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.moonlight-v4l2-request;
      defaultText = lib.literalExpression "pkgs.moonlight-v4l2-request";
      description = "Moonlight package used by the compact client.";
    };

    outputMode = lib.mkOption {
      type = lib.types.str;
      default = "1920x1080@60";
      description = "Preferred display mode for the compact client.";
    };

    outputScale = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Hyprland output scale for the compact client.";
    };

    presentationScale = lib.mkOption {
      type = lib.types.float;
      default = 1.5;
      description = ''
        UI and cursor scale requested from local and streamed browser
        presentations without reducing media resolution.
      '';
    };

    enableDms = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the compact DMS shell in the Nixbox session.";
    };

    enableKdeConnect = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable KDE Connect input and the Hyprland pointer bridge.";
    };

    kdeConnectScrollIntervalMs = lib.mkOption {
      type = lib.types.ints.between 0 1000;
      default = 80;
      description = "Minimum interval between KDE Connect wheel steps in milliseconds.";
    };

    enableLocalUtilities = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Keep a local terminal available as a maintenance escape hatch.";
    };

    enablePresentation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the Nixbox graphical-session and power transitions.";
    };

    enableBootSplash = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable the Plymouth Nixbox boot splash. This can be disabled on compact
        devices while retaining compositor-owned session and power animations.
      '';
    };

    moonlightPlatform = lib.mkOption {
      type = lib.types.enum [
        "wayland"
        "xcb"
      ];
      # KDE Connect and Waynergy pointer injection need the same XWayland
      # bridge proven by the full Nixbox client. Video decoding remains in the
      # platform-specific Moonlight package rather than the Qt presentation
      # backend.
      default = "xcb";
      description = "Qt display backend used by Moonlight.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "services.nixbox-client.user must name a declared NixOS user";
      }
    ];

    users.users.${cfg.user}.extraGroups = [
      "input"
      "render"
      "video"
    ];

    hardware.graphics.enable = true;
    hardware.enableRedistributableFirmware = true;

    programs.hyprland = {
      enable = true;
      withUWSM = false;
      xwayland.enable = cfg.moonlightPlatform == "xcb";
    };

    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --sessions /run/current-system/sw/share/wayland-sessions";
        user = "greeter";
      };
    };

    security.polkit = {
      enable = true;
      # DMS supplies the graphical authentication agent. The privileged
      # wrapper is still required for its contextual elevation helper to hand
      # approved commands to Polkit.
      enablePkexecWrapper = true;
    };

    # The document portal and protected-profile mounts invoke fusermount3 at
    # runtime. Compact hosts do not otherwise pull in the privileged FUSE
    # wrappers that a full desktop happens to provide transitively.
    programs.fuse.enable = true;

    boot.plymouth = lib.mkIf (cfg.enablePresentation && cfg.enableBootSplash) {
      enable = true;
      theme = "nixbox";
      themePackages = [pkgs.nixbox-plymouth-theme];
      extraConfig = "UseSimpledrmNoLuks=1";
    };

    # DMS runs the compositor-owned reverse transition before requesting the
    # system action. Avoid replaying a second Plymouth transition after the
    # graphical session has already released the display.
    systemd.services.plymouth-poweroff.wantedBy =
      lib.mkIf (cfg.enablePresentation && cfg.enableBootSplash) (lib.mkForce []);
    systemd.services.plymouth-reboot.wantedBy =
      lib.mkIf (cfg.enablePresentation && cfg.enableBootSplash) (lib.mkForce []);
    systemd.services.plymouth-halt.wantedBy =
      lib.mkIf (cfg.enablePresentation && cfg.enableBootSplash) (lib.mkForce []);

    services.moonlight-client = {
      enable = true;
      package = cfg.package;
      autoLoginUser = cfg.user;
      autoStartBrowser = false;
      autoStartStream = false;
      enableLocalBrowser = false;
      enableLocalUtilities = cfg.enableLocalUtilities;
      enableDms = cfg.enableDms;
      enableMergedProfile = false;
      enableKdeConnect = cfg.enableKdeConnect;
      kdeConnectScrollIntervalMs = cfg.kdeConnectScrollIntervalMs;
      fallbackBrowserPackage = null;
      protectedBrowserPackage = null;
      browserScaleFactor = cfg.presentationScale;
      browserPresentationScale = cfg.presentationScale;
      cursorThemePackage = pkgs.adwaita-icon-theme;
      cursorTheme = "Adwaita";
      # Adwaita's conventional desktop cursor is 24 px. Match the compact
      # client's 1.5x presentation scale without changing the output scale.
      cursorSize = 36;
      sessionSplashCommand = lib.mkIf cfg.enablePresentation (lib.getExe pkgs.nixbox-session-splash);
      relaunchOnExit = false;
      moonlightPlatform = cfg.moonlightPlatform;
      outputMode = cfg.outputMode;
      fallbackOutputMode = "1920x1080@60";
      outputScale = cfg.outputScale;
    };
  };
}
