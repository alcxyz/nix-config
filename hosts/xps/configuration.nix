# nix-config/hosts/xps/configuration.nix
{
  config,
  pkgs,
  inputs,
  username,
  hostRole,
  configDir,
  lib,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
  steamHeadlessStartCommand = lib.escapeShellArgs [
    "${pkgs.openssh}/bin/ssh"
    "-o"
    "BatchMode=yes"
    "-o"
    "ConnectTimeout=5"
    "xyz"
    "bash -lc ${lib.escapeShellArg "cd /home/alc/src/infra/gitops/docker/xyz/steam && docker compose up -d"}"
  ];
  displayPipelineSetupScript = ''
    internal_connector=""
    for attempt in $(seq 1 "''${XPS_DISPLAY_PIPELINE_ATTEMPTS:-50}"); do
      for candidate in /sys/class/drm/card*-eDP-1; do
        if [ -w "$candidate/status" ]; then
          internal_connector="$candidate"
          break 2
        fi
      done
      sleep 0.1
    done

    if [ -z "$internal_connector" ]; then
      echo "internal display connector did not appear" >&2
      exit 1
    fi

    # Allow dock authorization and EDID probing to settle. Stop waiting as
    # soon as all three external connectors are visible.
    external_count=0
    for attempt in $(seq 1 "''${XPS_DISPLAY_PIPELINE_ATTEMPTS:-50}"); do
      external_count=0
      for status_file in /sys/class/drm/card*-*/status; do
        case "$status_file" in
          *-eDP-* | *-LVDS-*) continue ;;
        esac
        if [ "$(cat "$status_file")" = connected ]; then
          external_count=$((external_count + 1))
        fi
      done
      if [ "$external_count" -ge 3 ]; then
        break
      fi
      sleep 0.1
    done

    if [ "$external_count" -ge 3 ]; then
      printf off > "$internal_connector/status"
    else
      printf detect > "$internal_connector/status"
    fi

    if [ -n "''${XPS_DISPLAY_PIPELINE_MARKER:-}" ]; then
      printf '%s\n' "$external_count" > "$XPS_DISPLAY_PIPELINE_MARKER"
    fi
  '';
