# nix-config/modules/home-manager/suites/gaming/default.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.suites.gaming;
  sunshineConfigPath = ".config/sunshine";

  stream-tool = pkgs.buildGoModule {
    pname = "stream-tool";
    version = "0.1.0";
    src = ./src; 
    vendorHash = null; 
  };
in {
  imports = [ ./audio.nix ];

  options.suites.gaming = {
    enable = lib.mkEnableOption "Gaming Suite";
    gamingWorkspace = lib.mkOption { type = lib.types.str; default = "1"; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [ 
      stream-tool gamescope mangohud
      (writeShellScriptBin "launch-steam" ''
        gamescope -W 2560 -H 1440 -r 60 -f -b -- flatpak run com.valvesoftware.Steam -gamepadui
      '')
      (writeShellScriptBin "launch-retrodeck" ''
        gamescope -W 1920 -H 1080 -r 60 -f -b -- flatpak run net.retrodeck.retrodeck
      '')
    ];

    home.file."${sunshineConfigPath}/apps.json" = {
      force = true;
      text = builtins.toJSON {
        env = { PATH = "$(PATH)"; };
        apps = [
          { name = "Steam"; cmd = "launch-steam"; }
          { name = "RetroDECK"; cmd = "launch-retrodeck"; }
          { name = "Stream Mode (Toggle)"; cmd = "stream-tool toggle"; }
        ];
      };
    };

    home.file."${sunshineConfigPath}/sunshine.conf" = {
      force = true;
      text = ''
        sunshine_name = xyz
        min_log_level = info
        origin_web_ui_allowed = pc
        audio_sink = GameAudioSink.monitor
        
        # Native Sunshine on NixOS auto-detects Wayland via D-Bus
        # Just specify the hardware/encoder
        encoder = nvenc
        nvenc_preset = p1
      '';
    };
  };
}
