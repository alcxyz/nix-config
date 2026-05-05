{
  roles = {
    workstation = {
      homePackageSet = "workstation";
      systemPackageSet = "workstation";
      workspaceProfiles = ["base" "infra-admin" "apps" "forks" "clones"];
    };

    nuc = {
      homePackageSet = "nuc";
      systemPackageSet = "server";
      workspaceProfiles = ["base" "infra-admin"];
    };

    embedded = {
      homePackageSet = "embedded";
      systemPackageSet = "server";
      workspaceProfiles = [];
    };

    mac = {
      homePackageSet = "mac";
      systemPackageSet = "mac";
      workspaceProfiles = ["base" "infra-admin" "apps"];
    };
  };

  k8sRoles = {
    agent = {
      role = "agent";
      schedulable = true;
    };

    server-worker = {
      role = "server";
      schedulable = true;
    };

    server-control-plane = {
      role = "server";
      schedulable = false;
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
      configuration = ./hosts/nux/configuration.nix;
      osIcon = "";
    };

    nex = {
      system = "x86_64-linux";
      platform = "nixos";
      role = "nuc";
      k8sRole = "server-worker";
      configuration = ./hosts/nex/configuration.nix;
      osIcon = "";
    };

    rpi0 = {
      system = "aarch64-linux";
      platform = "nixos";
      role = "embedded";
      k8sRole = "server-control-plane";
      configuration = ./hosts/rpi0/configuration.nix;
      osIcon = "";
    };

    mac = {
      system = "aarch64-darwin";
      platform = "darwin";
      role = "mac";
      k8sRole = null;
      configuration = ./hosts/mac/configuration.nix;
      osIcon = "";
    };
  };
}
