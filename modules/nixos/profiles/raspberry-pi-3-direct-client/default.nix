{
  config,
  inputs,
  lib,
  pkgs,
  username,
  ...
}: let
  # These appliances receive closures from the x86_64 builders (xyz or xev).
  # Cross-compile their vendor kernel there instead of running an AArch64
  # compiler through binfmt emulation.
  crossPkgs = import inputs.nixpkgs {
    localSystem = "x86_64-linux";
    crossSystem = "aarch64-linux";
  };
  rpiKernel = crossPkgs.callPackage "${inputs.nixos-hardware}/raspberry-pi/common/kernel.nix" {
    rpiVersion = 3;
  };
  # The generic NixOS image uses a 30 MiB firmware partition. The complete
  # Raspberry Pi firmware package contains DTBs and overlays for every board
  # generation and cannot be updated atomically in that space. Keep only the
  # standard GPU firmware and DTBs needed by these Pi 3B+ appliances.
  rpi3Firmware = crossPkgs.runCommand "raspberry-pi-3-minimal-firmware" {} ''
    firmwareRoot="$out/share/raspberrypi/boot"
    mkdir -p "$firmwareRoot/overlays"
    cp \
      ${pkgs.raspberrypifw}/share/raspberrypi/boot/bootcode.bin \
      ${pkgs.raspberrypifw}/share/raspberrypi/boot/start.elf \
      ${pkgs.raspberrypifw}/share/raspberrypi/boot/fixup.dat \
      ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-3-b.dtb \
      ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-3-b-plus.dtb \
      "$firmwareRoot/"
    cp \
      ${pkgs.raspberrypifw}/share/raspberrypi/boot/overlays/vc4-kms-v3d.dtbo \
      "$firmwareRoot/overlays/"
  '';
  mkSteamCommand = name: action:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [pkgs.openssh];
      text = ''
        exec ssh \
          -T \
          -i /etc/ssh/ssh_host_ed25519_key \
          -o IdentitiesOnly=yes \
          -o BatchMode=yes \
          -o ConnectTimeout=5 \
          root@xyz \
          ${lib.escapeShellArg action}
      '';
    };
  steamStart = mkSteamCommand "steam-start" "start";
  steamStop = mkSteamCommand "steam-stop" "stop";
  # Keep the old name available while callers migrate to steam-start.
  steamWake = mkSteamCommand "steam-wake" "wake";
in {
  imports = [
    "${inputs.nixos-hardware}/raspberry-pi/common/default.nix"
    inputs.nix-secrets.nixosModules.nixboxClientPrivate
    ../nixbox-direct-client/default.nix
  ];

  # This is the upstream nixos-hardware Pi 3 profile expressed without its
  # package overlay; flake/pkgs.nix owns overlays for the read-only package set.
  boot.kernelPackages = lib.mkDefault (pkgs.linuxPackagesFor rpiKernel);

  hardware.firmware = [
    (pkgs.callPackage "${inputs.nixos-hardware}/raspberry-pi/common/raspberry-pi-wireless-firmware.nix" {})
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

  hardware.raspberry-pi.firmware = {
    enable = true;
    package = rpi3Firmware;
    uboot.enable = true;
  };

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible = {
    enable = true;
    configurationLimit = 2;
  };
  boot.kernelParams = [
    "cma=256M"
    "kfence.sample_interval=0"
    "video=HDMI-A-1:1920x1080@60e"
  ];

  # These appliances receive complete closures built on xyz or xev. Fail
  # closed instead of falling back to slow, thermally constrained local builds.
  nix.settings = {
    max-jobs = 0;
    require-sigs = false;
  };

  fonts.packages = lib.mkForce [];
  programs.nix-ld.enable = lib.mkForce false;
  programs.nix-ld.libraries = lib.mkForce [];
  services.pcscd.enable = lib.mkForce false;
  virtualisation.containers.enable = lib.mkForce false;
  virtualisation.docker.enable = lib.mkForce false;

  environment.variables = {
    EDITOR = lib.mkForce "nano";
    VISUAL = lib.mkForce "nano";
    H264_DECODER_HINT = "h264_v4l2m2m";
    MOONLIGHT_DRM_USE_QT_MASTER_FD = "1";
  };

  environment.systemPackages = [
    steamStart
    steamStop
    steamWake
  ];

  services.nixbox-direct-client = {
    enable = true;
    user = username;
    package = pkgs.moonlight-rpi3;
    enableKdeConnect = false;
  };

  # The appliance user may authenticate with this machine's SSH host identity
  # only to start or stop SteamHeadless on xyz. The corresponding key is bound
  # to a forced dispatcher and cannot open a shell.
  security.sudo.extraRules = [
    {
      users = [username];
      commands = [
        {
          command = "${steamStart}/bin/steam-start";
          options = ["NOPASSWD"];
        }
        {
          command = "${steamStop}/bin/steam-stop";
          options = ["NOPASSWD"];
        }
        {
          command = "${steamWake}/bin/steam-wake";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  services.moonlight-client = {
    directDrmFixedOutput = {
      device = "/dev/dri/card0";
      connector = "HDMI-A-1";
      mode = "1920x1080@60";
    };
    directDrmAudioOutputByConnector."HDMI-A-1" = "alsa_output.platform-3f902000.hdmi.hdmi-stereo";
    directDrmExtraEnvironment = ["MOONLIGHT_VIDEO_STATS_LOG_INTERVAL_MS=5000"];
    directDrmLogToJournal = true;
    audioOutputStartupVolumePercent = 80;

    streamHost = "SteamHeadless";
    streamApplication = "Steam Big Picture";
    streamHostStartCommand = ''
      /run/wrappers/bin/sudo -- ${steamStart}/bin/steam-start
    '';
    streamReadinessHost = "xyz";

    browserStreamHost = "Wolf";
    browserStreamApplication = "Helium (Pi 3)";
    browserStreamSelectorHost = "Wolf User";
    browserStreamSelectorPort = 48989;
    browserStreamSelectorApplication = "Wolf UI";
    browserStreamSelectorProfileDirectory = "/home/${username}/.local/share/moonlight-client/private";
    # Stream coordinators are managed centrally. These appliances do not carry
    # an outgoing operator SSH identity merely to invoke the rpi0 layout hook.
    browserStreamLayoutCommand = lib.mkForce "";
    browserAbsoluteMouseSensitivity = 2.0;
    browserAbsoluteMousePollIntervalMs = 1;
    browserShowLocalCursor = false;

    streamArguments = [
      "--1080"
      "--fps"
      (toString config.services.nixbox-direct-client.streamFps)
      "--bitrate"
      "20000"
      "--display-mode"
      "windowed"
      "--audio-config"
      "stereo"
      "--video-codec"
      "H.264"
      "--video-decoder"
      "hardware"
      "--no-hdr"
      "--frame-pacing"
      "--swap-gamepad-buttons"
      "--mute-on-focus-loss"
      "--no-background-gamepad"
    ];

    browserStreamArguments = [
      "--absolute-mouse"
      "--capture-system-keys"
      "never"
      "--performance-overlay"
    ];
  };

  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=100M
  '';

  zramSwap.enable = true;
}
