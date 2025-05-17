{ config, lib, pkgs, username, ... }:
with lib;
let
  cfg = config.virtualisation.kvm-system;
in
{
  options.virtualisation.kvm-system = with types; {
    enable = mkBoolOpt false "Whether or not to enable KVM virtualisation.";
    vfioIds =
      mkOpt (listOf str) [ "10de:1b80" "10de:10f0" ] # Secondary 16x
        "The hardware IDs to pass through to a virtual machine.";
  };

  config = mkIf cfg.enable {
    boot = {
      kernelModules = [
        "kvm-amd"
        "vfio_virqfd"
        "vfio_pci"
        "vfio_iommu_type1"
        "vfio"
      ];
      kernelParams = [
        "amd_iommu=on"
        "amd_iommu=pt"
        "kvm.ignore_msrs=1"
      ];
      extraModprobeConfig = ''
        options kvm_amd nested=1
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
    users.users.${username}.extraGroups = [ "qemu-libvirtd" "libvirt" "libvirtd" ];
  };
}

