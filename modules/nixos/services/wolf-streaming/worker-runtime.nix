{
  config,
  lib,
  pkgs,
  ...
}: let
  runtimeRoot = "/run/nixbox-private-browser-worker";
  nvidiaPackage = config.hardware.nvidia.package;
  nvrtcRuntime = pkgs.callPackage ./nvrtc-runtime.nix {};
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
    "L+ ${runtimeRoot}/libnvidia-allocator.so.1 - - - - ${nvidiaPackage}/lib/libnvidia-allocator.so.1"
    "L+ ${runtimeRoot}/nvrtc - - - - ${nvrtcRuntime}"
    "L+ ${runtimeRoot}/10_nvidia.json - - - - ${nvidiaPackage}/share/glvnd/egl_vendor.d/10_nvidia.json"
  ];
}
