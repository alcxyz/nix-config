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

  services.pihole-native.blocklists = [
    {
      url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.samsung.txt";
      comment = "HaGeZi native Samsung tracker";
    }
  ];

  services.nixbox-direct-client = {
    room = "Bedroom";
    streamFps = 30;
  };
}
