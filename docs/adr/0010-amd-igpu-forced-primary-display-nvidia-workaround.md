# ADR-0010: Force AMD iGPU as primary display device on dual-GPU workstation

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `modules/nixos/common/desktop.nix`, `modules/nixos/hardware/nvidia.nix`, `modules/nixos/hardware/amd.nix`

## Context

The xyz workstation has two GPUs: an AMD iGPU (CPU-integrated, `amdgpu` driver) and an NVIDIA dGPU (proprietary driver). On a system with multiple GPUs, compositors and EGL/GLX applications default to whichever GPU the system presents first — typically the NVIDIA GPU. This causes two distinct problems in this setup:

1. **GPU passthrough incompatibility (ADR-0005):** The NVIDIA GPU is periodically unbound from its driver for VM passthrough. If the compositor (Hyprland) or display stack is using the NVIDIA GPU, unbinding it crashes the desktop.
2. **VA-API interference:** NVIDIA's proprietary GLVND implementation intercepts Mesa/AMD VA-API calls, causing hardware video decoding to fail or route incorrectly through the NVIDIA stack instead of the AMD GPU's native `radeonsi` driver.

## Decision

The AMD iGPU is forced as the exclusive display and compositor GPU via environment variables set in `modules/nixos/common/desktop.nix`:

```nix
environment.sessionVariables = {
  AQ_DRM_DEVICES              = "/dev/dri/amd-display-card";  # Hyprland: use AMD DRM node only
  __EGL_VENDOR_LIBRARY_FILENAMES = "${pkgs.mesa.drivers}/share/glvnd/egl_vendor.d/50_mesa.json";
  __GLX_VENDOR_LIBRARY_NAME   = "mesa";             # Force Mesa over NVIDIA GLVND
  LIBVA_DRIVER_NAME           = "radeonsi";         # Force AMD VA-API driver
};
```

Both `nvidia.nix` and `amd.nix` hardware modules are imported simultaneously — the NVIDIA driver remains active for CUDA and container GPU access via CDI; only the display and VA-API pipeline is locked to AMD.

The `/dev/dri/amd-display-card` symlink is created by a udev rule that matches PCI slot `0000:79:00.0`, PCI ID `1002:13C0`, and the `amdgpu` driver. A `gpu-display-guard` systemd service runs before `greetd` and fails the greeter startup if that symlink is missing, resolves to another PCI device, has a different PCI ID, or is not bound to `amdgpu`.

## Alternatives Considered

- **PRIME offloading (render offload to NVIDIA)** — Rejected. The opposite of what is needed here; PRIME offload uses the dGPU for rendering and the iGPU for display, which still requires the NVIDIA driver to be active for the compositor and breaks during GPU passthrough.
- **NVIDIA as sole GPU (no AMD driver)** — Rejected. Would require the NVIDIA GPU to remain bound at all times, making GPU passthrough impossible.
- **Blacklisting the NVIDIA driver at boot, loading only for the VM** — Rejected. Would make CUDA and CDI-based container GPU access unavailable when the VM is not running, defeating the purpose of dynamic passthrough.

## Consequences

- Hyprland and the display stack remain stable during GPU passthrough — they never touch the NVIDIA device; the AMD iGPU drives the compositor at all times.
- VA-API hardware video decoding reliably uses the AMD GPU via `radeonsi`, which is well-supported by Mesa.
- The NVIDIA GPU is not used for display or VA-API on the host. CUDA and container GPU access still function via the NVIDIA driver and CDI.
- The AMD DRM node is referenced through `/dev/dri/amd-display-card`, not `/dev/dri/card*`, because card numbering can change between boots.
- If the AMD iGPU PCI address or driver binding changes, login setup fails early with a clear `gpu-display-guard` journal error instead of letting Hyprland crash through Aquamarine.
- Do not remove these environment variables — they are not cosmetic. Without them, Hyprland and the NVIDIA GLVND will race for the NVIDIA GPU, breaking the display when it is passed through to the VM.
