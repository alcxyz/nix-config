{
  configDir,
  inputs,
  ...
}: {
  imports = [
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/server.nix"
    "${configDir}/modules/nixos/profiles/raspberry-pi-3-direct-client/default.nix"
    "${configDir}/modules/nixos/services/pihole-native/default.nix"
    inputs.nix-secrets.nixosModules.rpi1Pihole
  ];

  services.nixbox-direct-client.streamFps = 30;
}
