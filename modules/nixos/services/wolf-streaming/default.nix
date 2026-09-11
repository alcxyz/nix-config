{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.wolf-streaming;
  kdeConnectInputDefaults = import ../../../shared/kdeconnect-input.nix;
  nvidiaPackage = config.hardware.nvidia.package;
  browserCfg = cfg.browserImages;
  hostPublicCoordinator = cfg.publicCoordinator == "host";
  kdeConnectPackage = pkgs.kdePackages.kdeconnect-kde;
  kdeConnectExecutable = "${kdeConnectPackage}/bin/kdeconnectd";
  isolatedProtectedBackend =
    cfg.protectedProfile.definitionFile != null && cfg.protectedProfile.isolateBackend;
  publicRuntimeDirectory = cfg.publicRuntimeDirectory;
  publicRuntimeRoot = builtins.dirOf publicRuntimeDirectory;
  protectedRuntimeDirectory = "/run/wolf-streaming/protected/runtime";
  protectedStateDirectory = cfg.protectedProfile.stateDirectory;
  protectedPort = standard: standard + cfg.protectedProfile.portOffset;
  imageAssembly = import ./images.nix {
    inherit lib pkgs browserCfg;
  };
  inherit (imageAssembly) wolfUiImage;
  browserImages = map (name: browserCfg.${name}) (
    lib.filter (name: browserCfg.${name}.enable) ["helium" "brave" "chromium" "firefox" "zen"]
  );
  publicRunnerNames = lib.optionals browserCfg.helium.enable [
    "WolfHelium"
    "WolfHeliumCoop"
  ];
  protectedRunnerNames =
    [
      "Wolf-UI"
    ]
    ++ lib.optional browserCfg.helium.enable "WolfHeliumPrivate"
    ++ lib.optional browserCfg.brave.enable "WolfBrave"
    ++ lib.optional browserCfg.chromium.enable "WolfChromium"
    ++ lib.optional browserCfg.firefox.enable "WolfFirefox"
    ++ lib.optional browserCfg.zen.enable "WolfZen";
  cleanupRunnerContainers = runnerNames:
    lib.concatMapStringsSep "\n" (runnerName: ''
      ${pkgs.docker}/bin/docker ps -aq --filter ${lib.escapeShellArg "name=^/${runnerName}_"} \
        | while read -r container; do
          if [ -n "$container" ]; then
            ${pkgs.docker}/bin/docker rm -f "$container"
          fi
        done
    '')
    runnerNames;
  appCatalog = import ./apps.nix {
    inherit
      browserCfg
      cfg
      isolatedProtectedBackend
      kdeConnectExecutable
      lib
      pkgs
      protectedRuntimeDirectory
      publicRuntimeDirectory
      wolfUiImage
      ;
  };
  inherit
    (appCatalog)
    managedMoonlightAppsFile
    protectedBrowserAppsFile
    protectedMoonlightAppsFile
    reconcileWolfApps
    reconcileWolfProtectedProfile
    removeWolfProtectedProfile
    ;
  wolfCoopManager = pkgs.writeShellApplication {
    name = "wolf-coop-manager";
    runtimeInputs = [pkgs.python3];
    text = ''
      exec python3 ${./wolf-coop-manager.py} \
        --socket ${lib.escapeShellArg "${publicRuntimeDirectory}/wolf.sock"} \
        --entry-title Helium \
        ${lib.optionalString browserCfg.helium.pi3Compatibility "--entry-title ${lib.escapeShellArg "Helium (Pi 3)"} \\"}
        --individual-title ${lib.escapeShellArg "Helium (Individual)"} \
        --lobby-name Helium \
        --runner-name WolfHeliumCoop \
        --runner-state-folder ${lib.escapeShellArg "profile-data/moonlight-profile-id/WolfHeliumCoop"} \
        --video-producer-buffer-caps ${lib.escapeShellArg "video/x-raw, pixel-aspect-ratio=1/1"} \
        --kdeconnect-executable ${
        lib.escapeShellArg (
          if browserCfg.helium.kdeConnect.enable
          then kdeConnectExecutable
          else ""
        )
      }
    '';
  };
  pullRuntimeImages = pkgs.writeShellApplication {
    name = "pull-wolf-runtime-images";
    runtimeInputs = [pkgs.docker];
    text = lib.concatMapStringsSep "\n" (image: ''
      docker image inspect ${lib.escapeShellArg image} >/dev/null 2>&1 \
        || docker pull ${lib.escapeShellArg image}
    '') ([cfg.image] ++ lib.optional browserCfg.enable wolfUiImage ++ map (image: image.image) browserImages);
  };
  readPythonSource = name: source:
    pkgs.writeText name (
      # The file has already been read as source data. Drop only its path
      # context so the unchanged script retains its content-derived store path.
      builtins.unsafeDiscardStringContext (builtins.readFile source)
    );
  wolfSetClientPresentationScale =
    readPythonSource "wolf-set-client-presentation-scale.py"
    ./set-client-presentation-scale.py;
  wolfClearPeerSessions = pkgs.writeShellApplication {
    name = "wolf-clear-peer-sessions";
    runtimeInputs = [pkgs.docker];
    text = ''
      exec docker exec \
        -e "SSH_CONNECTION=$SSH_CONNECTION" \
        -i wolf \
        python3 - \
        < ${./wolf-clear-peer-sessions.py}
    '';
  };

  wolfStreamLayout = pkgs.writeShellApplication {
    name = "wolf-stream-layout";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.docker
    ];
    text = ''
      presentation_scale=1.0
      coordinator=wolf
      runtime_directory=${lib.escapeShellArg publicRuntimeDirectory}
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --presentation-scale)
            [ -n "''${2:-}" ] || {
              echo "wolf-stream-layout: --presentation-scale requires a value" >&2
              exit 2
            }
            presentation_scale="$2"
            shift 2
            ;;
          --coordinator)
            [ -n "''${2:-}" ] || {
              echo "wolf-stream-layout: --coordinator requires a container name" >&2
              exit 2
            }
            coordinator="$2"
            shift 2
            ;;
          --runtime-directory)
            [ -n "''${2:-}" ] || {
              echo "wolf-stream-layout: --runtime-directory requires a path" >&2
              exit 2
            }
            runtime_directory="$2"
            shift 2
            ;;
          *) break ;;
        esac
      done
      case "$presentation_scale" in
        1 | 1.0 | 1.00 | 1.000 | 1.0000 | 1.00000 | 1.000000)
          presentation_scale=1.0
          cursor_size=24
          ;;
        1.5 | 1.50 | 1.500 | 1.5000 | 1.50000 | 1.500000)
          presentation_scale=1.5
          cursor_size=36
          ;;
        *)
          echo "wolf-stream-layout: unsupported presentation scale: $presentation_scale" >&2
          exit 2
          ;;
      esac

      layout="''${1:-}"
      shift || true
      runners=("$@")
      case "$layout" in
        ${lib.concatImapStringsSep "\n        " (
          index: layout: "${layout}) layout_index=${toString (index - 1)} ;;"
        )
        browserCfg.keyboardLayouts}
        *)
          echo "usage: wolf-stream-layout [--presentation-scale {1.0|1.5}] [--coordinator NAME] [--runtime-directory PATH] {${lib.concatStringsSep "|" browserCfg.keyboardLayouts}} RUNNER [RUNNER ...]" >&2
          exit 2
          ;;
      esac
      if [ "''${#runners[@]}" -eq 0 ]; then
        echo "wolf-stream-layout requires at least one runner" >&2
        exit 2
      fi

      # Wolf UI may wait for a person to enter the protected profile PIN.
      # Keep this detached launch helper alive long enough for that normal
      # interaction without delaying Moonlight itself.
      for ((attempt = 0; attempt < 1200; attempt++)); do
        for runner in "''${runners[@]}"; do
          container="$(
            docker ps \
              --filter "name=^/''${runner}_" \
              --format '{{.Names}}' \
              | head -n1
          )"
          if [ -n "$container" ] \
            && docker exec \
              -u ${toString cfg.defaultRunUid} \
              "$container" \
              sh -c '
                if [ -e /tmp/nixbox-browser-presentation/ready ]; then
                  printf "%s\n" "$1" > /tmp/nixbox-browser-presentation/requested-scale
                fi
              ' sh "$presentation_scale" \
                >/dev/null 2>&1 \
            && docker exec \
              -u ${toString cfg.defaultRunUid} \
              -e "SWAYSOCK=$runtime_directory/sway.socket" \
              "$container" \
              swaymsg input type:keyboard xkb_switch_layout "$layout_index" \
                >/dev/null 2>&1; then
            # WOLF_SESSION_ID is the paired-client ID. Persist this client's
            # presentation class so a future fresh runner starts at the right
            # scale; the startup handshake above also handles this first run.
            client_id="$(
              docker exec "$container" printenv WOLF_SESSION_ID 2>/dev/null \
                || true
            )"
            if [ -n "$client_id" ]; then
              docker exec -i "$coordinator" python3 - "$client_id" "$presentation_scale" \
                < ${wolfSetClientPresentationScale} \
                >/dev/null 2>&1 || true
            fi
            docker exec \
              -u ${toString cfg.defaultRunUid} \
              -e "SWAYSOCK=$runtime_directory/sway.socket" \
              "$container" \
              swaymsg seat seat0 xcursor_theme Adwaita "$cursor_size" \
                >/dev/null 2>&1 || true
            # The in-runner KDE pointer bridge owns remote cursor visibility
            # and needs the remote cursor to outlive phone motion long enough
            # for a click. Do not replace its eight-second policy with the
            # near-immediate TV-client timeout merely because the joining
            # Moonlight client uses 1.5x presentation scaling.
            if docker exec "$container" sh -c \
              '[ -n "''${NIXBOX_KDECONNECT_EXECUTABLE:-}" ]' \
                >/dev/null 2>&1; then
              docker exec \
                -u ${toString cfg.defaultRunUid} \
                -e "SWAYSOCK=$runtime_directory/sway.socket" \
                "$container" \
                swaymsg seat seat0 hide_cursor 8000 \
                  >/dev/null 2>&1 || true
            # Other TV-oriented Nixbox clients render a responsive cursor
            # locally in Moonlight. Hide Wolf's remote cursor after activity
            # so absolute virtual pointers cannot leave a stale click-position
            # cursor in the stream. Desktop clients retain the remote cursor.
            elif [ "$presentation_scale" = 1.5 ]; then
              docker exec \
                -u ${toString cfg.defaultRunUid} \
                -e "SWAYSOCK=$runtime_directory/sway.socket" \
                "$container" \
                swaymsg seat seat0 hide_cursor 1 \
                  >/dev/null 2>&1 || true
            else
              docker exec \
                -u ${toString cfg.defaultRunUid} \
                -e "SWAYSOCK=$runtime_directory/sway.socket" \
                "$container" \
                swaymsg seat seat0 hide_cursor 0 \
                  >/dev/null 2>&1 || true
            fi
            exit 0
          fi
        done
        sleep 0.25
      done

      echo "none of the streamed runners exposed a keyboard in time: ''${runners[*]}" >&2
      exit 1
    '';
  };
  # GStreamer's CUDA conversion elements load NVRTC dynamically. The
  # upstream Wolf image deliberately does not bundle it, while NixOS' NVIDIA
  # CDI specification only injects driver libraries. Copy the runtime pieces
  # from the CUDA redistributable source without pulling in the full toolkit.
  nvrtcRuntime = pkgs.callPackage ./nvrtc-runtime.nix {};
