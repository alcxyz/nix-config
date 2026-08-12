{
  config,
  lib,
  pkgs,
  ...
}: let
  nvidiaContainerRuntime = lib.getExe' (
    lib.getOutput "tools" config.hardware.nvidia-container-toolkit.package
  ) "nvidia-container-runtime";
  nvidiaContainerRuntimeHook = lib.getExe' (
    lib.getOutput "tools" config.hardware.nvidia-container-toolkit.package
  ) "nvidia-container-runtime-hook";
  nvidiaCtk = lib.getExe' config.hardware.nvidia-container-toolkit.package "nvidia-ctk";
in {
  assertions = [
    {
      assertion = config.services.k3s.enable;
      message = "The k3s NVIDIA runtime module requires services.k3s.enable";
    }
  ];

  hardware.nvidia-container-toolkit = {
    enable = true;
    # Kubernetes allocates devices by UUID. Keep the aggregate `all` entry for
    # host-native Wolf containers while matching device-plugin allocations.
    device-name-strategy = "uuid";
  };

  # K3s cannot discover Nix store executables through conventional runtime
  # search paths. Register the runtime and every helper explicitly.
  environment.etc."nvidia-container-runtime/config.toml".text = ''
    disable-require = true
    supported-driver-capabilities = "compat32,compute,display,graphics,ngx,utility,video"

    [nvidia-container-cli]
    environment = []
    ldconfig = "@${lib.getExe' pkgs.glibc "ldconfig"}"
    load-kmods = true
    no-cgroups = false
    path = "${lib.getExe' pkgs.libnvidia-container "nvidia-container-cli"}"

    [nvidia-container-runtime]
    mode = "cdi"
    runtimes = ["docker-runc", "runc", "crun"]

    [nvidia-container-runtime-hook]
    path = "${nvidiaContainerRuntimeHook}"
    skip-mode-detection = false

    [nvidia-ctk]
    path = "${nvidiaCtk}"
  '';

  services.k3s.containerdConfigTemplate = ''
    {{ template "base" . }}

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'nvidia']
      runtime_type = "io.containerd.runc.v2"
      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'nvidia'.options]
        BinaryName = "${nvidiaContainerRuntime}"
  '';

  systemd.services.k3s = {
    after = ["nvidia-container-toolkit-cdi-generator.service"];
    requires = ["nvidia-container-toolkit-cdi-generator.service"];
  };
}
