{
  config,
  lib,
  pkgs,
  ...
}: let
  runtimeRoot = "/run/nixbox-private-browser-worker";
  publicRuntimeRoot = "/run/nixbox-public-browser-worker";
  publicKdeConnectHostPort = 1716;
  # Wolf's fixed ports with host networking: the legacy set, the public
  # browser's and the protected browser's.
  wolfTCPPorts = [
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
  wolfUDPPorts = [
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
    allowedTCPPorts = [publicKdeConnectHostPort] ++ wolfTCPPorts;
    allowedUDPPorts = [publicKdeConnectHostPort] ++ wolfUDPPorts;
  };

  # Most of these ports lie in the kernel's ephemeral range (32768-60999). An
  # outgoing connection that draws one as its source port blocks Wolf's bind
  # for as long as it lives: after a reboot on 2026-11-10, k3s's loopback
  # connection to etcd took 48984, and the protected browser's Wolf failed
  # with "bind: Address already in use" until that connection closed.
  # Reserving the ports keeps them out of the ephemeral pool.
  boot.kernel.sysctl."net.ipv4.ip_local_reserved_ports" =
    lib.concatMapStringsSep "," toString (lib.unique (wolfTCPPorts ++ wolfUDPPorts));
}
