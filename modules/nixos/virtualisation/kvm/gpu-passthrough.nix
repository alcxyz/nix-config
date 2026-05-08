# modules/nixos/virtualisation/kvm/gpu-passthrough.nix
#
# Dynamic GPU passthrough for a dedicated VM.
# On VM start: stops GPU containers, unbinds nvidia, binds vfio-pci.
# On VM stop:  unbinds vfio-pci, reloads nvidia, restarts containers.
{ config, pkgs, lib, username, ... }:

with lib;

let
  cfg = config.virtualisation.kvm.gpu-passthrough;

  qemuHook = pkgs.writeShellScript "gpu-passthrough-hook" ''
    GUEST_NAME="$1"
    OPERATION="$2"
    SUB_OPERATION="$3"

    # Only act on the designated VM
    if [ "$GUEST_NAME" != "${cfg.vmName}" ]; then
      exit 0
    fi

    log() { echo "gpu-passthrough: $*"; }

    stop_gpu_consumers() {
      log "stopping GPU consumer containers..."
      ${concatMapStringsSep "\n      " (service: ''
        systemctl stop ${escapeShellArg service} || true'') cfg.gpuSystemdServices}

      ${concatMapStringsSep "\n      " (stack: ''
        if [ -d "${stack}" ]; then
          ${pkgs.docker}/bin/docker compose -f "${stack}/docker-compose.yml" down --timeout 30 || true
        fi'') cfg.gpuContainerStacks}

      # Wait for nvidia users to release
      local attempts=0
      while ${pkgs.util-linux}/bin/lsof /dev/nvidia* >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 15 ]; then
          log "WARNING: nvidia devices still in use after 15s"
          break
        fi
        sleep 1
      done

      log "unloading nvidia kernel modules..."
      modprobe -r nvidia_uvm    2>/dev/null || true
      modprobe -r nvidia_drm    2>/dev/null || true
      modprobe -r nvidia_modeset 2>/dev/null || true
      modprobe -r nvidia        2>/dev/null || true
    }

    bind_vfio() {
      log "binding GPU to vfio-pci..."
      modprobe vfio-pci

      ${concatMapStringsSep "\n      " (addr: ''
        if [ -e /sys/bus/pci/devices/${addr}/driver ]; then
          echo "${addr}" > /sys/bus/pci/devices/${addr}/driver/unbind 2>/dev/null || true
        fi
        echo "vfio-pci" > /sys/bus/pci/devices/${addr}/driver_override
        echo "${addr}" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true'') cfg.gpuPciAddresses}
    }

    unbind_vfio() {
      log "unbinding GPU from vfio-pci..."
      ${concatMapStringsSep "\n      " (addr: ''
        echo "${addr}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        echo "" > /sys/bus/pci/devices/${addr}/driver_override'') cfg.gpuPciAddresses}

      log "rescanning PCI bus..."
      echo 1 > /sys/bus/pci/rescan
      sleep 2

      log "reloading nvidia kernel modules..."
      modprobe nvidia
      modprobe nvidia_modeset
      modprobe nvidia_drm
      modprobe nvidia_uvm

      # Regenerate CDI spec so containers can find the GPU again
      if command -v nvidia-ctk >/dev/null 2>&1; then
        log "regenerating nvidia CDI spec..."
        nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml 2>/dev/null || true
      fi
    }

    start_gpu_consumers() {
      log "restarting GPU consumer containers..."
      ${concatMapStringsSep "\n      " (service: ''
        systemctl start ${escapeShellArg service} || true'') cfg.gpuSystemdServices}

      ${concatMapStringsSep "\n      " (stack: ''
        if [ -d "${stack}" ]; then
          ${pkgs.docker}/bin/docker compose -f "${stack}/docker-compose.yml" up -d || true
        fi'') cfg.gpuContainerStacks}
    }

    case "$OPERATION/$SUB_OPERATION" in
      prepare/begin)
        log "preparing GPU passthrough for $GUEST_NAME..."
        stop_gpu_consumers
        sleep 1
        bind_vfio
        log "GPU ready for VM"
        ;;
      release/end)
        log "releasing GPU from $GUEST_NAME..."
        unbind_vfio
        sleep 1
        start_gpu_consumers
        log "GPU restored to host"
        ;;
    esac
  '';

in
{
  options.virtualisation.kvm.gpu-passthrough = {
    enable = mkEnableOption "Dynamic GPU passthrough for a VM";

    vmName = mkOption {
      type = types.str;
      default = "win11";
      description = "Name of the libvirt VM that receives the GPU.";
    };

    gpuPciAddresses = mkOption {
      type = types.listOf types.str;
      default = [ "0000:01:00.0" "0000:01:00.1" ];
      description = "PCI bus addresses of the GPU (and audio) devices.";
    };

    gpuContainerStacks = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Docker-compose directories using the GPU (stopped before passthrough).";
    };

    gpuSystemdServices = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Systemd services using the GPU (stopped before passthrough).";
    };
  };

  config = mkIf cfg.enable {
    # IOMMU must be enabled for passthrough
    boot.kernelParams = [ "amd_iommu=on" "iommu=pt" ];

    # vfio modules available (but idle — no IDs assigned at boot)
    boot.kernelModules = [ "vfio" "vfio_iommu_type1" "vfio_pci" ];

    boot.extraModprobeConfig = ''
      options kvm_amd nested=1
      options kvm ignore_msrs=1
    '';

    # Register the hook with libvirtd
    virtualisation.libvirtd.hooks.qemu = {
      "gpu-passthrough" = qemuHook;
    };

    # Looking Glass shared memory + packages
    environment.systemPackages = [ pkgs.looking-glass-client ];

    systemd.tmpfiles.rules = [
      "f /dev/shm/looking-glass 0660 ${username} kvm -"
    ];
  };
}
