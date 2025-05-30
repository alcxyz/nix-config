{ options
, config
, lib
, pkgs
, ...
}:
with lib;
let
  cfg = config.hardware.audio;
in
{
  options.hardware.audio = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable pipewire";
    };
  };

  config = mkIf cfg.enable {
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      wireplumber.enable = true;
      jack.enable = false;
      pulse.enable = true;
    };
    services.pulseaudio.enable = false;

    # Place the WirePlumber script
    # This will put it in /etc/wireplumber/main.lua.d/51-create-game-sink.lua
    # WirePlumber should automatically load scripts from this directory.
    environment.etc."wireplumber/main.lua.d/51-create-game-sink.lua" = {
      source = ./wireplumber_create_game_sink.lua;
      mode = "0444"; # Read-only is fine
    };

    #environment.systemPackages = with pkgs; [
    #];
    #programs.noisetorch.enable = true;
  };
}
