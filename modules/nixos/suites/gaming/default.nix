{ options, config, lib, pkgs, username, ... }:

with lib;
let
  cfg = config.suites.gaming;
in
{
  options.suites.gaming = with types; {
    enable = mkOption {
      type = bool;
      default = false;
      description = "Enable system-level gaming support (audio sink, permissions, Steam, firewall for Sunshine). User-specific setup is handled by Home Manager.";
    };

    sunshine = mkOption {
      type = submodule {
        options = {
          enable = mkOption {
            type = bool;
            default = true;
            description = "Enable Sunshine game streaming server";
          };
        };
      };
      default = {};
      description = "Sunshine streaming configuration";
    };
  };

  config = {
    # Conditionally add extraGroups for the user using mkAfter
    users.users.${username}.extraGroups =
      lib.mkIf cfg.enable (lib.mkAfter [ "render" ]); # Only add "render"

    environment.systemPackages = lib.mkIf cfg.enable (with pkgs; [
      steam pipewire pulseaudio gnugrep gawk gnused
      # Note: pipewire and pulseaudio packages here are for tools like pw-cli, pactl.
      # The actual services are managed by services.pipewire in NixOS config.
    ] ++ optionals cfg.sunshine.enable [ sunshine ]);

    services.udev.extraRules = lib.mkIf cfg.enable ''
      KERNEL=="event*", GROUP="input", MODE="0664"
      KERNEL=="mouse*", GROUP="input", MODE="0664"
      KERNEL=="js*", GROUP="input", MODE="0664"
      SUBSYSTEM=="input", GROUP="input", MODE="0664"
    '';

    programs.steam.enable = lib.mkIf cfg.enable true;
    programs.steam.remotePlay.openFirewall = lib.mkIf cfg.enable true;

    # Add Sunshine service configuration
    systemd.user.services.sunshine = mkIf (cfg.enable && cfg.sunshine.enable) {
      description = "Sunshine game streaming server";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.sunshine}/bin/sunshine";
        Restart = "on-failure";
        RestartSec = "5s";
      };
      
      environment = {
        HOME = "/home/${username}";
        XDG_RUNTIME_DIR = "/run/user/1000";  # Adjust if your user ID is different
      };
    };

    # Copy Sunshine configuration file
    system.activationScripts.sunshine-config = mkIf (cfg.enable && cfg.sunshine.enable) ''
      mkdir -p /home/${username}/.config/sunshine
      chown ${username}:users /home/${username}/.config/sunshine
      
      # Copy the sunshine.conf from the module directory
      cp ${./sunshine.conf} /home/${username}/.config/sunshine/sunshine.conf
      chown ${username}:users /home/${username}/.config/sunshine/sunshine.conf
    '';

    systemd.user.services.pipewire-game-sink = lib.mkIf cfg.enable {
      description = "Create persistent PipeWire game audio sink";
      wantedBy = [ "pipewire.service" ];
      after = [ "pipewire.service" "wireplumber.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "5s";
        ExecStart = let
          createSinkScript = pkgs.writeShellScript "create-game-sink" ''
            set -e
            echo "[pipewire-game-sink] Waiting for PipeWire..."
            timeout=30
            while [ $timeout -gt 0 ]; do
              if ${pkgs.pipewire}/bin/pw-cli info &>/dev/null; then
                echo "[pipewire-game-sink] PipeWire is ready."
                break
              fi
              sleep 2; timeout=$((timeout - 2))
            done
            if [ $timeout -le 0 ]; then echo "[pipewire-game-sink] PipeWire not ready." >&2; exit 1; fi
            
            if ${pkgs.pipewire}/bin/pw-cli ls Node | ${pkgs.gnugrep}/bin/grep -q 'node.name = "GameAudioSink"'; then
              echo "[pipewire-game-sink] GameAudioSink already exists."
              exit 0
            fi
            echo "[pipewire-game-sink] Creating GameAudioSink..."
            ${pkgs.pipewire}/bin/pw-cli create-node adapter '{ factory.name="support.null-audio-sink", node.name="GameAudioSink", node.description="Virtual_Sink_for_Games", media.class="Audio/Sink", audio.channels=2, audio.position="[FL,FR]", object.linger=true, node.dont-remix=true, node.pause-on-idle=false }'
            echo "[pipewire-game-sink] GameAudioSink created."
          '';
        in "${createSinkScript}";
        ExecStop = let
          removeSinkScript = pkgs.writeShellScript "remove-game-sink" ''
            set -e; echo "[pipewire-game-sink] Removing GameAudioSink..."
            SINK_ID=$(${pkgs.pipewire}/bin/pw-cli ls Node | ${pkgs.gnugrep}/bin/grep -B2 'node.name = "GameAudioSink"' | ${pkgs.gnugrep}/bin/grep 'id:' | ${pkgs.gawk}/bin/awk '{print $2}' | ${pkgs.gnused}/bin/sed 's/,//' | head -n 1)
            if [ -n "$SINK_ID" ]; then ${pkgs.pipewire}/bin/pw-cli destroy "$SINK_ID"; echo "[pipewire-game-sink] GameAudioSink (ID: $SINK_ID) removed."; else echo "[pipewire-game-sink] GameAudioSink not found."; fi
          '';
        in "${removeSinkScript}";
      };
    };
    
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.enable [ 47984 47989 48010 ];
    networking.firewall.allowedUDPPorts = lib.mkIf cfg.enable [ 47998 47999 48000 48002 48010 ];
  };
}
