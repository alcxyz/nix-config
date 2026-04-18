# ADR-0005: GPU passthrough via dynamic driver bind/unbind using libvirt hooks

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `modules/nixos/virtualisation/kvm/gpu-passthrough.nix`, `hosts/xyz/configuration.nix`

## Context

The xyz workstation has one NVIDIA dGPU used for Linux workloads (CUDA containers, Steam, video encoding in Stash and Plex) and a Windows 11 VM via KVM/QEMU. True GPU passthrough (VFIO) requires exclusive ownership — the GPU must be bound to `vfio-pci` for the VM and to the NVIDIA driver for the host. There is no second dedicated host GPU; the AMD iGPU (amdgpu) serves as the display device and compositor GPU at all times (see ADR-0010).

## Decision

Dynamic GPU passthrough is implemented as a custom NixOS module using libvirt's hook mechanism (`/etc/libvirt/hooks/qemu`).

**On VM start (`prepare/begin`):**
1. Stop Docker Compose stacks consuming the GPU (configurable via `gpuContainerStacks`)
2. Unload NVIDIA kernel modules: `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm`, `nvidia`
3. Bind the GPU PCI devices to `vfio-pci`

**On VM stop (`release/end`):**
1. Unbind GPU from `vfio-pci`
2. Trigger PCI bus rescan
3. Reload NVIDIA modules
4. Regenerate NVIDIA CDI spec so containers can see the GPU again

VFIO modules are loaded at boot but the GPU is not initially bound to them. IOMMU is enabled via `amd_iommu=on iommu=pt`. A Looking Glass shared memory device is configured for low-latency display capture from the VM.

## Alternatives Considered

- **Static passthrough (GPU always assigned to VM)** — Rejected. The NVIDIA GPU would be permanently unavailable to the host, making CUDA containers, Steam-in-Docker, and hardware video encoding impossible without running the VM.
- **SR-IOV virtual functions** — Rejected. The NVIDIA consumer GPU does not support SR-IOV; this is an enterprise feature not available on the hardware in use.
- **Separate dedicated host GPU** — Rejected. Would require additional hardware and PCIe slot; the AMD iGPU already covers display and compositor needs without a second discrete card.

## Consequences

- The NVIDIA GPU is fully available for Linux workloads when the VM is not running, and fully available to the VM when it is.
- Starting the VM stops all GPU consumer containers (Stash, Steam stacks). This is disruptive to any active workload using those containers — stopping them is intentional and required for clean driver unbind.
- Any new Docker Compose stack that uses the NVIDIA GPU must be added to `gpuContainerStacks` in `hosts/xyz/configuration.nix`, or it will hold the NVIDIA driver open and prevent clean passthrough.
- If the NVIDIA module fails to reload after the VM exits (e.g. a process still holds the device), the GPU will be inaccessible until manual recovery. The AMD iGPU remains unaffected.
- Do not remove VFIO modules from the kernel module list — they must be loaded at boot even though the GPU is not initially bound to them.
