{...}: {
  flake.nixosModules.credentialConsent = import ../modules/nixos/security/credential-consent;
  flake.nixosModules.isolatedAgent = import ../modules/nixos/services/isolated-agent;
}
