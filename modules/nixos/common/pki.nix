{
  # eMudhra intermediate-key compromise (2026-10-20):
  # https://www.theregister.com/security/2026/10/20/indian-certification-authority-emudhras-private-keys-compromised-one-of-them-was-the-number-4/5304312
  # NSS 3.131.1 dropped C1, ECC G3 and ECC C3, and the bundle generator
  # rejects a blocklisted name it cannot find, so only G1 remains listed.
  # Remove this workaround when nixpkgs excludes G1 too:
  # https://git.alc.xyz/alcxyz/nix-config/issues/775
  security.pki.caCertificateBlacklist = [
    "emSign Root CA - G1"
  ];
}
