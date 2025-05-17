{ config, lib, pkgs, ... }:
with lib;
with lib.custom;
let
  cfg = config.virtualisation.kvm-system;
  inherit (config) user;
in
{
  options.virtualisation.kvm-system = with types; {
    enable = mkBoolOpt false "Whether or not to enable KVM virtualisation.";
    vfioIds =
      mkOpt (listOf str) [ "10de:1b80" "10de:10f0" ] # Secondary 16x
        "The hardware IDs to pass through to a virtual machine.";
    platform =
      mkOpt (enum [ "amd" "intel" ]) "amd"
        "Which CPU platform the machine is using.";
  };

  config = mkIf cfg.enable {
    boot = {
      kernelModules = [
        "kvm-${cfg.platform}"
        "vfio_virqfd"
        "vfio_pci"
        "vfio_iommu_type1"
        "vfio"
      ];
      kernelParams = [
        "${cfg.platform}_iommu=on"
        "${cfg.platform}_iommu=pt"
        "kvm.ignore_msrs=1"
      ];
      extraModprobeConfig = ''
        options kvm_${cfg.platform} nested=1
        options kvm ignore_msrs=1
        ${optionalString (length cfg.vfioIds > 0) "options vfio-pci ids=${concatStringsSep "," cfg.vfioIds}"}
      '';
    };

    systemd.tmpfiles.rules = [
      "f /dev/shm/looking-glass 0660 root qemu-libvirtd -"
      "f /dev/shm/scream 0660 root qemu-libvirtd -"
    ];

    environment.systemPackages = with pkgs; [ guestfs-tools virt-manager swtpm libtpms OVMF looking-glass-client swtpm ];

    virtualisation.libvirtd = {
      enable = true;
      onBoot = "ignore";
      onShutdown = "shutdown";
      qemu = {
        package = pkgs.qemu_kvm;
        swtpm.enable = true;
        ovmf = {
          enable = true;
          packages = [
            (pkgs.OVMF.override {
              secureBoot = true;
              tpmSupport = true;
            }).fd
          ];

        };
        verbatimConfig = ''
          namespaces = [ ]
        '';
      };
    };

    users.groups.qemu = { };
    users.users.${user.name}.extraGroups = [ "qemu-libvirtd" "libvirt" "libvirtd" ];
  };
}

