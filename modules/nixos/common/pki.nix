{
  # eMudhra intermediate-key compromise (2026-10-20):
  # https://www.theregister.com/security/2026/10/20/indian-certification-authority-emudhras-private-keys-compromised-one-of-them-was-the-number-4/5304312
  # Remove this workaround when nixpkgs excludes all four roots:
  # https://git.alc.xyz/alcxyz/nix-config/issues/775
  security.pki.caCertificateBlacklist = [
    "emSign Root CA - G1"
    "emSign Root CA - C1"
    "emSign ECC Root CA - G3"
    "emSign ECC Root CA - C3"
  ];
}
