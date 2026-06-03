# nix-config/hosts/nux/configuration.nix
{
  config,
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
    "${configDir}/modules/nixos/services/nfs/default.nix"
    "${configDir}/modules/nixos/services/pihole-native/default.nix"
    "${configDir}/modules/nixos/services/unifi-native/default.nix"
    "${configDir}/modules/nixos/services/forgejo-actions-runner/default.nix"
    "${configDir}/modules/nixos/services/k8s-api-vip/default.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/default.nix"
    "${configDir}/modules/nixos/virtualisation/longhorn-prereqs/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  boot.initrd.systemd.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  alc.distributedBuildClient.enable = true;

  sops.secrets = {
    pihole_secret_key = {
      sopsFile = "${inputs.nix-secrets}/apps/secrets.yaml";
      owner = "pihole";
      group = "pihole";
    };
    flux_age_key = {
      key = "flux_age_key";
    };
    k3s_server_token = {
      sopsFile = "${inputs.nix-secrets}/cluster-bootstrap/secrets.yaml";
      key = "k3s_server_token";
      owner = "root";
      group = "root";
    };
  };

  services.forge-mirror-audit = {
    enable = true;
    schedule = "*-*-* 00/8:00:00"; # every 8 hours
  };

  k3s = {
    enable = true;
    clusterInit = true;
    tokenFile = config.sops.secrets.k3s_server_token.path;
    tlsSans = [
      "k8s-api.local"
      "192.168.1.250"
    ];
  };

  fileSystems."/var/lib/longhorn" = {
    device = "/dev/disk/by-label/nux-longhorn";
    fsType = "ext4";
  };

  systemd.services.k3s = {
    requires = ["var-lib-longhorn.mount"];
    after = ["var-lib-longhorn.mount"];
  };

  services.k8s-api-vip = {
    enable = true;
    interface = "eno1";
    sourceIp = "192.168.1.15";
    peers = [
      "192.168.1.13"
      "192.168.1.16"
    ];
    priority = 110;
  };

  networking.hosts."192.168.1.250" = ["k8s-api.local"];

  services.netbird.managed.enable = true;

  services.forgejo-actions-runner = {
    enable = true;
    name = "nux";
    capacity = 1;
    labels = [
      "forgejo-docker-secondary:docker://node:20-bookworm"
      "nux:docker://node:20-bookworm"
    ];
  };

  services.unbound = {
    enable = true;
    resolveLocalQueries = false;
    settings.server = {
      interface = ["127.0.0.1"];
      port = 5335;
      access-control = ["127.0.0.0/8 allow"];
      do-ip4 = true;
      do-ip6 = false;
      do-udp = true;
      do-tcp = true;
      prefer-ip6 = false;
      edns-buffer-size = 1232;
      harden-glue = true;
      harden-dnssec-stripped = true;
      prefetch = true;
      qname-minimisation = true;
      rrset-roundrobin = true;
    };
  };

  systemd.services.unbound = {
    after = [
      "network-online.target"
      "time-sync.target"
    ];
    wants = [
      "network-online.target"
      "time-sync.target"
    ];
  };

  services.pihole-native = {
    enable = true;
    listenInterface = "eno1";
    hostName = "pihole.nux.local";
    webPort = 8081;
    upstream = "127.0.0.1#5335";
    stateDirectory = "/var/lib/pihole/etc";
    passwordFile = config.sops.secrets.pihole_secret_key.path;
    disableWebPassword = true;
    webAcl = "+10.42.0.0/16,+192.168.1.10,+192.168.1.13,+192.168.1.15,+192.168.1.16";
  };

  services.unifi-native = {
    enable = true;
    role = "active";
    openFirewall = true;
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

  # NFS server — export /mnt/shared for paperless-ingest (and future services)
  services.nfs.managed = {
    enable = true;
    allowedClients = [
      "192.168.1.10" # xyz
      "192.168.1.24" # mac
    ];
    shares = [
      {path = "/mnt/shared";}
    ];
  };

  # Ensure /mnt/shared/paperless-ingest exists
  systemd.tmpfiles.rules = [
    "d /mnt/shared 0755 root root -"
    "d /mnt/shared/paperless-ingest 0777 root root -"
    # k3s Traefik manifest
    "d /var/lib/rancher/k3s/server/manifests 0755 root root -"
    "L+ /var/lib/rancher/k3s/server/manifests/traefik-config.yaml - - - - ${traefikConfig}"
  ];

  nix.settings.max-jobs = 1; # prefer xyz for builds, but allow local fallback

  networking.hosts."127.0.0.1" = ["git.local"];
  networking.firewall.allowedTCPPorts = [53];
  networking.firewall.allowedUDPPorts = [53];
}
