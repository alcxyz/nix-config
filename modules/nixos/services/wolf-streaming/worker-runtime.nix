{
  config,
  lib,
  pkgs,
  ...
}: let
  runtimeRoot = "/run/nixbox-private-browser-worker";
  publicRuntimeRoot = "/run/nixbox-public-browser-worker";
  publicKdeConnectHostPort = 1716;
  nvidiaPackage = config.hardware.nvidia.package;
  nvrtcRuntime = pkgs.callPackage ./nvrtc-runtime.nix {};
  workerStreamLayout = pkgs.writeShellApplication {
    name = "k8s-wolf-stream-layout";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.docker
    ];
    text = ''
      presentation_scale=1.0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --presentation-scale)
            [ -n "''${2:-}" ] || {
              echo "k8s-wolf-stream-layout: --presentation-scale requires a value" >&2
              exit 2
            }
            presentation_scale="$2"
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
          echo "k8s-wolf-stream-layout: unsupported presentation scale: $presentation_scale" >&2
          exit 2
          ;;
      esac

      layout="''${1:-}"
      shift || true
      runners=("$@")
      case "$layout" in
        no) layout_index=0 ;;
        us) layout_index=1 ;;
        *)
          echo "usage: k8s-wolf-stream-layout [--presentation-scale {1.0|1.5}] {no|us} RUNNER [RUNNER ...]" >&2
          exit 2
          ;;
      esac
      if [ "''${#runners[@]}" -eq 0 ]; then
        echo "k8s-wolf-stream-layout requires at least one runner" >&2
        exit 2
      fi

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
              -u 1000 \
              "$container" \
              sh -c '
                if [ -e /tmp/nixbox-browser-presentation/ready ]; then
                  printf "%s\n" "$1" > /tmp/nixbox-browser-presentation/requested-scale
                fi
              ' sh "$presentation_scale" \
                >/dev/null 2>&1 \
            && docker exec \
              -u 1000 \
              -e "SWAYSOCK=${runtimeRoot}/runtime/sway.socket" \
              "$container" \
              swaymsg input type:keyboard xkb_switch_layout "$layout_index" \
                >/dev/null 2>&1; then
            docker exec \
              -u 1000 \
              -e "SWAYSOCK=${runtimeRoot}/runtime/sway.socket" \
              "$container" \
              swaymsg seat seat0 xcursor_theme Adwaita "$cursor_size" \
                >/dev/null 2>&1 || true
            if [ "$presentation_scale" = 1.5 ]; then
              hide_cursor=1
            else
              hide_cursor=0
            fi
            docker exec \
              -u 1000 \
              -e "SWAYSOCK=${runtimeRoot}/runtime/sway.socket" \
              "$container" \
              swaymsg seat seat0 hide_cursor "$hide_cursor" \
                >/dev/null 2>&1 || true
            exit 0
          fi
        done
        sleep 0.25
      done

      echo "none of the streamed runners exposed a keyboard in time: ''${runners[*]}" >&2
      exit 1
    '';
  };
in {
  assertions = [
    {
      assertion = config.hardware.nvidia-container-toolkit.enable;
      message = "The Wolf worker runtime requires the NVIDIA container toolkit";
    }
  ];

  # Kubernetes starts the coordinator through the node-local Docker API. Give
  # that supervisor stable host paths instead of exposing generation-specific
  # Nix store paths in GitOps.
  systemd.tmpfiles.rules = [
    "d ${runtimeRoot} 0700 root root - -"
    "d ${runtimeRoot}/runtime 0700 root root - -"
    "d ${publicRuntimeRoot} 0700 root root - -"
    "d ${publicRuntimeRoot}/runtime 0700 root root - -"
    "L+ ${runtimeRoot}/libnvidia-allocator.so.1 - - - - ${nvidiaPackage}/lib/libnvidia-allocator.so.1"
    "L+ ${runtimeRoot}/nvrtc - - - - ${nvrtcRuntime}"
    "L+ ${runtimeRoot}/10_nvidia.json - - - - ${nvidiaPackage}/share/glvnd/egl_vendor.d/10_nvidia.json"
  ];

  environment.systemPackages = [workerStreamLayout];

  # The Kubernetes supervisor starts Wolf with host networking. Expose its
  # isolated Moonlight port sets on every qualified worker so either
  # rescheduled singleton remains reachable without host-specific exceptions.
  networking.firewall = {
    allowedTCPPorts = [
      publicKdeConnectHostPort
      47984
      47989
      48010
      49984
      49989
      50010
      48984
      48989
      49010
    ];
    allowedUDPPorts = [
      publicKdeConnectHostPort
      47999
      48100
      48200
      49999
      50100
      50200
      48999
      49100
      49200
    ];
  };
}
