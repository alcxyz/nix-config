{
  lib,
  ...
}: {
  imports = [../../services/moonlight-client/default.nix];

  # Stability and interaction defaults shared by every Nixbox session.
  # Hardware profiles should only override topology, resolution, decoder, and
  # host-specific launch behavior.
  services.moonlight-client = {
    enableKdeConnect = lib.mkDefault true;
    enableControllerShortcuts = lib.mkDefault true;
    enableAudioOutputCycle = lib.mkDefault true;
    enableAudioHealthRecovery = lib.mkDefault true;
    preferHdmiAudio = lib.mkDefault false;
    relaunchOnExit = lib.mkDefault false;

    # XWayland is the proven common path for Moonlight, KDE Connect XTest
    # injection, and the Waynergy uinput pointer bridge.
    moonlightPlatform = lib.mkDefault "xcb";
    browserStreamArguments = lib.mkDefault [
      "--absolute-mouse"
      "--capture-system-keys"
      "never"
    ];

    # Fixed Nixbox appliances prefer physical-LAN endpoints. A roaming client
    # can explicitly overlay a different endpoint policy.
    streamEndpointMode = lib.mkDefault "lan-only";
    browserStreamEndpointMode = lib.mkDefault "lan-only";

    browserScaleFactor = lib.mkDefault 1.5;
    browserPresentationScale = lib.mkDefault 1.5;
  };
}
