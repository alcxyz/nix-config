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
    text =
      lib.replaceStrings
      ["@runtimeRoot@"]
      [runtimeRoot]
      (builtins.readFile ./worker-stream-layout.sh.in);
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
