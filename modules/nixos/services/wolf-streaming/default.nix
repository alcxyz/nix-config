{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.wolf-streaming;
  nvidiaPackage = config.hardware.nvidia.package;
  nvidiaSmi = "${nvidiaPackage.bin}/bin/nvidia-smi";
  browserCfg = cfg.browserImages;
  wolfRevision = "d6d41dec9cf758b086768e19a7dc02c20ffce22c";
  wolfPatchSet = "altgr-idle-presentation-v1";
  wolfBaseImage = "ghcr.io/games-on-whales/wolf@sha256:8515dd1a88fa6c4a39a814c7c2f7eee4106d5b60c8140be6d0ef689324a079a2";
  wolfPatchedImage = "nixbox/wolf:${builtins.substring 0 12 wolfRevision}-${wolfPatchSet}";
  wolfSource = pkgs.fetchFromGitHub {
    owner = "games-on-whales";
    repo = "wolf";
    rev = wolfRevision;
    hash = "sha256-5dcMiIgOPY9JtrVpmEUMoETha/cc+tShdaqe8j5ytp8=";
  };
  patchedWolfSource = pkgs.applyPatches {
    name = "wolf-${builtins.substring 0 12 wolfRevision}-${wolfPatchSet}-source";
    src = wolfSource;
    patches = [
      ./wolf-image/altgr.patch
      ./wolf-image/client-presentation-scale.patch
      ./wolf-image/idle-session-timeout.patch
    ];
  };
  wolfBuildContext =
    pkgs.runCommand "wolf-${builtins.substring 0 12 wolfRevision}-${wolfPatchSet}-image-context" {}
    ''
      cp -r ${patchedWolfSource} "$out"
      chmod -R u+w "$out"
      cp ${./wolf-image/Dockerfile} "$out/Dockerfile"
    '';
  browserBaseImage = "ghcr.io/games-on-whales/base-app@sha256:1d7b61da242e767bc5c80c5fe897392b6a9e6854345d3dea6d2f799e7ea98a14";
  wolfUiImage = "ghcr.io/games-on-whales/wolf-ui@sha256:f483f79fcc5f39294067a5029f8de55e5867f74c709a3d55cd6163e4a5f0cf6b";
  heliumVersion = "0.14.7.1";
  heliumDeb = pkgs.fetchurl {
    url = "https://github.com/imputnet/helium-linux/releases/download/${heliumVersion}/helium-bin_${heliumVersion}-1_amd64.deb";
    hash = "sha256-FSSqAA2q64ubpGTBcd6l2VGK4DmSY0FVRNRhu4ZOfIc=";
  };
  mkBrowserContext = {
    name,
    deb,
  }:
    pkgs.runCommand "wolf-${name}-image-context" {} ''
      mkdir -p "$out"
      cp ${./browser-image/Dockerfile} "$out/Dockerfile"
      cp ${./browser-image/startup.sh} "$out/startup.sh"
      cp ${./browser-image/waybar.jsonc} "$out/waybar.jsonc"
      cp ${./browser-image/waybar.css} "$out/waybar.css"
      cp ${deb} "$out/browser.deb"
    '';
  mkNixBrowserContext = {
    name,
    package,
  }: let
    closure = pkgs.closureInfo {rootPaths = [package];};
  in
    pkgs.runCommand "wolf-${name}-image-context" {nativeBuildInputs = [pkgs.gnutar];} ''
      mkdir -p "$out"
      cp ${./browser-image/Dockerfile.nix} "$out/Dockerfile"
      cp ${./browser-image/startup.sh} "$out/startup.sh"
      cp ${./browser-image/waybar.jsonc} "$out/waybar.jsonc"
      cp ${./browser-image/waybar.css} "$out/waybar.css"
      tar \
        --create \
        --file="$out/browser-store.tar" \
        --directory=/ \
        --verbatim-files-from \
        --files-from=${closure}/store-paths
    '';
  browserImages = lib.filter (image: image.enable) [
    {
      enable = browserCfg.helium.enable;
      name = "helium";
      image = browserCfg.helium.image;
      version = heliumVersion;
      executable = "/usr/bin/helium";
      family = "chromium";
      source = "https://github.com/imputnet/helium-linux";
      context = mkBrowserContext {
        name = "helium";
        deb = heliumDeb;
      };
    }
    {
      enable = browserCfg.brave.enable;
      name = "brave";
      image = browserCfg.brave.image;
      version = pkgs.brave.version;
      executable = "/usr/bin/brave-browser-stable";
      family = "chromium";
      source = "https://github.com/brave/brave-browser";
      context = mkBrowserContext {
        name = "brave";
        deb = pkgs.brave.src;
      };
    }
    {
      enable = browserCfg.chromium.enable;
      name = "chromium";
      image = browserCfg.chromium.image;
      version = pkgs.chromium.version;
      executable = "${pkgs.chromium}/bin/chromium";
      family = "chromium";
      source = "https://chromium.googlesource.com/chromium/src";
      context = mkNixBrowserContext {
        name = "chromium";
        package = pkgs.chromium;
      };
    }
    {
      enable = browserCfg.firefox.enable;
      name = "firefox";
      image = browserCfg.firefox.image;
      version = pkgs.firefox.version;
      executable = "${pkgs.firefox}/bin/firefox";
      family = "firefox";
      source = "https://hg.mozilla.org/mozilla-unified";
      context = mkNixBrowserContext {
        name = "firefox";
        package = pkgs.firefox;
      };
    }
    {
      enable = browserCfg.zen.enable;
      name = "zen";
      image = browserCfg.zen.image;
      version = pkgs.zen-browser.version;
      executable = "${pkgs.zen-browser}/bin/zen";
      family = "firefox";
      source = "https://github.com/zen-browser/desktop";
      context = mkNixBrowserContext {
        name = "zen";
        package = pkgs.zen-browser;
      };
    }
  ];
  managedRunnerNames =
    [
      "Wolf-UI"
    ]
    ++ lib.optional browserCfg.helium.enable "WolfHelium"
    ++ lib.optional browserCfg.helium.enable "WolfHeliumPrivate"
    ++ lib.optional browserCfg.brave.enable "WolfBrave"
    ++ lib.optional browserCfg.chromium.enable "WolfChromium"
    ++ lib.optional browserCfg.firefox.enable "WolfFirefox"
    ++ lib.optional browserCfg.zen.enable "WolfZen";
  cleanupManagedContainers =
    lib.concatMapStringsSep "\n" (runnerName: ''
      ${pkgs.docker}/bin/docker ps -aq --filter ${lib.escapeShellArg "name=^/${runnerName}_"} \
        | while read -r container; do
          if [ -n "$container" ]; then
            ${pkgs.docker}/bin/docker rm -f "$container"
          fi
        done
    '')
    managedRunnerNames;
  browserHostConfig = builtins.toJSON {
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
  }: {
    inherit title;
    icon_png_path = icon;
    start_virtual_compositor = true;
    start_audio_server = true;
    runner = {
      type = "docker";
      name = runnerName;
      inherit image;
      mounts = [
        "/run/wolf-streaming/libnvidia-allocator.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.1:ro"
      ];
      env = [
        "RUN_SWAY=1"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
        "NIXBOX_BROWSER_SCALE=1.0"
        "XKB_DEFAULT_LAYOUT=${lib.concatStringsSep "," browserCfg.keyboardLayouts}"
        "XKB_DEFAULT_OPTIONS=grp:alt_shift_toggle,lv3:ralt_switch"
      ];
      devices = [];
      ports = [];
      base_create_json = browserHostConfig;
    };
  };
  managedMoonlightApps =
    [
      {
        title = "Wolf UI";
        icon_png_path = "https://raw.githubusercontent.com/games-on-whales/wolf-ui/refs/heads/main/src/Icons/wolf_ui_icon.png";
        start_virtual_compositor = true;
        runner = {
          type = "docker";
          name = "Wolf-UI";
          image = wolfUiImage;
          mounts = [
            "/run/wolf-streaming/runtime/wolf.sock:/var/run/wolf/wolf.sock"
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
      }
    ]
    ++ lib.optional browserCfg.helium.publish (mkMoonlightBrowserApp {
      title = "Helium";
      runnerName = "WolfHelium";
      image = browserCfg.helium.image;
      icon = "https://helium.computer/favicon.png";
    })
    ++ lib.optional browserCfg.brave.publish (mkMoonlightBrowserApp {
      title = "Brave";
      runnerName = "WolfBrave";
      image = browserCfg.brave.image;
      icon = "https://brave.com/static-assets/images/brave-logo-sans-text.svg";
    });
  managedMoonlightAppsFile = pkgs.writeText "wolf-managed-moonlight-apps.json" (
    builtins.toJSON {
      managedTitles =
        [
          "Wolf UI"
          "Helium"
          "Brave"
        ]
        ++ cfg.prunedApplicationTitles;
      apps = managedMoonlightApps;
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
  buildBrowserImages = pkgs.writeShellApplication {
    name = "build-wolf-browser-images";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.docker
    ];
    text = ''
      set -euo pipefail

      docker image inspect ${lib.escapeShellArg browserBaseImage} >/dev/null 2>&1 \
        || docker pull ${lib.escapeShellArg browserBaseImage}

      docker image inspect ${lib.escapeShellArg wolfUiImage} >/dev/null 2>&1 \
        || docker pull ${lib.escapeShellArg wolfUiImage}

      ${lib.concatMapStringsSep "\n" (image: ''
          docker build \
            --pull=false \
            --build-arg BASE_APP_IMAGE=${lib.escapeShellArg browserBaseImage} \
            --build-arg BROWSER_EXECUTABLE=${lib.escapeShellArg image.executable} \
            --build-arg BROWSER_FAMILY=${lib.escapeShellArg image.family} \
            --build-arg IMAGE_SOURCE=${lib.escapeShellArg image.source} \
            --build-arg IMAGE_VERSION=${lib.escapeShellArg image.version} \
            --tag ${lib.escapeShellArg image.image} \
            ${lib.escapeShellArg image.context}
        '')
        browserImages}
    '';
  };
  wolfSetClientPresentationScale = pkgs.writeText "wolf-set-client-presentation-scale.py" ''
    import json
    import socket
    import sys

    client_id, scale = sys.argv[1:]
    payload = json.dumps(
        {
            "client_id": client_id,
            "settings": {"presentation_scale": float(scale)},
        },
        separators=(",", ":"),
    ).encode()
    request = (
        b"POST /api/v1/clients/settings HTTP/1.1\r\n"
        b"Host: localhost\r\n"
        b"Content-Type: application/json\r\n"
        + f"Content-Length: {len(payload)}\r\n".encode()
        + b"Connection: close\r\n\r\n"
        + payload
    )

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect("/run/wolf-streaming/runtime/wolf.sock")
        connection.sendall(request)
        response = bytearray()
        while chunk := connection.recv(65536):
            response.extend(chunk)

    status_line = bytes(response).split(b"\r\n", 1)[0]
    if b" 200 " not in status_line:
        raise RuntimeError(status_line.decode(errors="replace"))
  '';

  wolfStreamLayout = pkgs.writeShellApplication {
    name = "wolf-stream-layout";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.docker
    ];
    text = ''
      presentation_scale=1.0
      if [ "''${1:-}" = --presentation-scale ]; then
        [ -n "''${2:-}" ] || {
          echo "wolf-stream-layout: --presentation-scale requires a value" >&2
          exit 2
        }
        presentation_scale="$2"
        shift 2
      fi
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
          echo "usage: wolf-stream-layout [--presentation-scale {1.0|1.5}] {${lib.concatStringsSep "|" browserCfg.keyboardLayouts}} RUNNER [RUNNER ...]" >&2
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
              -e SWAYSOCK=/run/wolf-streaming/runtime/sway.socket \
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
              docker exec -i wolf python3 - "$client_id" "$presentation_scale" \
                < ${wolfSetClientPresentationScale} \
                >/dev/null 2>&1 || true
            fi
            docker exec \
              -u ${toString cfg.defaultRunUid} \
              -e SWAYSOCK=/run/wolf-streaming/runtime/sway.socket \
              "$container" \
              swaymsg seat seat0 xcursor_theme Adwaita "$cursor_size" \
                >/dev/null 2>&1 || true
            # TV-oriented Nixbox clients render a responsive cursor locally in
            # Moonlight. Hide Wolf's remote cursor after activity so absolute
            # virtual pointers cannot leave a stale click-position cursor in
            # the stream. Desktop clients retain the normal remote cursor.
            if [ "$presentation_scale" = 1.5 ]; then
              docker exec \
                -u ${toString cfg.defaultRunUid} \
                -e SWAYSOCK=/run/wolf-streaming/runtime/sway.socket \
                "$container" \
                swaymsg seat seat0 hide_cursor 1 \
                  >/dev/null 2>&1 || true
            else
              docker exec \
                -u ${toString cfg.defaultRunUid} \
                -e SWAYSOCK=/run/wolf-streaming/runtime/sway.socket \
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
  buildPatchedWolfImage = pkgs.writeShellApplication {
    name = "build-patched-wolf-image";
    runtimeInputs = [pkgs.docker];
    text = ''
      set -euo pipefail

      if docker image inspect ${lib.escapeShellArg wolfPatchedImage} >/dev/null 2>&1; then
        exit 0
      fi

      docker image inspect ${lib.escapeShellArg wolfBaseImage} >/dev/null 2>&1 \
        || docker pull ${lib.escapeShellArg wolfBaseImage}

      docker build \
        --pull=false \
        --build-arg RUNTIME_IMAGE=${lib.escapeShellArg wolfBaseImage} \
        --tag ${lib.escapeShellArg wolfPatchedImage} \
        ${lib.escapeShellArg wolfBuildContext}
    '';
  };
  # GStreamer's CUDA conversion elements load NVRTC dynamically. The
  # upstream Wolf image deliberately does not bundle it, while NixOS' NVIDIA
  # CDI specification only injects driver libraries. Copy the runtime pieces
  # from the CUDA redistributable source without pulling in the full toolkit.
  nvrtcRuntime = pkgs.runCommand "wolf-nvrtc-runtime" {} ''
    mkdir -p "$out/lib"
    cp ${pkgs.cudaPackages.cuda_nvrtc.src}/lib/libnvrtc.so.* "$out/lib/"
    cp ${pkgs.cudaPackages.cuda_nvrtc.src}/lib/libnvrtc-builtins.so.* "$out/lib/"

    for library in libnvrtc libnvrtc-builtins; do
      set -- "$out/lib/$library.so."*
      ln -s "$(basename "$1")" "$out/lib/$library.so"
    done
  '';
  wolfVramWatchdog = pkgs.writeShellApplication {
    name = "wolf-vram-watchdog";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.systemd
    ];
    text = ''
      state_file=/run/wolf-streaming/vram-high-count

      if ! systemctl --quiet is-active docker-wolf.service; then
        rm -f "$state_file"
        exit 0
      fi

      total_mib="$(
        ${nvidiaSmi} \
          --query-gpu=memory.total \
          --format=csv,noheader,nounits \
          | awk -F, 'NR == 1 { gsub(/[[:space:]]/, "", $1); print $1 }'
      )"
      wolf_mib="$(
        ${nvidiaSmi} \
          --query-compute-apps=process_name,used_memory \
          --format=csv,noheader,nounits \
          | awk -F, '
              $1 ~ /\/wolf$/ {
                gsub(/[[:space:]]/, "", $2)
                total += $2
              }
              END { print total + 0 }
            '
      )"

      if ! [[ "$total_mib" =~ ^[1-9][0-9]*$ && "$wolf_mib" =~ ^[0-9]+$ ]]; then
        echo "Wolf VRAM watchdog could not parse the NVIDIA memory sample" >&2
        exit 1
      fi

      threshold_mib=$((total_mib * ${toString cfg.vramWatchdog.maxUsedPercent} / 100))
      if [ "$wolf_mib" -lt "$threshold_mib" ]; then
        rm -f "$state_file"
        exit 0
      fi

      count=0
      if [ -r "$state_file" ]; then
        read -r count < "$state_file" || count=0
      fi
      [[ "$count" =~ ^[0-9]+$ ]] || count=0
      count=$((count + 1))
      printf '%s\n' "$count" > "$state_file"

      if [ "$count" -lt ${toString cfg.vramWatchdog.consecutiveSamples} ]; then
        echo "Wolf VRAM remains high: $wolf_mib MiB of $total_mib MiB (sample $count/${toString cfg.vramWatchdog.consecutiveSamples})" >&2
        exit 0
      fi

      rm -f "$state_file"
      echo "Restarting Wolf after sustained VRAM growth: $wolf_mib MiB of $total_mib MiB" >&2
      systemctl restart docker-wolf.service
    '';
  };
  wolfPipelineWatchdog = pkgs.writeShellApplication {
    name = "wolf-pipeline-watchdog";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.docker
      pkgs.gnugrep
      pkgs.systemd
    ];
    text = ''
      state_dir=/var/lib/wolf-pipeline-watchdog
      cursor_file="$state_dir/log-cursor"
      pending_file="$state_dir/recovery-pending"

      if ! systemctl --quiet is-active docker-wolf.service; then
        exit 0
      fi

      now="$(date --iso-8601=seconds)"
      if [ -r "$cursor_file" ]; then
        read -r since < "$cursor_file"
      else
        since="$(docker inspect --format '{{.State.StartedAt}}' wolf)"
      fi
      printf '%s\n' "$now" > "$cursor_file"

      log_sample="$(mktemp)"
      trap 'rm -f "$log_sample"' EXIT
      docker logs --since "$since" wolf > "$log_sample" 2>&1 || true

      # Both signatures leave Wolf running while its video path can no longer
      # produce frames.  They are deliberately narrower than generic
      # GStreamer warnings, which are common during normal disconnects.
      if grep -aEq \
        'Failed to map input buffer|Unhandled exception: stoull' \
        "$log_sample"; then
        touch "$pending_file"
      fi

      if [ ! -e "$pending_file" ]; then
        exit 0
      fi

      # Never destroy a healthy concurrent stream.  Once Moonlight has timed
      # out the poisoned stream, the API reports no active sessions and it is
      # safe to rebuild Wolf's coordinator and encoder state.  Persistent app
      # homes remain on disk; docker-wolf's pre-start removes only unusable
      # runner containers.
      if ! active_sessions="$(
        docker exec -i wolf python3 - <<'PY'
import json
import socket

connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
connection.settimeout(2)
connection.connect("/run/wolf-streaming/runtime/wolf.sock")
connection.sendall(
    b"GET /api/v1/sessions HTTP/1.1\r\n"
    b"Host: localhost\r\n"
    b"Connection: close\r\n\r\n"
)
response = bytearray()
while chunk := connection.recv(65536):
    response.extend(chunk)
body = bytes(response).split(b"\r\n\r\n", 1)[1]
print(len(json.loads(body).get("sessions", [])))
PY
      )"; then
        echo "Wolf pipeline recovery deferred: session API unavailable" >&2
        exit 1
      fi

      if ! [[ "$active_sessions" =~ ^[0-9]+$ ]]; then
        echo "Wolf pipeline recovery deferred: invalid session count" >&2
        exit 1
      fi
      if [ "$active_sessions" -ne 0 ]; then
        echo "Wolf pipeline recovery pending behind $active_sessions active session(s)" >&2
        exit 0
      fi

      echo "Restarting Wolf after an unrecoverable video-pipeline failure" >&2
      systemctl restart docker-wolf.service
      rm -f "$pending_file"
    '';
  };
