{...}: {
  flake.nixosModules.credentialConsent = import ../modules/nixos/security/credential-consent;
}
