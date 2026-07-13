{
  roles = {
    workstation = {
      homePackageSet = "workstation";
      systemPackageSet = "workstation";
      workspaceProfiles = ["base" "infra-admin" "platform" "apps" "tools" "personal" "sites" "orgs" "forks" "clones"];
    };

    nuc = {
      homePackageSet = "nuc";
      systemPackageSet = "server";
      workspaceProfiles = ["base" "infra-admin"];
    };

    k8s-worker = {
      homePackageSet = "server";
      systemPackageSet = "server";
      workspaceProfiles = ["base" "infra-admin"];
    };

    laptop-workstation = {
      homePackageSet = "workstation";
      systemPackageSet = "workstation";
      workspaceProfiles = ["base" "infra-admin" "platform" "apps" "tools" "personal" "sites" "orgs" "forks" "clones"];
    };

    family-gaming = {
      homePackageSet = "family-gaming";
      systemPackageSet = "workstation";
      workspaceProfiles = [];
    };

    embedded = {
      homePackageSet = "embedded";
      systemPackageSet = "embedded";
      workspaceProfiles = [];
    };

    mac = {
      homePackageSet = "mac";
      systemPackageSet = "mac";
      workspaceProfiles = ["base" "infra-admin" "platform" "apps" "tools" "personal" "sites" "orgs" "forks" "clones"];
    };
  };

  k8sRoles = {
    agent = {
      role = "agent";
      schedulable = true;
      extraFlags = [
        "--node-label=workload-class=ephemeral"
      ];
    };

    stable-agent = {
      role = "agent";
      schedulable = true;
      extraFlags = [
        "--node-label=workload-class=stable"
      ];
    };

    server-worker = {
      role = "server";
      schedulable = true;
      maxPods = 200;
      extraFlags = [
        "--disable=coredns"
        "--node-label=workload-class=stable"
      ];
    };

    server-control-plane = {
      role = "server";
      schedulable = false;
      extraFlags = [
        "--node-taint=node-role.kubernetes.io/control-plane=true:NoSchedule"
      ];
    };
  };

  hosts = {
    xyz = {
      system = "x86_64-linux";
      platform = "nixos";
      role = "workstation";
      k8sRole = "agent";
      configuration = ./hosts/xyz/configuration.nix;
      osIcon = "";
    };

    nux = {
      system = "x86_64-linux";
      platform = "nixos";
      role = "nuc";
      k8sRole = "server-worker";
      sshHostname = "192.168.1.15";
      configuration = ./hosts/nux/configuration.nix;
      osIcon = "";
    };

    nex = {
      system = "x86_64-linux";
      platform = "nixos";
      role = "nuc";
      k8sRole = "server-worker";
      sshHostname = "192.168.1.16";
      configuration = ./hosts/nex/configuration.nix;
      osIcon = "";
    };

    xev = {
      system = "x86_64-linux";
      platform = "nixos";
      role = "k8s-worker";
      k8sRole = "server-worker";
      sshHostname = "192.168.1.13";
      configuration = ./hosts/xev/configuration.nix;
      osIcon = "";
    };

    xps = {
      system = "x86_64-linux";
      platform = "nixos";
      role = "laptop-workstation";
      k8sRole = null;
      sshHostname = "192.168.1.14";
      systemSshUser = "alc";
      systemUseRemoteSudo = true;
      configuration = ./hosts/xps/configuration.nix;
      osIcon = "";
    };

    madsil = {
      system = "x86_64-linux";
      platform = "nixos";
      role = "family-gaming";
      k8sRole = null;
      sshHostname = "100.82.58.0";
      systemSshUser = "alc";
      systemUseRemoteSudo = true;
      forwardAgent = true;
      deployAll = false;
      skipManagedUserSshSecrets = true;
      configuration = ./hosts/madsil/configuration.nix;
      osIcon = "";
    };

    rpi0 = {
      system = "aarch64-linux";
      platform = "nixos";
      role = "embedded";
      k8sRole = null;
      sshHostname = "192.168.1.3";
      configuration = ./hosts/rpi0/configuration.nix;
      osIcon = "";
    };

    mac = {
      system = "aarch64-darwin";
      platform = "darwin";
      role = "mac";
      k8sRole = null;
      aliases = ["AM-VYH2F56CR6"];
      darwinNetworkName = "AM-VYH2F56CR6";
      configuration = ./hosts/mac/configuration.nix;
      osIcon = "";
    };
  };
}
