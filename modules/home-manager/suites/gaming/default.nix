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
  imports = [
    ./audio.nix
  ];

  options.suites.gaming = {
    enable = lib.mkEnableOption "Gaming Suite";
    gamingWorkspace = lib.mkOption { 
      type = lib.types.str; 
      default = "1"; 
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [ 
      stream-tool
      gamescope 
      mangohud
      
      (writeShellScriptBin "launch-steam" ''
        gamescope -W 2560 -H 1440 -r 60 -f -b -- flatpak run com.valvesoftware.Steam -bigpicture
      '')
      (writeShellScriptBin "launch-retrodeck" ''
        gamescope -W 1920 -H 1080 -r 60 -f -b -- flatpak run net.retrodeck.retrodeck
      '')
    ];

    # Combined Sunshine Config Definitions
    home.file."${sunshineConfigPath}/apps.json" = {
      force = true;
      text = builtins.toJSON {
        env = { PATH = "$(PATH)"; };
        apps = [
          {
            name = "Steam";
            cmd = [ "flatpak" "run" "com.valvesoftware.Steam" "-gamepadui" ];
          }
          {
            name = "RetroDECK";
            cmd = [ "flatpak" "run" "net.retrodeck.retrodeck" ];
          }
          {
            name = "Stream Mode (Toggle)";
            cmd = [ "stream-tool" "toggle" ];
          }
        ];
      };
    };

    # Force delete the state file to ensure it picks up the .conf monitor settings
    #home.file."${sunshineConfigPath}/sunshine_state.json".force = true;
    #home.file."${sunshineConfigPath}/sunshine_state.json".text = "{}";

    home.file."${sunshineConfigPath}/sunshine.conf" = {
      force = true;
      text = ''
        sunshine_name = xyz
        min_log_level = info
        origin_web_ui_allowed = pc
        external_ip = 192.168.1.10

        # Target HDMI-A-3 (Index 1)
        #output_name = HDMI-A-3
        output_index = 1
        output_name = 1

        # Priority Hardware
        adapter_name = 1
        encoder = nvenc
        nvenc_preset = p1

        audio_sink = GameAudioSink.monitor
      '';
    };

  };
}
