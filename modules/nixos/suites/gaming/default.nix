# nix-config/modules/nixos/suites/gaming.nix
{ config, lib, pkgs, username, ... }:

let
  gameAppsRegex = "steam|steam_app_.*|retrodeck|retroarch|gamescope";

  nvidiaLib = "${config.hardware.nvidia.package}/lib";
  sunshinePatched = pkgs.sunshine.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [])
      ++ [ pkgs.patchelf pkgs.findutils pkgs.file ];

    postFixup = (old.postFixup or "") + ''
      set -euo pipefail
      echo "Patching Sunshine RPATH to include: ${nvidiaLib}"

      while IFS= read -r -d "" f; do
        if ${pkgs.file}/bin/file -b "$f" | grep -q ELF; then
          ${pkgs.patchelf}/bin/patchelf --add-rpath "${nvidiaLib}" "$f" \
            || true
        fi
      done < <(${pkgs.findutils}/bin/find "$out" -type f \
        \( -name sunshine -o -name '*.so' -o -name '*.so.*' \) -print0)
    '';
  });

in {
  options.suites.gaming.enable = lib.mkEnableOption "Gaming Infrastructure";

  config = lib.mkIf config.suites.gaming.enable {
    services.pipewire = {
      enable = true;
      audio.enable = true;
      pulse.enable = true;

      # Minimal: one persistent virtual sink
      extraConfig.pipewire."91-game-sink" = {
        "context.objects" = [
          {
            factory = "adapter";
            args = {
              "factory.name" = "support.null-audio-sink";
              "node.name" = "GameAudioSink";
              "node.description" = "Game Audio Sink";
              "media.class" = "Audio/Sink";
              "audio.position" = "FL,FR";
            };
          }
        ];
      };
    };

    services.pipewire.extraConfig.pipewire."92-game-loopback" = {
      "context.modules" = [
        {
          name = "libpipewire-module-loopback";
          args = {
            "node.description" = "Game Audio Loopback";
            "capture.props" = {
              "node.target" = "GameAudioSink";
              "media.class" = "Audio/Source";
            };
            "playback.props" = {
              "node.name" = "GameAudio_Loopback_Output";
              "node.passive" = true;
              "target.object" = "@DEFAULT_SINK@";
            };
          };
        }
      ];
    };

    services.pipewire.wireplumber.extraConfig."51-game-audio-routing" = {
      "monitor.pipewire.rules" = [
        {
          matches = [
            { "application.process.binary" = "~(steam|steam_app_.*|retrodeck|retroarch|gamescope)"; }
            { "app.id" = "~(com.valvesoftware.Steam|net.retrodeck.retrodeck)"; }
          ];
          actions.update-props = {
            "node.target" = "GameAudioSink";
          };
        }
      ];
    };

    # Sunshine Configuration
    services.sunshine = {
      enable = true;
      package = sunshinePatched;
      autoStart = true;
      capSysAdmin = true;
      openFirewall = true;
      settings = {
        sunshine_name = "xyz";
        audio_sink = "GameAudioSink.monitor";
        capture = "kms";
        
        # Using the stable PCI path ensures this works regardless of card order (card1 vs card2)
        adapter_name = "/dev/dri/by-path/pci-0000:01:00.0-render"; 
        
        # Sticking with index 1 as verified by your logs
        output_name = "1"; 
        encoder = "nvenc";
      };
      applications = {
        apps = [
          {
            name = "Steam";
            cmd = "${pkgs.gamescope}/bin/gamescope -W 2560 -H 1440 -r 60 -O HDMI-A-3 -- flatpak run com.valvesoftware.Steam -gamepadui";
          }
          {
            name = "RetroDECK";
            cmd = "${pkgs.gamescope}/bin/gamescope -W 1920 -H 1080 -r 60 -O HDMI-A-3 -- flatpak run net.retrodeck.retrodeck";
          }
        ];
      };
    };

    # REFINED ENVIRONMENT: Fixes the CUDA/NVENC library lookup
    systemd.user.services.sunshine.serviceConfig = {
      Environment = lib.mkForce [
        "XDG_RUNTIME_DIR=/run/user/1000"
        # Crucial: This allows Sunshine to find libcuda.so.1 and libnvidia-encode.so.1
        "LD_LIBRARY_PATH=/run/opengl-driver/lib:/run/opengl-driver-32/lib"
        # Force Sunshine to prioritize the NVIDIA vendor for GL/Vulkan if needed
        "__GLX_VENDOR_LIBRARY_NAME=nvidia"
      ];
    };

    # Permissions and Hardware
    # Andre must be in both video and render
    users.users.${username}.extraGroups = [ "video" "render" "input" ];

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    # udev: Added standard NVIDIA and uinput rules
    services.udev.extraRules = ''
      KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
      KERNEL=="nvidia_uvm", MODE="0666"
      # Basic gamepad rule to stop the ds5 noise in your logs
      KERNEL=="hidraw*", SUBSYSTEM=="hidraw", MODE="0666", TAG+="uaccess"
    '';

    boot.kernelModules = [ "uinput" "nvidia_uvm" ];

  };
}
