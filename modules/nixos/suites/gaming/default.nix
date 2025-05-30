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
    # Ensure audio is enabled as a dependency
    hardware.audio.enable = mkDefault true;

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

    # Create persistent PipeWire null sink for game audio routing
    systemd.user.services.pipewire-game-sink = {
      description = "Create persistent PipeWire game audio sink";
      wantedBy = [ "pipewire.service" ];
      after = [ "pipewire.service" ];
      requisite = [ "pipewire.service" ];
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = let
          createSinkScript = pkgs.writeShellScript "create-game-sink" ''
            # Wait for PipeWire to be fully ready
            timeout=10
            while [ $timeout -gt 0 ]; do
              if ${pkgs.pipewire}/bin/pw-cli info &>/dev/null; then
                break
              fi
              sleep 1
              timeout=$((timeout - 1))
            done
            
            # Check if sink already exists to avoid duplicates
            if ! ${pkgs.pipewire}/bin/pw-cli ls Node | ${pkgs.gnugrep}/bin/grep -q "GameAudioSink"; then
              # Create the null sink with all specified properties
              ${pkgs.pipewire}/bin/pw-cli create-node adapter '{
                factory.name=support.null-audio-sink
                node.name=GameAudioSink
                node.description="Virtual_Sink_for_Games"
                media.class=Audio/Sink
                audio.channels=2
                audio.position=[FL,FR]
                object.linger=true
                node.dont-remix=true
                node.pause-on-idle=false
              }'
            fi
          '';
        in "${createSinkScript}";
        
        ExecStop = let
          removeSinkScript = pkgs.writeShellScript "remove-game-sink" ''
            # Find and destroy the sink by name
            SINK_ID=$(${pkgs.pipewire}/bin/pw-cli ls Node | \
              ${pkgs.gnugrep}/bin/grep -A5 "GameAudioSink" | \
              ${pkgs.gnugrep}/bin/grep "id:" | \
              ${pkgs.gawk}/bin/awk '{print $2}' | \
              ${pkgs.gnused}/bin/sed 's/,//')
            
            if [ -n "$SINK_ID" ]; then
              ${pkgs.pipewire}/bin/pw-cli destroy "$SINK_ID"
            fi
          '';
        in "${removeSinkScript}";
      };
    };

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
            do-cmd = "${pkgs.gamescope}/bin/gamescope -W 1920 -H 1080 -r 60 -f -- ${pkgs.emulationstation-de}/bin/bin/emulationstation-de";
          }
          {
            name = "Steam Big Picture (with Game Audio Sink)";
            # Example of routing audio to the virtual sink for streaming
            do-cmd = let
              steamWithAudioSink = pkgs.writeShellScript "steam-with-audio-sink" ''
                # Set the game audio sink as default for this session
                ${pkgs.pulseaudio}/bin/pactl set-default-sink GameAudioSink
                # Launch Steam Big Picture with Gamescope
                ${pkgs.gamescope}/bin/gamescope -W 1920 -H 1080 -r 60 -f -b -- ${pkgs.steam}/bin/steam -bigpicture
              '';
            in "${steamWithAudioSink}";
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
