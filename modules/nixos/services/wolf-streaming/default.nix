{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.wolf-streaming;
  nvidiaPackage = config.hardware.nvidia.package;
  browserCfg = cfg.browserImages;
  browserBaseImage = "ghcr.io/games-on-whales/base-app@sha256:1d7b61da242e767bc5c80c5fe897392b6a9e6854345d3dea6d2f799e7ea98a14";
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
      cp ${deb} "$out/browser.deb"
    '';
  browserImages = lib.filter (image: image.enable) [
    {
      enable = browserCfg.helium.enable;
      name = "helium";
      image = browserCfg.helium.image;
      version = heliumVersion;
      executable = "/usr/bin/helium";
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
      source = "https://github.com/brave/brave-browser";
      context = mkBrowserContext {
        name = "brave";
        deb = pkgs.brave.src;
      };
    }
  ];
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
        "NIXBOX_BROWSER_SCALE=1.5"
      ];
      devices = [];
      ports = [];
      base_create_json = browserHostConfig;
    };
  };
  managedMoonlightApps =
    lib.optional browserCfg.helium.publish (mkMoonlightBrowserApp {
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
  managedMoonlightAppsFile = pkgs.writeText "wolf-managed-moonlight-apps.json" (builtins.toJSON {
    managedTitles = [
      "Helium"
      "Brave"
    ];
    apps = managedMoonlightApps;
  });
  reconcileWolfApps = pkgs.writeShellApplication {
    name = "reconcile-wolf-apps";
    runtimeInputs = [
      (pkgs.python3.withPackages (pythonPackages: [pythonPackages.tomlkit]))
    ];
    text = ''
      exec python3 ${./reconcile-apps.py} "$@"
    '';
  };
  buildBrowserImages = pkgs.writeShellApplication {
    name = "build-wolf-browser-images";
    runtimeInputs = [pkgs.docker];
    text = ''
      set -euo pipefail

      docker image inspect ${lib.escapeShellArg browserBaseImage} >/dev/null 2>&1 \
        || docker pull ${lib.escapeShellArg browserBaseImage}

      ${lib.concatMapStringsSep "\n" (image: ''
          docker build \
            --pull=false \
            --build-arg BASE_APP_IMAGE=${lib.escapeShellArg browserBaseImage} \
            --build-arg BROWSER_EXECUTABLE=${lib.escapeShellArg image.executable} \
            --build-arg IMAGE_SOURCE=${lib.escapeShellArg image.source} \
            --build-arg IMAGE_VERSION=${lib.escapeShellArg image.version} \
            --tag ${lib.escapeShellArg image.image} \
            ${lib.escapeShellArg image.context}
        '')
        browserImages}
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

    browserImages = {
      enable = lib.mkEnableOption "locally built Wolf browser application images";

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
          WOLF_STOP_CONTAINER_ON_EXIT = "TRUE";
        };
        volumes = [
          "${cfg.stateDirectory}:/etc/wolf:rw"
          "${nvrtcRuntime}:/opt/wolf-nvrtc:ro"
          "/run/wolf-streaming/libnvidia-allocator.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.1:ro"
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

    systemd.services.docker-wolf = {
      after = [
        "docker.service"
        "nvidia-container-toolkit-cdi-generator.service"
      ];
      requires = ["docker.service"];
      preStart = lib.mkIf browserCfg.enable ''
        ${lib.getExe reconcileWolfApps} \
          ${lib.escapeShellArg "${cfg.stateDirectory}/cfg/config.toml"} \
          ${lib.escapeShellArg managedMoonlightAppsFile}
      '';
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
