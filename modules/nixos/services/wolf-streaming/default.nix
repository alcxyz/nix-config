{
  config,
  lib,
  ...
}: let
  cfg = config.services.wolf-streaming;
in {
  options.services.wolf-streaming = {
    enable = lib.mkEnableOption "Wolf Moonlight application streaming";

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/games-on-whales/wolf@sha256:8515dd1a88fa6c4a39a814c7c2f7eee4106d5b60c8140be6d0ef689324a079a2";
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
    ];

    virtualisation.oci-containers = {
      backend = "docker";
      containers.wolf = {
        image = cfg.image;
        autoStart = true;
        environment = {
          HOST_APPS_STATE_FOLDER = cfg.stateDirectory;
          NVIDIA_DRIVER_CAPABILITIES = "all";
          NVIDIA_VISIBLE_DEVICES = "all";
          WOLF_DEFAULT_RUN_GID = toString cfg.defaultRunGid;
          WOLF_DEFAULT_RUN_UID = toString cfg.defaultRunUid;
          WOLF_LOG_LEVEL = "INFO";
          WOLF_RENDER_NODE = cfg.renderNode;
          WOLF_STOP_CONTAINER_ON_EXIT = "TRUE";
        };
        volumes = [
          "${cfg.stateDirectory}:/etc/wolf:rw"
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

    systemd.services.docker-wolf = {
      after = [
        "docker.service"
        "nvidia-container-toolkit-cdi-generator.service"
      ];
      requires = ["docker.service"];
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