in {
  options.services.wolf-streaming = {
    enable = lib.mkEnableOption "Wolf Moonlight application streaming";

    image = lib.mkOption {
      type = lib.types.str;
      default = wolfPatchedImage;
      description = "Pinned amd64 Wolf container image.";
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/wolf";
      description = "Persistent Wolf certificates, pairings, profiles, and application state.";
    };

    renderNode = lib.mkOption {
      type = lib.types.str;
      default = "/dev/dri/renderD128";
      description = "DRM render node used for virtual desktops and video encoding.";
    };

    defaultRunUid = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1000;
      description = "Default UID assigned to newly paired Wolf application profiles.";
    };

    defaultRunGid = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1000;
      description = "Default GID assigned to newly paired Wolf application profiles.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open Wolf's documented Moonlight protocol ports.";
    };

    sessionIdleTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        Seconds a disconnected stream or empty resumable lobby may remain
        available before Wolf stops it. Reconnecting to the stream or joining
        the lobby cancels the deadline. Zero disables idle expiry.
      '';
    };

    vramWatchdog = {
      enable = lib.mkEnableOption "automatic recovery from sustained Wolf GPU-memory growth";

      maxUsedPercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 80;
        description = "Percentage of total GPU memory Wolf may retain before recovery is considered.";
      };

      consecutiveSamples = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "Consecutive high-memory samples required before Wolf is restarted.";
      };

      interval = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "30s";
        description = "Systemd time span between Wolf GPU-memory checks.";
      };
    };

    pipelineWatchdog = {
      enable = lib.mkEnableOption "automatic recovery from fatal Wolf video-pipeline failures";

      interval = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "15s";
        description = "Systemd time span between Wolf video-pipeline health checks.";
      };
    };

    prunedApplicationTitles = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [];
      description = ''
        Application titles to remove from Wolf's direct Moonlight profile
        during reconciliation. Persistent application homes are not deleted.
      '';
    };

    browserImages = {
      enable = lib.mkEnableOption "locally built Wolf browser application images";

      keyboardLayouts = lib.mkOption {
        type = lib.types.nonEmptyListOf (
          lib.types.enum [
            "no"
            "us"
            "ru"
          ]
        );
        default = [
          "no"
          "us"
          "ru"
        ];
        description = "Ordered XKB layouts exposed inside each streamed browser; Alt+Shift cycles them.";
      };

      helium = {
        enable = lib.mkEnableOption "the Helium Wolf application image";
        publish = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Publish Helium directly in the Moonlight application list.";
        };
        image = lib.mkOption {
          type = lib.types.str;
          default = "nixbox/wolf-helium:${heliumVersion}";
          description = "Local Docker image name used by the Helium Wolf application.";
        };
      };

      brave = {
        enable = lib.mkEnableOption "the Brave Wolf application image";
        publish = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Publish Brave directly in the Moonlight application list; leave disabled for protected profiles.";
        };
        image = lib.mkOption {
          type = lib.types.str;
          default = "nixbox/wolf-brave:${pkgs.brave.version}";
          description = "Local Docker image name used by the Brave Wolf application.";
        };
      };

      chromium = {
        enable = lib.mkEnableOption "the Chromium Wolf application image";
        image = lib.mkOption {
          type = lib.types.str;
          default = "nixbox/wolf-chromium:${pkgs.chromium.version}";
          description = "Local Docker image name used by the protected Chromium application.";
        };
      };

      firefox = {
        enable = lib.mkEnableOption "the Firefox Wolf application image";
        image = lib.mkOption {
          type = lib.types.str;
          default = "nixbox/wolf-firefox:${pkgs.firefox.version}";
          description = "Local Docker image name used by the protected Firefox application.";
        };
      };

      zen = {
        enable = lib.mkEnableOption "the Zen Wolf application image";
        image = lib.mkOption {
          type = lib.types.str;
          default = "nixbox/wolf-zen:${pkgs.zen-browser.version}";
          description = "Local Docker image name used by the protected Zen application.";
        };
      };
    };

    protectedProfile = {
      definitionFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/run/credentials/docker-wolf.service/protected-profile";
        description = ''
          Root-only runtime JSON file defining the protected Wolf profile id,
          internal name, and PIN. Keep this file outside the Nix store. When
          set, protected browser applications are published only inside that
          profile and the file is loaded as a systemd credential before Wolf
          starts.
        '';
      };

      displayName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "User";
        description = ''
          Neutral public label shown for the protected profile in Wolf UI.
          This deliberately overrides the private credential's internal name.
        '';
      };
    };
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
        assertion = lib.hasPrefix "/dev/dri/renderD" cfg.renderNode;
        message = "services.wolf-streaming.renderNode must name a DRM render node";
      }
      {
        assertion = !browserCfg.enable || browserImages != [];
        message = "services.wolf-streaming.browserImages requires at least one browser image";
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

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDirectory} 0700 root root - -"
      "d /run/wolf-streaming 0755 root root - -"
      "d /run/wolf-streaming/runtime 0700 root root - -"
      "L+ /run/wolf-streaming/libnvidia-allocator.so.1 - - - - ${nvidiaPackage}/lib/libnvidia-allocator.so.1"
    ];

    virtualisation.oci-containers = {
      backend = "docker";
      containers.wolf = {
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
    };

    environment.systemPackages = lib.optional browserCfg.enable wolfStreamLayout;

    systemd.services.docker-wolf = {
      after =
        [
          "docker.service"
          "nvidia-container-toolkit-cdi-generator.service"
        ]
        ++ lib.optional (cfg.protectedProfile.definitionFile != null) "sops-install-secrets.service";
      requires = ["docker.service"];
      serviceConfig.LoadCredential = lib.mkIf (cfg.protectedProfile.definitionFile != null) [
        "wolf-protected-profile:${cfg.protectedProfile.definitionFile}"
      ];
      preStart = lib.mkIf browserCfg.enable (
        ''
          # Wolf cannot resume application containers that outlive a
          # coordinator restart. Remove only containers created by the managed
          # runners before loading the reconciled application catalog.
          ${cleanupManagedContainers}

          ${lib.getExe reconcileWolfApps} \
            ${lib.escapeShellArg "${cfg.stateDirectory}/cfg/config.toml"} \
            ${lib.escapeShellArg managedMoonlightAppsFile}
        ''
        + lib.optionalString (cfg.protectedProfile.definitionFile != null) ''
          ${lib.getExe reconcileWolfProtectedProfile} \
            ${lib.escapeShellArg "${cfg.stateDirectory}/cfg/config.toml"} \
            "$CREDENTIALS_DIRECTORY/wolf-protected-profile" \
            ${lib.escapeShellArg protectedBrowserAppsFile} \
            ${lib.escapeShellArg cfg.protectedProfile.displayName}
        ''
      );
    };

    systemd.services.wolf-vram-watchdog = lib.mkIf cfg.vramWatchdog.enable {
      description = "Recover Wolf from sustained GPU-memory growth";
      after = ["docker-wolf.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe wolfVramWatchdog;
      };
    };

    systemd.timers.wolf-vram-watchdog = lib.mkIf cfg.vramWatchdog.enable {
      description = "Periodically check Wolf GPU-memory usage";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = cfg.vramWatchdog.interval;
        OnUnitActiveSec = cfg.vramWatchdog.interval;
        Unit = "wolf-vram-watchdog.service";
      };
    };

    systemd.services.wolf-pipeline-watchdog = lib.mkIf cfg.pipelineWatchdog.enable {
      description = "Recover Wolf from fatal video-pipeline failures";
      after = ["docker-wolf.service"];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "wolf-pipeline-watchdog";
        ExecStart = lib.getExe wolfPipelineWatchdog;
      };
    };

    systemd.timers.wolf-pipeline-watchdog = lib.mkIf cfg.pipelineWatchdog.enable {
      description = "Periodically check Wolf video-pipeline health";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = cfg.pipelineWatchdog.interval;
        OnUnitActiveSec = cfg.pipelineWatchdog.interval;
        Unit = "wolf-pipeline-watchdog.service";
      };
    };

    systemd.services.wolf-patched-image = lib.mkIf (cfg.image == wolfPatchedImage) {
      description = "Build the pinned Wolf image with AltGr modifier tracking";
      after = ["docker.service"];
      before = ["docker-wolf.service"];
      requires = ["docker.service"];
      requiredBy = ["docker-wolf.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe buildPatchedWolfImage;
      };
    };

    systemd.services.wolf-browser-images = lib.mkIf browserCfg.enable {
      description = "Build local Wolf browser application images";
      after = ["docker.service"];
      before = ["docker-wolf.service"];
      requires = ["docker.service"];
      requiredBy = ["docker-wolf.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe buildBrowserImages;
      };
    };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [
        47984
        47989
        48010
      ];
      allowedUDPPorts = [
        47999
        48100
        48200
      ];
    };
  };
}