in {
  imports = [
    (import ./watchdogs.nix {
      inherit
        hostPublicCoordinator
        isolatedProtectedBackend
        protectedPort
        protectedRuntimeDirectory
        publicRuntimeDirectory
        readPythonSource
        ;
    })
  ];

  options.services.wolf-streaming = import ./options.nix {
    inherit lib kdeConnectInputDefaults;
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.virtualisation.docker.enable;
        message = "services.wolf-streaming requires virtualisation.docker.enable";
      }
      {
        assertion = lib.hasPrefix "/" cfg.stateDirectory;
        message = "services.wolf-streaming.stateDirectory must be an absolute path";
      }
      {
        assertion = lib.hasPrefix "/" publicRuntimeDirectory;
        message = "services.wolf-streaming.publicRuntimeDirectory must be an absolute path";
      }
      {
        assertion = lib.hasPrefix "/dev/dri/renderD" cfg.renderNode;
        message = "services.wolf-streaming.renderNode must name a DRM render node";
      }
      {
        assertion = !browserCfg.enable || browserImages != [];
        message = "services.wolf-streaming.browserImages requires at least one browser image";
      }
      {
        assertion =
          !browserCfg.helium.cooperativeDefault || (browserCfg.helium.enable && browserCfg.helium.publish);
        message = "cooperative Helium requires the enabled, published Helium image";
      }
      {
        assertion = !browserCfg.helium.kdeConnect.enable || browserCfg.helium.cooperativeDefault;
        message = "in-session KDE Connect requires cooperative Helium";
      }
      {
        assertion =
          browserCfg.helium.kdeConnect.pointerPrecisionSensitivity
          <= browserCfg.helium.kdeConnect.pointerSensitivity;
        message = "KDE Connect precision pointer gain must not exceed its maximum gain";
      }
      {
        assertion =
          browserCfg.helium.kdeConnect.pointerAccelerationStart
          < browserCfg.helium.kdeConnect.pointerAccelerationFull;
        message = "KDE Connect pointer acceleration full speed must exceed its start speed";
      }
      {
        assertion =
          lib.length browserCfg.keyboardLayouts == lib.length (lib.unique browserCfg.keyboardLayouts);
        message = "services.wolf-streaming.browserImages.keyboardLayouts must not contain duplicates";
      }
      {
        assertion =
          cfg.protectedProfile.definitionFile
          == null
          || browserCfg.helium.enable
          || browserCfg.brave.enable
          || browserCfg.chromium.enable
          || browserCfg.firefox.enable
          || browserCfg.zen.enable;
        message = "services.wolf-streaming.protectedProfile requires at least one browser image";
      }
      {
        assertion =
          cfg.protectedProfile.definitionFile
          == null
          || lib.hasPrefix "/" cfg.protectedProfile.definitionFile;
        message = "services.wolf-streaming.protectedProfile.definitionFile must be an absolute runtime path";
      }
      {
        assertion = lib.hasPrefix "/" protectedStateDirectory;
        message = "services.wolf-streaming.protectedProfile.stateDirectory must be absolute";
      }
      {
        assertion = !isolatedProtectedBackend || protectedPort 48200 <= 65535;
        message = "services.wolf-streaming.protectedProfile.portOffset produces an invalid port";
      }
    ];

    boot.kernelModules = [
      "uinput"
      "uhid"
    ];

    hardware.nvidia-container-toolkit.enable = true;
    virtualisation.docker.daemon.settings.features.cdi = true;

    services.udev.extraRules = ''
      KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"
      KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"
    '';

    systemd.tmpfiles.rules =
      [
        "d ${cfg.stateDirectory} 0700 root root - -"
        "d /run/wolf-streaming 0755 root root - -"
        "d ${publicRuntimeDirectory} 0700 root root - -"
        "L+ /run/wolf-streaming/libnvidia-allocator.so.1 - - - - ${nvidiaPackage}/lib/libnvidia-allocator.so.1"
      ]
      ++ lib.optionals isolatedProtectedBackend [
        "d ${protectedStateDirectory} 0700 root root - -"
        "d /run/wolf-streaming/protected 0700 root root - -"
        "d ${protectedRuntimeDirectory} 0700 root root - -"
      ]
      ++ lib.optionals (!hostPublicCoordinator) [
        # The Kubernetes supervisor runs this before starting its external
        # coordinator so persisted profiles receive the same managed catalog
        # reconciliation as the host-native coordinator.
        "L+ ${publicRuntimeRoot}/reconcile-apps - - - - ${lib.getExe reconcileWolfApps}"
        "L+ ${publicRuntimeRoot}/managed-apps.json - - - - ${managedMoonlightAppsFile}"
      ];

    virtualisation.oci-containers = {
      backend = "docker";
      containers =
        (lib.optionalAttrs hostPublicCoordinator {
          wolf = {
            image = cfg.image;
            autoStart = true;
            environment = {
              LD_LIBRARY_PATH = "/opt/wolf-nvrtc/lib";
              NVIDIA_DRIVER_CAPABILITIES = "all";
              NVIDIA_VISIBLE_DEVICES = "all";
              WOLF_DEFAULT_RUN_GID = toString cfg.defaultRunGid;
              WOLF_DEFAULT_RUN_UID = toString cfg.defaultRunUid;
              WOLF_LOG_LEVEL = "INFO";
              WOLF_RENDER_NODE = cfg.renderNode;
              WOLF_SESSION_IDLE_TIMEOUT_SECONDS = toString cfg.sessionIdleTimeoutSeconds;
              WOLF_STOP_CONTAINER_ON_EXIT = "TRUE";
              # gst-wayland-display owns the outer virtual seat. Its Smithay
              # keymap must recognize Right Alt as LevelThree before nested Sway
              # can preserve AltGr for streamed applications.
              XKB_DEFAULT_LAYOUT = lib.concatStringsSep "," browserCfg.keyboardLayouts;
              XKB_DEFAULT_OPTIONS = "grp:alt_shift_toggle,lv3:ralt_switch";
              XDG_RUNTIME_DIR = "/run/wolf-streaming/runtime";
            };
            volumes = [
              "${cfg.stateDirectory}:/etc/wolf:rw"
              "${nvrtcRuntime}:/opt/wolf-nvrtc:ro"
              "/run/wolf-streaming/libnvidia-allocator.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.1:ro"
              "/run/wolf-streaming/runtime:/run/wolf-streaming/runtime:rw"
              "${nvidiaPackage}/share/glvnd/egl_vendor.d/10_nvidia.json:/usr/share/glvnd/egl_vendor.d/10_nvidia.json:ro"
              "/var/run/docker.sock:/var/run/docker.sock:rw"
              "/dev:/dev:rw"
              "/run/udev:/run/udev:rw"
            ];
            extraOptions = [
              "--network=host"
              "--device=/dev/dri"
              "--device=/dev/uinput"
              "--device=/dev/uhid"
              "--device=nvidia.com/gpu=all"
              "--device-cgroup-rule=c 13:* rmw"
            ];
          };
        })
        // lib.optionalAttrs isolatedProtectedBackend {
          wolf-protected = {
            image = cfg.image;
            autoStart = true;
            environment = {
              LD_LIBRARY_PATH = "/opt/wolf-nvrtc/lib";
              NVIDIA_DRIVER_CAPABILITIES = "all";
              NVIDIA_VISIBLE_DEVICES = "all";
              WOLF_AUDIO_PING_PORT = toString (protectedPort 48200);
              WOLF_CONTROL_PORT = toString (protectedPort 47999);
              WOLF_DEFAULT_RUN_GID = toString cfg.defaultRunGid;
              WOLF_DEFAULT_RUN_UID = toString cfg.defaultRunUid;
              WOLF_HTTP_PORT = toString (protectedPort 47989);
              WOLF_HTTPS_PORT = toString (protectedPort 47984);
              WOLF_LOG_LEVEL = "INFO";
              WOLF_RENDER_NODE = cfg.renderNode;
              WOLF_RTSP_SETUP_PORT = toString (protectedPort 48010);
              WOLF_SESSION_IDLE_TIMEOUT_SECONDS = toString cfg.sessionIdleTimeoutSeconds;
              WOLF_STOP_CONTAINER_ON_EXIT = "TRUE";
              WOLF_VIDEO_PING_PORT = toString (protectedPort 48100);
              XKB_DEFAULT_LAYOUT = lib.concatStringsSep "," browserCfg.keyboardLayouts;
              XKB_DEFAULT_OPTIONS = "grp:alt_shift_toggle,lv3:ralt_switch";
              XDG_RUNTIME_DIR = protectedRuntimeDirectory;
            };
            volumes = [
              "${protectedStateDirectory}:/etc/wolf:rw"
              "${nvrtcRuntime}:/opt/wolf-nvrtc:ro"
              "/run/wolf-streaming/libnvidia-allocator.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.1:ro"
              "${protectedRuntimeDirectory}:${protectedRuntimeDirectory}:rw"
              "${nvidiaPackage}/share/glvnd/egl_vendor.d/10_nvidia.json:/usr/share/glvnd/egl_vendor.d/10_nvidia.json:ro"
              "/var/run/docker.sock:/var/run/docker.sock:rw"
              "/dev:/dev:rw"
              "/run/udev:/run/udev:rw"
            ];
            extraOptions = [
              "--network=host"
              "--device=/dev/dri"
              "--device=/dev/uinput"
              "--device=/dev/uhid"
              "--device=nvidia.com/gpu=all"
              "--device-cgroup-rule=c 13:* rmw"
            ];
          };
        };
    };

    environment.systemPackages = lib.optionals browserCfg.enable [
      wolfClearPeerSessions
      wolfStreamLayout
    ];

    systemd.services.docker-wolf = lib.mkIf hostPublicCoordinator {
      restartIfChanged = false;
      after =
        [
          "docker.service"
          "nvidia-container-toolkit-cdi-generator.service"
        ]
        ++ lib.optional isolatedProtectedBackend "wolf-protected-state-migration.service"
        ++ lib.optional (cfg.protectedProfile.definitionFile != null) "sops-install-secrets.service";
      requires =
        [
          "docker.service"
        ]
        ++ lib.optional isolatedProtectedBackend "wolf-protected-state-migration.service";
      serviceConfig.LoadCredential = lib.mkIf (cfg.protectedProfile.definitionFile != null) [
        "wolf-protected-profile:${cfg.protectedProfile.definitionFile}"
      ];
      preStart = lib.mkIf browserCfg.enable (
        ''
          # Wolf cannot resume application containers that outlive a
          # coordinator restart. Remove only containers created by the managed
          # runners before loading the reconciled application catalog.
          ${cleanupRunnerContainers (
            publicRunnerNames ++ lib.optionals (!isolatedProtectedBackend) protectedRunnerNames
          )}

          ${lib.getExe reconcileWolfApps} \
            ${lib.escapeShellArg "${cfg.stateDirectory}/cfg/config.toml"} \
            ${lib.escapeShellArg managedMoonlightAppsFile}

          ${lib.optionalString isolatedProtectedBackend ''
            # The independent coordinator now owns this profile. Remove its
            # stale catalog entry from the public coordinator only after the
            # one-time state fork has completed.
            ${lib.getExe removeWolfProtectedProfile} \
              ${lib.escapeShellArg "${cfg.stateDirectory}/cfg/config.toml"} \
              "$CREDENTIALS_DIRECTORY/wolf-protected-profile"
          ''}
        ''
        + lib.optionalString (cfg.protectedProfile.definitionFile != null && !isolatedProtectedBackend) ''
          ${lib.getExe reconcileWolfProtectedProfile} \
            ${lib.escapeShellArg "${cfg.stateDirectory}/cfg/config.toml"} \
            "$CREDENTIALS_DIRECTORY/wolf-protected-profile" \
            ${lib.escapeShellArg protectedBrowserAppsFile} \
            ${lib.escapeShellArg cfg.protectedProfile.displayName}
        ''
      );
    };

    systemd.services.wolf-coop-manager =
      lib.mkIf (browserCfg.helium.publish && browserCfg.helium.cooperativeDefault)
      {
        description = "Route Helium Moonlight sessions into the shared lobby";
        wantedBy = ["multi-user.target"];
        after =
          if hostPublicCoordinator
          then ["docker-wolf.service"]
          else ["docker.service"];
        requires = lib.optional hostPublicCoordinator "docker-wolf.service";
        serviceConfig = {
          ExecStart = lib.getExe wolfCoopManager;
          Restart = "always";
          RestartSec = "2s";
        };
      };

    systemd.services.wolf-protected-state-migration = lib.mkIf isolatedProtectedBackend {
      description = "Fork persistent Wolf state for the protected coordinator";
      before = [
        "docker-wolf.service"
        "docker-wolf-protected.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Preserve pairing, protected browser homes, and profile identity on
        # the first split. The state trees diverge permanently after this copy.
        if [ ! -e ${lib.escapeShellArg "${protectedStateDirectory}/cfg/config.toml"} ] \
          && [ -e ${lib.escapeShellArg "${cfg.stateDirectory}/cfg/config.toml"} ]; then
          cp -a ${lib.escapeShellArg "${cfg.stateDirectory}/."} \
            ${lib.escapeShellArg "${protectedStateDirectory}/"}
          find ${lib.escapeShellArg protectedStateDirectory} \
            -name .nixbox-browser-session.lock -delete
        fi
      '';
    };

    systemd.services.docker-wolf-protected = lib.mkIf isolatedProtectedBackend {
      restartIfChanged = false;
      after = [
        "docker.service"
        "nvidia-container-toolkit-cdi-generator.service"
        "sops-install-secrets.service"
        "wolf-protected-state-migration.service"
      ];
      requires = [
        "docker.service"
        "wolf-protected-state-migration.service"
      ];
      serviceConfig.LoadCredential = [
        "wolf-protected-profile:${cfg.protectedProfile.definitionFile}"
      ];
      preStart = ''
        ${cleanupRunnerContainers protectedRunnerNames}

        ${lib.getExe reconcileWolfApps} \
          ${lib.escapeShellArg "${protectedStateDirectory}/cfg/config.toml"} \
          ${lib.escapeShellArg protectedMoonlightAppsFile} \
          ${lib.escapeShellArg "Wolf User"}

        ${lib.getExe reconcileWolfProtectedProfile} \
          ${lib.escapeShellArg "${protectedStateDirectory}/cfg/config.toml"} \
          "$CREDENTIALS_DIRECTORY/wolf-protected-profile" \
          ${lib.escapeShellArg protectedBrowserAppsFile} \
          ${lib.escapeShellArg cfg.protectedProfile.displayName}
      '';
    };

    # Preload the configured artifacts without retaining image build inputs.
    # External supervisors also pull their declared references on reconciliation.
    systemd.services.wolf-runtime-images = {
      description = "Pull pinned Wolf runtime images";
      after = ["docker.service" "network-online.target"];
      wants = ["network-online.target"];
      requires = ["docker.service"];
      before = lib.optional hostPublicCoordinator "docker-wolf.service" ++ lib.optional isolatedProtectedBackend "docker-wolf-protected.service";
      wantedBy = lib.optional hostPublicCoordinator "docker-wolf.service" ++ lib.optional isolatedProtectedBackend "docker-wolf-protected.service" ++ lib.optional (!hostPublicCoordinator) "multi-user.target";
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "60s";
        TimeoutStartSec = "15min";
        ExecStart = lib.getExe pullRuntimeImages;
      };
    };

    systemd.services.docker-prune = lib.mkIf config.virtualisation.docker.autoPrune.enable {
      unitConfig.OnSuccess = lib.mkAfter ["wolf-runtime-images-after-prune.service"];
    };
    systemd.services.wolf-runtime-images-after-prune = lib.mkIf config.virtualisation.docker.autoPrune.enable {
      description = "Restore pinned Wolf images after Docker pruning";
      after = ["docker-prune.service" "network-online.target"];
      wants = ["network-online.target"];
      requires = ["docker.service"];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "60s";
        TimeoutStartSec = "15min";
        ExecStart = lib.getExe pullRuntimeImages;
      };
    };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts =
        [
          47984
          47989
          48010
        ]
        ++ lib.optional browserCfg.helium.kdeConnect.enable 1716
        ++ lib.optionals isolatedProtectedBackend [
          (protectedPort 47984)
          (protectedPort 47989)
          (protectedPort 48010)
        ];
      allowedUDPPorts =
        [
          47999
          48100
          48200
        ]
        ++ lib.optional browserCfg.helium.kdeConnect.enable 1716
        ++ lib.optionals isolatedProtectedBackend [
          (protectedPort 47999)
          (protectedPort 48100)
          (protectedPort 48200)
        ];
    };
  };
}
