{ config, lib, pkgs, username, ... }:
with lib;
let
  cfg = config.virtualisation.kvm-system;
in
{
  options.virtualisation.kvm-system = with lib.types; { # Explicitly use lib.types
    enable = lib.mkEnableOption "Whether or not to enable KVM virtualisation."; # Uses mkEnableOption, defaults to false
    vfioIds = lib.mkOption {
      type = listOf str; # listOf and str are from lib.types
      default = [ "10de:1b80" "10de:10f0" ]; # Secondary 16x
      description = "The hardware IDs to pass through to a virtual machine.";
    };
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

    environment.systemPackages = with pkgs; [ guestfs-tools virt-manager swtpm libtpms OVMF looking-glass-client ]; # Removed duplicate swtpm

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

    users.groups.qemu-libvirtd = {}; # Ensure group exists for qemu user
    # users.groups.qemu = { }; # qemu-libvirtd is often the correct group for libvirt
    users.users.${username}.extraGroups = [ "qemu-libvirtd" "libvirt" ]; # Removed redundant "libvirtd"
  };
}
