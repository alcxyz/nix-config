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
      extraConfig.pipewire = {
        "context.modules" = [
          {
            name = "libpipewire-module-raop-discover latency_msec=2000";
          }
        ];
      };
    };
    services.avahi = {
      enable = true;
      nssmdns4 = true;
    };
    services.pulseaudio.enable = false;
    environment.systemPackages = with pkgs; [
      shairport-sync
      shairport-sync-airplay2
    ];
    #programs.noisetorch.enable = true;
  };
}
