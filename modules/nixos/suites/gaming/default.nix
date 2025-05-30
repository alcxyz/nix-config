# modules/nixos/suites/gaming/default.nix
{ options, config, lib, pkgs, username, ... }: # username is 'alc'

with lib;
let
  cfg = config.suites.gaming;
in
{
  options.suites.gaming = with types; {
    enable = mkOption {
      type = bool;
      default = false;
      description = "Enable the gaming suite configurations, including Steam, Gamescope, and Sunshine.";
    };
  };

  config = mkIf cfg.enable {
    # Ensure your main user 'alc' is in necessary groups (audio, video, input, media)
    # This is already handled in your hosts/xyz/configuration.nix

    environment.systemPackages = with pkgs; [
      # Core gaming and streaming
      # steam # Already enabled via programs.steam.enable in hosts/xyz/configuration.nix
      gamescope
      # sunshine # The module itself adds cfg.package to systemPackages

      # Emulation frontend
      emulationstation-de

      # Common Emulators
      retroarchFull
      dolphin-emu
      pcsx2

      # Utilities
      pipewire
    ];

    # PipeWire/PulseAudio configuration for the virtual sink
    # This ensures the null sink is loaded when PipeWire starts.
    services.pulseaudio.extraConfig = ''
      load-module module-null-sink sink_name=GameAudioSink sink_properties=device.description="Virtual_Sink_for_Games"
    '';
    # If you are purely on PipeWire without pulseaudio.enable = true,
    # you might need to use PipeWire's native config or a WirePlumber script.
    # However, `hardware.pulseaudio.extraConfig` often works for PipeWire too
    # as PipeWire implements the PulseAudio API.
    # Let's assume your `hardware.audio.enable = true` (which enables PipeWire with Pulse support)
    # from `modules/nixos/default.nix` makes this work.

    # Configure the Sunshine service (which is a systemd USER service)
    services.sunshine = {
      enable = true; # This enables the systemd user service for Sunshine
      autoStart = true; # Ensures it starts with your graphical session
      openFirewall = true; # Opens system firewall ports

      # capSysAdmin = true; # Only if you need DRM/KMS capture and understand the implications.
                           # For Gamescope capture, this is usually not needed.

      applications = {
        # env = { # Optional: Environment variables for all Sunshine commands
        #   # These will be available to the do-cmd scripts.
        #   # Example: "STEAM_GAME_ID_FOR_GAMESCOPE" = "12345";
        # };
        apps = [
          {
            name = "Steam Big Picture (Gamescoped Games)";
            # Since this is a user service running as 'alc', this command
            # will execute as 'alc' and should use your existing Steam session.
            do-cmd = "${pkgs.gamescope}/bin/gamescope -W 1920 -H 1080 -r 60 -f -b -- ${pkgs.steam}/bin/steam -bigpicture";
            # image-path = "/path/to/steam_icon.png"; # Optional
          }
          {
            name = "EmulationStation-DE (Gamescoped)";
            do-cmd = "${pkgs.gamescope}/bin/gamescope -W 1920 -H 1080 -r 60 -f -- ${pkgs.emulationstation-de}/bin/emulationstation-de";
          }
        ];
      };

      # settings = { # Global Sunshine settings from sunshine.conf
      #   # Example:
      #   # "sunshine_name" = "NixOS-XYZ";
      #   # "port" = 47989; # Default, but can be changed
      #   # "encoder_bitrate" = 50000; # kbps
      # };
    };

    # Since Sunshine is a user service, we need to ensure it's enabled for your user.
    # The `services.sunshine.enable = true;` above should handle enabling the
    # `sunshine.service` unit within the user's systemd instance.
    # You can verify this after a rebuild with:
    # `systemctl --user status sunshine`
    # `systemctl --user is-enabled sunshine`

    # No need for `systemd.services.sunshine` overrides for User/Group here,
    # as it's a user service.
  };
}
