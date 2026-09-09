{
  browserCfg,
  cfg,
  isolatedProtectedBackend,
  kdeConnectExecutable,
  lib,
  pkgs,
  protectedRuntimeDirectory,
  publicRuntimeDirectory,
  wolfUiImage,
}: let
  browserHostConfig = builtins.toJSON {
    StopSignal = "SIGTERM";
    StopTimeout = 20;
    HostConfig = {
      IpcMode = "host";
      Privileged = false;
      CapAdd = [
        "NET_RAW"
        "MKNOD"
        "NET_ADMIN"
      ];
      DeviceCgroupRules = [
        "c 13:* rmw"
        "c 244:* rmw"
      ];
      SecurityOpt = ["seccomp=unconfined"];
      DeviceRequests = [
        {
          Driver = "cdi";
          Count = 0;
          DeviceIDs = ["nvidia.com/gpu=all"];
          Capabilities = null;
          Options = null;
        }
      ];
    };
  };
  wolfUiHostConfig = builtins.toJSON {
    HostConfig = {
      IpcMode = "host";
      Privileged = false;
      CapAdd = [
        "NET_RAW"
        "MKNOD"
        "NET_ADMIN"
        "SYS_ADMIN"
        "SYS_NICE"
      ];
      DeviceCgroupRules = [
        "c 13:* rmw"
        "c 244:* rmw"
      ];
      SecurityOpt = ["seccomp=unconfined"];
      DeviceRequests = [
        {
          Driver = "cdi";
          Count = 0;
          DeviceIDs = ["nvidia.com/gpu=all"];
          Capabilities = null;
          Options = null;
        }
      ];
    };
  };
  mkMoonlightBrowserApp = {
    title,
    runnerName,
    image,
    icon,
    kdeConnect ? false,
    restoreSession ? false,
  }: {
    inherit title;
    icon_png_path = icon;
    start_virtual_compositor = true;
    start_audio_server = true;
    runner = {
      type = "docker";
      name = runnerName;
      inherit image;
      mounts =
        [
          "/run/wolf-streaming/libnvidia-allocator.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.1:ro"
        ]
        ++ lib.optional kdeConnect "/nix/store:/nix/store:ro";
      env =
        [
          "RUN_SWAY=1"
          "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
          "NIXBOX_BROWSER_SCALE=1.0"
          "XKB_DEFAULT_LAYOUT=${lib.concatStringsSep "," browserCfg.keyboardLayouts}"
          "XKB_DEFAULT_OPTIONS=grp:alt_shift_toggle,lv3:ralt_switch"
        ]
        ++ lib.optional kdeConnect "NIXBOX_KDECONNECT_EXECUTABLE=${kdeConnectExecutable}"
        ++ lib.optional kdeConnect "NIXBOX_KDECONNECT_POINTER_SENSITIVITY=${toString browserCfg.helium.kdeConnect.pointerSensitivity}"
        ++ lib.optional kdeConnect "NIXBOX_KDECONNECT_POINTER_PRECISION_SENSITIVITY=${toString browserCfg.helium.kdeConnect.pointerPrecisionSensitivity}"
        ++ lib.optional kdeConnect "NIXBOX_KDECONNECT_POINTER_ACCELERATION_START=${toString browserCfg.helium.kdeConnect.pointerAccelerationStart}"
        ++ lib.optional kdeConnect "NIXBOX_KDECONNECT_POINTER_ACCELERATION_FULL=${toString browserCfg.helium.kdeConnect.pointerAccelerationFull}"
        ++ lib.optional kdeConnect "NIXBOX_KDECONNECT_SCROLL_INTERVAL_MS=${toString browserCfg.helium.kdeConnect.scrollIntervalMs}"
        ++ lib.optional restoreSession "NIXBOX_RESTORE_LAST_SESSION=1";
      devices = [];
      ports = [];
      base_create_json = browserHostConfig;
    };
  };
  heliumIndividualApp = mkMoonlightBrowserApp {
    title =
      if browserCfg.helium.cooperativeDefault
      then "Helium (Individual)"
      else "Helium";
    runnerName = "WolfHelium";
    image = browserCfg.helium.image;
    icon = "https://helium.computer/favicon.png";
    kdeConnect = browserCfg.helium.kdeConnect.enable;
    restoreSession = true;
  };
  heliumCooperativeEntryApp = {
    title = "Helium";
    icon_png_path = "https://helium.computer/favicon.png";
    start_virtual_compositor = true;
    start_audio_server = true;
    # The cold catalog producer exists only until the cooperative lobby is
    # ready. Keeping its frames in CUDA memory makes cudaconvertscale reject
    # the initial BGRA caps and Moonlight remains on "Starting Helium" before
    # the lobby can take over. Normalize the temporary and lobby producers in
    # system memory, then upload NV12 for the normal NVENC pipeline.
    video = {
      # Both the temporary catalog compositor and the cooperative lobby must
      # publish byte-for-byte compatible caps. waylanddisplaysrc otherwise
      # gives the first producer an effectively unspecified pixel aspect
      # ratio, while the replacement producer omits the field entirely;
      # gst-interpipe then treats the live handoff as renegotiation.
      producer_buffer_caps = "video/x-raw, pixel-aspect-ratio=1/1";
      video_params = ''
        videoconvertscale add-borders=false !
        video/x-raw, width={width}, height={height}, format=NV12, pixel-aspect-ratio=1/1 !
        cudaupload !
        video/x-raw(memory:CUDAMemory), width={width}, height={height}, format=NV12, pixel-aspect-ratio=1/1
      '';
      # Emit a periodic IDR and repeat SPS/PPS so recovery after the live
      # catalog-to-lobby switch does not depend on preserving the initial
      # codec headers across that handoff.
      h264_encoder = ''
        nvh264enc preset=low-latency-hq zerolatency=true gop-size=60 rc-mode=cbr-ld-hq bitrate={bitrate} vbv-buffer-size={vbv_buffer_size} aud=false !
        h264parse config-interval=-1 !
        video/x-h264, profile=main, stream-format=byte-stream
      '';
    };
    runner = {
      type = "process";
      run_cmd = "sleep infinity";
    };
  };
  # bcm2835-codec rejects the low-latency NVENC H.264 bitstream even though it
  # accepts equivalent 1080p streams from x264. Keep the shared lobby and
  # publish a conservative software-encoded entry only for Pi 3 clients.
  heliumPi3CooperativeEntryApp =
    heliumCooperativeEntryApp
    // {
      title = "Helium (Pi 3)";
      video =
        heliumCooperativeEntryApp.video
        // {
          video_params = ''
            videoconvertscale add-borders=false !
            video/x-raw, width={width}, height={height}, format=NV12, pixel-aspect-ratio=1/1 !
            cudaupload !
            video/x-raw(memory:CUDAMemory), width={width}, height={height}, format=NV12, pixel-aspect-ratio=1/1 !
            cudadownload !
            video/x-raw, width={width}, height={height}, format=NV12, pixel-aspect-ratio=1/1
          '';
          h264_encoder = ''
            x264enc tune=zerolatency speed-preset=ultrafast bitrate={bitrate} key-int-max=60 bframes=0 byte-stream=true aud=true cabac=false !
            h264parse config-interval=-1 !
            video/x-h264, profile=constrained-baseline, stream-format=byte-stream
          '';
        };
    };
  mkWolfUiApp = runtimeDirectory: {
    title = "Wolf UI";
    icon_png_path = "https://raw.githubusercontent.com/games-on-whales/wolf-ui/refs/heads/main/src/Icons/wolf_ui_icon.png";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "Wolf-UI";
      image = wolfUiImage;
      mounts = [
        "${runtimeDirectory}/wolf.sock:/var/run/wolf/wolf.sock"
        "/run/wolf-streaming/libnvidia-allocator.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.1:ro"
      ];
      env = [
        "GOW_REQUIRED_DEVICES=/dev/input/event* /dev/dri/* /dev/nvidia*"
        "WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock"
        "WOLF_UI_AUTOUPDATE=False"
        "LOGLEVEL=INFO"
      ];
      devices = [];
      ports = [];
      base_create_json = wolfUiHostConfig;
    };
  };
  managedMoonlightApps =
    lib.optional (!isolatedProtectedBackend) (mkWolfUiApp publicRuntimeDirectory)
    ++ lib.optionals browserCfg.helium.publish (
      if browserCfg.helium.cooperativeDefault
      then
        [heliumCooperativeEntryApp]
        ++ lib.optional browserCfg.helium.pi3Compatibility heliumPi3CooperativeEntryApp
        ++ [heliumIndividualApp]
      else [heliumIndividualApp]
    )
    ++ lib.optional browserCfg.brave.publish (mkMoonlightBrowserApp {
      title = "Brave";
      runnerName = "WolfBrave";
      image = browserCfg.brave.image;
      icon = "https://brave.com/static-assets/images/brave-logo-sans-text.svg";
    });
  protectedMoonlightApps = lib.optional isolatedProtectedBackend (
    mkWolfUiApp protectedRuntimeDirectory
  );
  managedMoonlightAppsFile = pkgs.writeText "wolf-managed-moonlight-apps.json" (
    builtins.toJSON {
      managedTitles =
        [
          "Wolf UI"
          "Helium"
          "Helium (Pi 3)"
          "Brave"
          "Chromium"
          "Firefox"
          "Firefox ESR"
          "Zen"
        ]
        ++ cfg.prunedApplicationTitles;
      apps = managedMoonlightApps;
    }
  );
  protectedMoonlightAppsFile = pkgs.writeText "wolf-protected-moonlight-apps.json" (
    builtins.toJSON {
      managedTitles = [
        "Wolf UI"
        "Helium"
        "Helium (Individual)"
        "Brave"
        "Chromium"
        "Firefox"
        "Firefox ESR"
        "Zen"
      ];
      apps = protectedMoonlightApps;
    }
  );
  protectedBrowserAppsFile = pkgs.writeText "wolf-managed-protected-browser-apps.json" (
    builtins.toJSON {
      managedTitles = [
        "Helium"
        "Brave"
        "Chromium"
        "Firefox"
        "Firefox ESR"
        "Zen"
      ];
      apps =
        lib.optional browserCfg.helium.enable (mkMoonlightBrowserApp {
          title = "Helium";
          runnerName = "WolfHeliumPrivate";
          image = browserCfg.helium.image;
          icon = "https://helium.computer/favicon.png";
          kdeConnect = browserCfg.helium.kdeConnect.enable;
        })
        ++ lib.optional browserCfg.brave.enable (mkMoonlightBrowserApp {
          title = "Brave";
          runnerName = "WolfBrave";
          image = browserCfg.brave.image;
          icon = "https://brave.com/static-assets/images/brave-logo-sans-text.svg";
        })
        ++ lib.optional browserCfg.chromium.enable (mkMoonlightBrowserApp {
          title = "Chromium";
          runnerName = "WolfChromium";
          image = browserCfg.chromium.image;
          icon = "https://www.chromium.org/_static/images/chromium-logo.svg";
        })
        ++ lib.optional browserCfg.firefox.enable (mkMoonlightBrowserApp {
          title = "Firefox";
          runnerName = "WolfFirefox";
          image = browserCfg.firefox.image;
          icon = "https://games-on-whales.github.io/wildlife/apps/firefox/assets/icon.png";
        })
        ++ lib.optional browserCfg.zen.enable (mkMoonlightBrowserApp {
          title = "Zen";
          runnerName = "WolfZen";
          image = browserCfg.zen.image;
          icon = "https://zen-browser.app/favicon.svg";
        });
    }
  );
  reconcileWolfApps = pkgs.writeShellApplication {
    name = "reconcile-wolf-apps";
    runtimeInputs = [
      (pkgs.python3.withPackages (pythonPackages: [pythonPackages.tomlkit]))
    ];
    text = ''
      exec python3 ${./reconcile-apps.py} "$@"
    '';
  };
  reconcileWolfProtectedProfile = pkgs.writeShellApplication {
    name = "reconcile-wolf-protected-profile";
    runtimeInputs = [
      (pkgs.python3.withPackages (pythonPackages: [pythonPackages.tomlkit]))
    ];
    text = ''
      exec python3 ${./reconcile-protected-profile.py} "$@"
    '';
  };
  removeWolfProtectedProfile = pkgs.writeShellApplication {
    name = "remove-wolf-protected-profile";
    runtimeInputs = [
      (pkgs.python3.withPackages (pythonPackages: [pythonPackages.tomlkit]))
    ];
    text = ''
      exec python3 ${./remove-protected-profile.py} "$@"
    '';
  };
in {
  inherit
    managedMoonlightAppsFile
    protectedBrowserAppsFile
    protectedMoonlightAppsFile
    reconcileWolfApps
    reconcileWolfProtectedProfile
    removeWolfProtectedProfile
    ;
}
