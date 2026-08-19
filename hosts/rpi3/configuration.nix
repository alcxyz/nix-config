{configDir, ...}: {
  imports = [
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/server.nix"
    "${configDir}/modules/nixos/profiles/raspberry-pi-3-direct-client/default.nix"
  ];
}
