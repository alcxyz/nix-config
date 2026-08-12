{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.bluetooth-audio-receiver;

  pairingWindow = pkgs.writeShellApplication {
    name = "bluetooth-audio-pairing-window";
    runtimeInputs = [
      pkgs.bluez
      pkgs.coreutils
      pkgs.gnused
    ];
    text = ''
      controller="$(${pkgs.bluez}/bin/bluetoothctl list \
        | ${pkgs.gnused}/bin/sed -n 's/^Controller \([^ ]*\).* \[default\]$/\1/p' \
        | ${pkgs.coreutils}/bin/head -n 1)"

      if [[ -z "$controller" ]]; then
        echo "No default Bluetooth controller is available" >&2
        exit 1
      fi

      close_window() {
        printf 'select %s\ndiscoverable off\npairable off\nquit\n' "$controller" \
          | ${pkgs.bluez}/bin/bluetoothctl >/dev/null
      }
      trap close_window EXIT INT TERM

      printf 'select %s\npairable on\ndiscoverable on\nquit\n' "$controller" \
        | ${pkgs.bluez}/bin/bluetoothctl >/dev/null
      echo "Bluetooth pairing is available as ${lib.escapeShellArg cfg.adapterName} for ${toString cfg.pairingWindowSeconds} seconds"
      ${pkgs.coreutils}/bin/sleep ${toString cfg.pairingWindowSeconds}
    '';
  };
in {
  options.services.bluetooth-audio-receiver = {
    enable = lib.mkEnableOption "a boot-persistent Bluetooth audio receiver";

    user = lib.mkOption {
      type = lib.types.str;
      description = "User whose lingering PipeWire session owns the Bluetooth audio endpoints.";
    };

    adapterName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Name advertised by the local Bluetooth adapter.";
    };

    enableTransmitRole = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Also allow this host to send audio to Bluetooth speakers or headphones.";
    };

    outputSinkName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alsa_output.platform-sound.stereo-fallback";
      description = ''
        PipeWire sink node that always receives incoming Bluetooth audio. When
        unset, WirePlumber routes it to the current default audio sink.
      '';
    };

    pairingWindowSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 180;
      description = "Duration of an explicitly requested Bluetooth discovery and pairing window.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "services.bluetooth-audio-receiver.user must name a declared NixOS user";
      }
    ];

    users.users.${cfg.user} = {
      linger = true;
      extraGroups = ["audio"];
    };

    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          Name = cfg.adapterName;
          Class = "0x240414";
          ControllerMode = "dual";
        };
        Policy.AutoEnable = true;
      };
    };

    security.rtkit.enable = true;

    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
      wireplumber = {
        enable = true;
        extraConfig."51-headless-bluetooth-receiver" = {
          "monitor.bluez.properties" = {
            # Keep A2DP endpoints alive even before an interactive graphical
            # session exists. The owning user manager starts at boot via linger.
            "with-logind" = false;
            "bluez5.roles" = ["a2dp_sink"] ++ lib.optional cfg.enableTransmitRole "a2dp_source";
          };
          "monitor.bluez.rules" = lib.optional (cfg.outputSinkName != null) {
            matches = [{"node.name" = "~bluez_input[.].*";}];
            actions."update-props" = {
              # A received A2DP stream is a playback stream. Give it an
              # explicit target so changing the desktop/media default cannot
              # move Bluetooth-speaker audio to HDMI.
              "target.object" = cfg.outputSinkName;
              "node.dont-fallback" = true;
            };
          };
        };
      };
    };

    # Keep a non-interactive BlueZ agent alive independently of SSH sessions.
    # Discovery and pairing remain opt-in through the bounded user service below.
    systemd.services.bluetooth-audio-pairing-agent = {
      description = "Bluetooth audio receiver pairing agent";
      wantedBy = ["bluetooth.target"];
      after = ["bluetooth.service"];
      requires = ["bluetooth.service"];
      serviceConfig = {
        ExecStart = "${pkgs.bluez-tools}/bin/bt-agent --capability=NoInputNoOutput";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    systemd.user.services.bluetooth-audio-pairing-window = {
      description = "Temporarily advertise the Bluetooth audio receiver";
      after = ["default.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pairingWindow}/bin/bluetooth-audio-pairing-window";
      };
    };

    environment.systemPackages = [
      pkgs.bluez
      pairingWindow
    ];
  };
}
