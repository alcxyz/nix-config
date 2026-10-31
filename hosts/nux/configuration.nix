# nix-config/hosts/nux/configuration.nix
{
  pkgs,
  inputs,
  username,
  hostName,
  configDir,
  lib,
  ...
}: let
  # k3s Traefik on standard ports (Docker Traefik decommissioned)
  traefikConfig = pkgs.writeText "traefik-config.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChartConfig
    metadata:
      name: traefik
      namespace: kube-system
    spec:
      valuesContent: |
        deployment:
          replicas: 2
        podDisruptionBudget:
          enabled: true
          minAvailable: 1
        ports:
          web:
            exposedPort: 80
            forwardedHeaders:
              trustedIPs:
                - 10.42.0.0/16
          websecure:
            exposedPort: 443
            forwardedHeaders:
              trustedIPs:
                - 10.42.0.0/16
        service:
          spec:
            externalTrafficPolicy: Local
        ingressRoute:
          dashboard:
            enabled: false
        api:
          dashboard: true
          insecure: false
  '';
in {
  imports = [
    ./hardware-configuration.nix
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/server.nix"
    "${configDir}/modules/nixos/services/forge-mirror-audit/default.nix"
    "${configDir}/modules/nixos/services/forgejo-actions-runner/default.nix"
    "${configDir}/modules/nixos/services/k8s-api-vip/default.nix"
    inputs.nix-secrets.nixosModules.k8sApiVipPolicy
    inputs.nix-secrets.nixosModules.k3sClusterSecrets
    inputs.nix-secrets.nixosModules.openbaoClusterPolicy
    "${configDir}/modules/nixos/services/rustfs-native/default.nix"
    inputs.nix-secrets.nixosModules.rustfsApplicationPolicy
    "${configDir}/modules/nixos/virtualisation/k3s/default.nix"
    "${configDir}/modules/nixos/virtualisation/longhorn-prereqs/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  alc.private.openbaoClusterPolicy.enable = true;
  alc.private.rustfsApplication.enable = true;
  alc.private.rustfsApplication.vipEnable = true;

  boot.kernelPackages = pkgs.linuxPackages_latest;

  alc.distributedBuildClient.enable = true;

  services.forge-mirror-audit = {
    enable = true;
    schedule = "*-*-* 00/8:00:00"; # every 8 hours
  };

  k3s = {
    enable = true;
    nodeIp = "192.168.1.15";
    nodeInterface = "eno1";
    # nex is the retained authoritative member during nux root replacement.
    # A clean nux must join it, never initialize an independent etcd cluster.
    serverAddr = "https://192.168.1.16:6443";
    tlsSans = [
      "k8s-api.local"
      "192.168.1.250"
    ];
  };

  # The target 1 TB NVMe deliberately shares its root filesystem with
  # Longhorn. The bind mount distinguishes intentional root-backed storage
  # from an accidental ordinary directory at /var/lib/longhorn and lets the
  # fail-closed storage guard remain authoritative.
  system.activationScripts.longhornDataDirectory.text = ''
    install -d -m 0755 /var/lib/longhorn-data
  '';

  fileSystems."/var/lib/longhorn" = {
    device = "/var/lib/longhorn-data";
    fsType = "none";
    options = [
      "bind"
      "nofail"
    ];
  };

  alc.longhornPrereqs.storageMountUnit = "var-lib-longhorn.mount";

  networking.hosts."192.168.1.250" = ["k8s-api.local"];

  services.netbird.managed.enable = true;

  services.forgejo-actions-runner = {
    enable = true;
    # Alert when CI admission stays held beyond its bound (ADR-0072, #894).
    holdMonitor.enable = true;
    package = pkgs.callPackage "${inputs.nix-packages}/pkgs/forgejo-runner-cancellation" {};
    ioPressureGuard.enable = true;
    ioPressureGuard.admissionControl.enable = true;
    ioPressureGuard.diskSpace.enable = true;
    idlePodmanCleanup.enable = true;
    idlePodmanCleanup.pressureOnly = false;
    # Pool jobs substitute upstream paths through a local read-only proxy
    # (ADR-0103).
    nixCacheProxy.enable = true;
    # Engines pull docker.io images through the LAN cache, falling back to
    # docker.io when it is down (#917).
    registryMirror = "registry-cache.alc.xyz";
    registryMirrorCaFile = ../../modules/nixos/services/forgejo-actions-runner/registry-cache-ca.crt;
    isolatedDocker.enable = true;
    isolatedDocker.retention.enable = true;
    podmanCanary = {
      enable = true;
      package = pkgs.callPackage "${inputs.nix-packages}/pkgs/forgejo-runner-cancellation" {};
      # Preserve the manual canary workflow while jobs adopt the shared label.
      labels = [
        "forgejo-podman:docker://docker.io/library/docker:27-cli"
        "forgejo-podman-canary:docker://docker.io/library/docker:27-cli"
      ];
      # nux resolves through NetBird DNS, whose oversized UDP answers
      # aardvark-dns cannot decode; jobs use the LAN resolvers instead.
      dnsServers = ["192.168.1.3" "192.168.1.4"];
    };
    resourcePolicy.enable = true;
    name = "nux";
    # 8 threads shared with k3s and storage: one job per runner (ADR-0041).
    capacity = 1;
    labels = [
      "forgejo-docker-primary:docker://node:20-bookworm"
      "forgejo-docker-secondary:docker://node:20-bookworm"
      "ubuntu-latest:docker://node:20-bookworm"
      "docker:docker://node:20-bookworm"
      "nux:docker://node:20-bookworm"
    ];
  };

  # NFS mount from xyz — shared state for gitops tools (tokens, cross-host config)
  fileSystems."/mnt/gitops-state" = {
    device = "192.168.1.10:/home/alc/.local/share/gitops-state";
    fsType = "nfs";
    options = [
      "nfsvers=4"
      "soft"
      "timeo=15"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
    ];
  };

  systemd.tmpfiles.rules = [
    # k3s Traefik manifest
    "d /var/lib/rancher/k3s/server/manifests 0755 root root -"
    "L+ /var/lib/rancher/k3s/server/manifests/traefik-config.yaml - - - - ${traefikConfig}"
  ];

  nix.settings.max-jobs = 1; # prefer xyz for builds, but allow local fallback

  networking.hosts."127.0.0.1" = ["git.local"];
}