in {
  imports = [
    ./hardware-configuration.nix
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/hardware/nvidia.nix"
    "${configDir}/modules/nixos/services/moonlight-client/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  boot.initrd.systemd.enable = true;
  # Plymouth can mirror across every DRM head it knows about, but the external
  # Intel/dock connectors otherwise appear only near the end of userspace boot.
  # Load (and include) this display path in the initrd so the splash is visible
  # while boot progress is actually happening. Keep the broad hardware module
  # inventory from hardware-configuration.nix unchanged.
  boot.initrd.kernelModules = lib.mkAfter [
    "thunderbolt"
    "i915"
  ];
  # Let the early drivers finish connector discovery and apply the same
  # three-external/internal-fallback policy before Plymouth starts. This keeps
  # pipeline reallocation from interrupting the visible boot animation.
  boot.initrd.systemd.services.xps-display-pipeline-setup = {
    description = "Prepare XPS display pipelines for the boot splash";
    before = ["plymouth-start.service"];
    after = [
      "systemd-modules-load.service"
      "systemd-udev-trigger.service"
    ];
    wantedBy = ["sysinit.target"];
    path = [pkgs.coreutils];
    environment = {
      XPS_DISPLAY_PIPELINE_ATTEMPTS = "20";
      XPS_DISPLAY_PIPELINE_MARKER = "/run/xps-display-pipeline-external-count";
    };
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    script = displayPipelineSetupScript;
  };
  boot.initrd.systemd.services.plymouth-start = {
    requires = ["xps-display-pipeline-setup.service"];
    after = ["xps-display-pipeline-setup.service"];
  };
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.plymouth = {
    enable = true;
    theme = "nixbox";
    themePackages = [pkgs.nixbox-plymouth-theme];
    # Render the lightweight intro and genuine progress hold on the firmware
    # framebuffer. The compositor owns the animated outro after boot.
    extraConfig = "UseSimpledrmNoLuks=1";
  };

  # Standard Plymouth teardown leaves a gap before greetd launches the
  # compositor. Retain the completed frame while releasing DRM ownership so
  # Hyprland can replace it directly with the matching Quickshell outro.
  systemd.services.plymouth-quit.serviceConfig.ExecStart = lib.mkForce [
    ""
    "${lib.getExe' pkgs.plymouth "plymouth"} quit --retain-splash"
  ];

  # The couch power actions already animate while Hyprland owns the outputs.
  # Do not start a second Plymouth animation after the compositor exits.
  systemd.services.plymouth-poweroff.wantedBy = lib.mkForce [];
  systemd.services.plymouth-reboot.wantedBy = lib.mkForce [];
  systemd.services.plymouth-halt.wantedBy = lib.mkForce [];

  # Activation can legitimately request wrapper regeneration several times
  # during early boot. Every run is idempotent; do not report a false failure
  # merely because systemd's default start-rate limit was reached.
  systemd.services.suid-sgid-wrappers.unitConfig.StartLimitIntervalSec = 0;

  # Keep recovery TTYs usable with the laptop's Norwegian keyboard. Graphical
  # sessions manage their own us/no layout and toggle independently.
  console.useXkbConfig = lib.mkForce false;
  console.keyMap = "no";

  environment.systemPackages =
    pkgsets.system.${hostRole.systemPackageSet}
    ++ [
      pkgs.bolt
    ];

  hardware.enableRedistributableFirmware = true;
  hardware.nvidia.enable = true;

  # The Intel HDA controller exposes one PCM per physical display path. Keep
  # them simultaneous so DMS and the couch shortcuts can select an output
  # without changing the whole card profile first.
  services.pipewire.wireplumber.extraConfig."51-xps-couch-audio" = {
    "monitor.alsa.rules" = [
      {
        matches = [
          {
            "device.name" = "~alsa_card.pci-.*";
            "api.alsa.card.name" = "HDA Intel PCH";
          }
        ];
        actions."update-props" = {
          "api.alsa.use-acp" = false;
          "device.profile" = "pro-audio";
          "api.acp.auto-profile" = false;
          "api.acp.auto-port" = false;
        };
      }
      {
        matches = [{"node.name" = "~alsa_output.*[.]playback[.]0[.]0";}];
        actions."update-props" = {
          "node.description" = "XPS speakers";
          "node.nick" = "XPS speakers";
          "priority.session" = 900;
        };
      }
      {
        matches = [{"node.name" = "~alsa_output.*[.]playback[.]3[.]0";}];
        actions."update-props" = {
          "node.description" = "Primary TV";
          "node.nick" = "Primary TV";
          "priority.session" = 1100;
        };
      }
      {
        matches = [{"node.name" = "~alsa_output.*[.]playback[.]7[.]0";}];
        actions."update-props" = {
          "node.description" = "Secondary TV";
          "node.nick" = "Secondary TV";
          "priority.session" = 1200;
        };
      }
      {
        matches = [{"node.name" = "~alsa_output.*[.]playback[.]8[.]0";}];
        actions."update-props" = {
          "node.description" = "Auxiliary display";
          "node.nick" = "Auxiliary display";
          "priority.session" = 1000;
        };
      }
    ];
    "monitor.bluez.rules" = [
      {
        matches = [{"device.form-factor" = "speaker";}];
        actions."update-props"."device.profile" = "a2dp-sink";
      }
    ];
  };

  # Present the two TV paths as one optional stereo sink. PipeWire keeps a
  # playback stream connected to each physical sink and compensates for their
  # latency difference; selecting either physical sink remains possible.
  services.pipewire.extraConfig.pipewire."52-xps-dual-tv-output" = {
    "context.modules" = [
      {
        name = "libpipewire-module-combine-stream";
        args = {
          "combine.mode" = "sink";
          "node.name" = "xps_dual_tv";
          "node.description" = "Both TVs";
          "combine.latency-compensate" = true;
          "combine.props" = {
            "audio.position" = ["FL" "FR"];
            "node.virtual" = true;
            # Keep it immediately after Primary TV in the couch audio cycle,
            # while leaving physical TV sinks ahead for fresh-session defaults.
            "priority.session" = 1050;
            # PipeWire stores linear amplitude; 0.064 is 40% on its cubic
            # user-facing volume scale.
            "state.default-volume" = "0.064";
          };
          "stream.props" = {};
          "stream.rules" = [
            {
              matches = [
                {
                  "media.class" = "Audio/Sink";
                  "node.name" = "~alsa_output.*[.]playback[.](3|7)[.]0";
                }
              ];
              actions."create-stream" = {
                "combine.audio.position" = ["FL" "FR"];
                "audio.position" = ["FL" "FR"];
              };
            }
          ];
        };
      }
    ];
  };

  users.users.${username}.extraGroups = [
    "video"
    "render"
  ];

  programs.hyprlock.enable = true;
  services.accounts-daemon.enable = true;
  system.activationScripts.accountsServiceIcon = {
    text = ''
      install -d -m755 /var/lib/AccountsService/icons
      install -d -m755 /var/lib/AccountsService/users
      install -m644 ${configDir}/users/${username}/profile.jpg \
        /var/lib/AccountsService/icons/${username}
      if [ ! -f /var/lib/AccountsService/users/${username} ]; then
        printf '[User]\nIcon=/var/lib/AccountsService/icons/${username}\nSystemAccount=false\n' \
          > /var/lib/AccountsService/users/${username}
      fi
    '';
    deps = [];
  };

  services.displayManager.gdm.enable = false;
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --remember-session --sessions /run/current-system/sw/share/wayland-sessions";
      user = "greeter";
    };
  };

  services.moonlight-client = {
    enable = true;
    autoLoginUser = username;
    desktopSessionCommand = "${pkgs.uwsm}/bin/uwsm start -e -D Hyprland hyprland.desktop";
    defaultSessionMode = "couch";
    # A boot-time pipeline check hides this panel only when all three external
    # displays are connected. With fewer externals it remains available for
    # local maintenance and debugging.
    disableInternalDisplay = false;
    enableDms = false;
    enableMergedProfile = true;
    enableKdeConnect = true;
    enableControllerShortcuts = true;
    keyboardLayouts = "no,us";
    keyboardOptions = "grp:alt_shift_toggle";
    browserScaleFactor = 1.5;
    sessionSplashCommand = lib.getExe pkgs.nixbox-session-splash;
    autoStartBrowser = true;
    autoStartStream = false;
    fallbackBrowserPackage = null;
    protectedBrowserPackage = pkgs.brave;
    protectedBrowserName = "Brave (Private)";
    protectedBrowserIcon = "${pkgs.brave}/opt/brave.com/brave/product_logo_256.png";
    protectedBrowserCommandName = "brave";
    protectedBrowserEncryptedDirectory = "brave-couch-private";
    protectedBrowserLegacyProfileDirectory = "/run/moonlight-client/dms-merged/BraveSoftware/Brave-Browser";
    moonlightPlatform = "xcb";
    outputMode = "2560x1440@60";
    mirrorOutputMode = "1920x1080@60";
    fallbackOutputMode = "1920x1080@60";
    outputScale = 1.0;
    autoLayoutExternalOutputs = true;
    autoLayoutSecondaryModes = [
      "2560x1440@60"
      "1920x1080@60"
    ];
    autoLayoutSecondaryPosition = "2560x0";
    autoMirrorSecondaryPosition = "1920x0";
    autoLayoutSecondaryScale = 1.0;
    autoLayoutTertiaryPosition = "5120x0";
    autoMirrorTertiaryPosition = "3840x0";
    autoLayoutTertiaryScale = 1.0;
    autoLayoutPrimaryMinPhysicalWidth = 1000;
    autoLayoutPrimaryWorkspaces = [
      1
      2
      3
    ];
    autoLayoutSecondaryWorkspaces = [
      4
      5
      6
    ];
    autoLayoutTertiaryWorkspaces = [
      7
      8
      9
    ];
    enableAdaptiveDisplayLayout = true;
    enableAudioOutputCycle = true;
    autoMirrorExternalOutputs = false;
    enableMirrorToggle = true;
    forceSoftwareMirror = true;
    autoMirrorWorkspace = 10;
    preferHdmiAudio = false;
    relaunchOnExit = false;
    streamHost = "SteamHeadless";
    streamApplication = "Steam Big Picture";
    streamHostStartCommand = steamHeadlessStartCommand;
    streamReadinessHost = "xyz";
    streamArguments = [
      "--1440"
      "--fps"
      "60"
      "--bitrate"
      "40000"
      "--display-mode"
      "fullscreen"
      "--audio-config"
      "stereo"
      "--video-codec"
      "HEVC"
      "--video-decoder"
      "hardware"
      "--no-hdr"
      "--frame-pacing"
      "--swap-gamepad-buttons"
    ];
  };

  # Intel exposes three display pipelines. The firmware initially assigns one
  # to the built-in panel even when Hyprland disables it. Before the graphical
  # session starts, reserve that pipeline for external displays only when all
  # three are physically connected; otherwise leave the panel detectable.
  systemd.services.xps-display-pipeline-setup = {
    description = "Allocate XPS display pipelines for couch outputs";
    before = ["greetd.service"];
    wantedBy = ["multi-user.target"];
    path = [pkgs.coreutils];
    serviceConfig.Type = "oneshot";
    script = ''
      # The initrd normally settles this before Plymouth starts. Retain the
      # userspace pass as a fallback for a dock that appears unusually late.
      early_external_count="$(cat /run/xps-display-pipeline-external-count 2>/dev/null || printf 0)"
      if [ "$early_external_count" -lt 3 ]; then
        ${displayPipelineSetupScript}
      fi
    '';
  };

  systemd.services.greetd.serviceConfig = {
    Type = "idle";
    StandardInput = "tty";
    StandardOutput = "tty";
    StandardError = "journal";
    TTYReset = true;
    TTYVHangup = true;
    TTYVTDisallocate = true;
  };

  # DMS owns idle handling for this user. Prevent the package-provided
  # hypridle unit from failing under UWSM when it has no standalone config.
  systemd.user.services.hypridle = {
    overrideStrategy = "asDropin";
    unitConfig.ConditionPathExists = "/run/xps-enable-hypridle";
  };

  # DMS exits with SIGTERM's conventional 143 status when its graphical
  # session is stopped; treat that normal lifecycle as successful.
  systemd.user.services.dms = {
    overrideStrategy = "asDropin";
    path = [inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default];
    serviceConfig.SuccessExitStatus = 143;
  };

  # UWSM owns graphical-session.target. Start desktop-only companions from the
  # target so they do not interfere with the fixed-output couch session.
  systemd.user.services.xps-desktop-session-setup = {
    description = "Start XPS desktop session companions";
    partOf = ["graphical-session.target"];
    after = ["graphical-session.target"];
    wantedBy = ["graphical-session.target"];
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.coreutils
      pkgs.systemd
    ];
    script = ''
      if [ "$(tr -d '[:space:]' < /var/lib/moonlight-client/session-mode 2>/dev/null || true)" = desktop ]; then
        systemctl --user start dms.service hypr-laptop-display-autoswitch.service
      fi
    '';
  };

  services.xserver.enable = true;
  programs.niri.enable = true;
  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true;
  };

  services.gnome.sushi.enable = true;
  services.udisks2.enable = true;
  services.gvfs.enable = true;
  services.hardware.bolt.enable = true;
  security.polkit = {
    enable = true;
    # DMS provides the graphical Polkit agent in the merged couch session.
    # Install pkexec's privileged wrapper so administrative launchers can use
    # that modal instead of falling back to a terminal-bound sudo prompt.
    enablePkexecWrapper = true;
  };
  # A live NixOS switch can restart polkit after DMS has registered its agent.
  # Refresh the already-running couch shell so the next graphical request is
  # not left waiting on a stale agent registration. Failure is expected before
  # the user's graphical session exists during boot.
  systemd.services.polkit.serviceConfig.ExecStartPost = lib.mkAfter [
    "-+${pkgs.systemd}/bin/systemctl --user --machine=${username}@.host try-restart couch-merged-dms.service"
  ];
  programs.dconf.enable = true;

  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [xdg-desktop-portal-gtk];
    config.common.default = ["gtk"];
    config.hyprland.default = [
      "hyprland"
      "gtk"
    ];
    xdgOpenUsePortal = true;
  };

  services.power-profiles-daemon.enable = true;
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    IdleAction = "ignore";
  };
  services.printing.enable = true;
  services.flatpak.enable = true;
  services.netbird.managed.enable = true;

  systemd.services.xps-network-route-metrics = {
    description = "Prefer wired routing and keep Wi-Fi as fallback";
    after = ["NetworkManager.service"];
    wants = ["NetworkManager.service"];
    wantedBy = ["multi-user.target"];
    path = [pkgs.networkmanager];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      nmcli -t -f NAME,TYPE connection show | while IFS=: read -r name type; do
        case "$type" in
          802-3-ethernet|ethernet)
            nmcli connection modify "$name" \
              ipv4.route-metric 50 ipv6.route-metric 50 || true
            ;;
          802-11-wireless|wifi)
            nmcli connection modify "$name" \
              ipv4.route-metric 600 ipv6.route-metric 600 || true
            ;;
        esac
      done

      nmcli -t -f DEVICE,TYPE device status | while IFS=: read -r device type; do
        if [ "$type" = "ethernet" ] || [ "$type" = "wifi" ]; then
          nmcli device reapply "$device" || true
        fi
      done
    '';
  };

  networking.hosts = {
    "192.168.1.14" = ["xps"];
    "192.168.1.250" = ["k8s-api.local"];
  };

  nix.settings.max-jobs = 8;

  system.stateVersion = lib.mkForce "25.11";
}
