# ADR-0010: Force AMD iGPU as primary display device on dual-GPU workstation

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `modules/nixos/hardware/display-device-guard.nix`, private host display policy, `modules/nixos/hardware/nvidia.nix`, `modules/nixos/hardware/amd.nix`

## Context

The xyz workstation has two GPUs: an AMD iGPU (CPU-integrated, `amdgpu` driver) and an NVIDIA dGPU (proprietary driver). On a system with multiple GPUs, compositors and EGL/GLX applications default to whichever GPU the system presents first — typically the NVIDIA GPU. This causes two distinct problems in this setup:

1. **GPU passthrough incompatibility (ADR-0005):** The NVIDIA GPU is periodically unbound from its driver for VM passthrough. If the compositor (Hyprland) or display stack is using the NVIDIA GPU, unbinding it crashes the desktop.
2. **VA-API interference:** NVIDIA's proprietary GLVND implementation intercepts Mesa/AMD VA-API calls, causing hardware video decoding to fail or route incorrectly through the NVIDIA stack instead of the AMD GPU's native `radeonsi` driver.

## Decision

The workstation's private host policy selects the AMD iGPU for the compositor
and Mesa display pipeline while keeping the NVIDIA device available for compute
and passthrough. It supplies the device identity, stable alias, required driver,
and display environment through the private module boundary.

The public `hardware.displayDeviceGuard` module creates the configured DRM alias
and verifies its PCI address, PCI ID, and driver before the configured dependent
services start. It has no enabled-by-default device or host identity. The shared
desktop role owns desktop composition; the host imports the guard and its private
policy explicitly. The AMD and NVIDIA hardware modules remain independent.

The policy keeps `AQ_DRM_DEVICES`, the Mesa EGL/GLX selection, and the VA-API
selection explicit. Device numbering is never used as a stable identity. The
September 2026 extraction changes ownership, not the selected GPU or startup
checks; private hardware values and historical redaction follow-up belong in
`nix-secrets`.

## Alternatives Considered

- **PRIME offloading (render offload to NVIDIA)** — Rejected. The opposite of what is needed here; PRIME offload uses the dGPU for rendering and the iGPU for display, which still requires the NVIDIA driver to be active for the compositor and breaks during GPU passthrough.
- **NVIDIA as sole GPU (no AMD driver)** — Rejected. Would require the NVIDIA GPU to remain bound at all times, making GPU passthrough impossible.
- **Blacklisting the NVIDIA driver at boot, loading only for the VM** — Rejected. Would make CUDA and CDI-based container GPU access unavailable when the VM is not running, defeating the purpose of dynamic passthrough.

## Consequences

- Hyprland and the display stack remain stable during GPU passthrough — they never touch the NVIDIA device; the AMD iGPU drives the compositor at all times.
- VA-API hardware video decoding reliably uses the AMD GPU via `radeonsi`, which is well-supported by Mesa.
- The NVIDIA GPU is not used for display or VA-API on the host. CUDA and container GPU access still function via the NVIDIA driver and CDI.
- The display DRM node is referenced through its configured stable alias because card numbering can change between boots.
- If the AMD iGPU PCI address or driver binding changes, login setup fails early with a clear `gpu-display-guard` journal error instead of letting Hyprland crash through Aquamarine.
- Do not remove these environment variables — they are not cosmetic. Without them, Hyprland and the NVIDIA GLVND will race for the NVIDIA GPU, breaking the display when it is passed through to the VM.
