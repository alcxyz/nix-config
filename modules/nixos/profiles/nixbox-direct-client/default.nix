{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nixbox-direct-client;
in {
  imports = [../../services/moonlight-client/default.nix];

  options.services.nixbox-direct-client = {
    enable = lib.mkEnableOption "a direct-DRM-only Moonlight appliance";

    user = lib.mkOption {
      type = lib.types.str;
      description = "Existing user that owns the direct-display session.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.moonlight-v4l2-request;
      defaultText = lib.literalExpression "pkgs.moonlight-v4l2-request";
      description = "Moonlight package used by the direct-display client.";
    };

    enableKdeConnect = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable KDE Connect input for direct-display sessions.";
    };

    streamFps = lib.mkOption {
      type = lib.types.ints.between 1 120;
      default = 60;
      description = "Requested Moonlight frame rate for direct-display streams.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "services.nixbox-direct-client.user must name a declared NixOS user";
      }
    ];

    users.users.${cfg.user}.extraGroups = [
      "input"
      "render"
      "video"
    ];

    hardware.graphics.enable = true;
    hardware.enableRedistributableFirmware = true;

    services.greetd.enable = true;

    services.moonlight-client = {
      enable = true;
      enableCompositedSession = false;
      package = cfg.package;
      autoLoginUser = cfg.user;

      autoStartBrowser = false;
      autoStartStream = false;
      enableLocalBrowser = false;
      enableLocalUtilities = false;
      enableDms = false;
      enableMergedProfile = false;
      enableKdeConnect = cfg.enableKdeConnect;
      enableControllerShortcuts = false;
      enableAudioOutputCycle = false;
      enableAudioHealthRecovery = false;
      fallbackBrowserPackage = null;
      protectedBrowserPackage = null;

      enableDirectDrmBrowserStreams = true;
      enableDirectDrmStream = true;
      enableDirectModeInputShortcuts = true;
      defaultSessionMode = "direct-browser";
      relaunchOnExit = false;
    };
  };
}
