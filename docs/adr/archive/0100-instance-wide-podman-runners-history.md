**History of** [ADR-0100](../0100-instance-wide-podman-runners.md): text replaced on 2026-11-03.

## Text replaced on 2026-11-03

When the dedicated `ci-fast` runners were retired ([#957](https://git.alc.xyz/alcxyz/nix-config/issues/957)), from the decision:

> - The Podman runners (ADR-0074, ADR-0097) register instance-wide, so they take
>   jobs from every repository on the instance: the `alcxyz` user's and every
>   organisation's, present and future. Each host keeps its Podman pool runner,
>   plus the `ci-fast` runners of ADR-0097, and every owner can use all four
>   hosts.

> - `podmanCanary.registrationScope` (and each extra runner's, which follows the
>   canary's) records the scope of the registration token.
