{ config, pkgs, inputs, username, hostName, configDir, ... }:

{
  # Import necessary modules
  imports = [
    # Import base NixOS configuration modules here
    # For example, a minimal setup might need networking, users, etc.
    # <nixpkgs/nixos/modules/services/networking/networkmanager.nix>
    # <nixpkgs/nixos/modules/system/boot/loader/systemd-boot/systemd-boot.nix>
    # <nixpkgs/nixos/modules/system/etc/passwd.nix>
    ./modules/system/suites/common/default.nix
    ./modules/system/suites/lab/default.nix
    ./modules/system/suites/desktop/default.nix
  ];

  # Define the hostname using the specialArgs passed from the flake
  networking.hostName = hostName;

  # Configure bootloader (example: systemd-boot)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Configure users (example: using the username from specialArgs)
  users.users.${username} = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" ]; # Add your user to necessary groups
    packages = with pkgs; [
      # Add any packages you want available to this user system-wide
    ];
  };

  # Enable SSH for remote access
  services.openssh.enable = true;

  # Enable the Nix daemon (usually enabled by default, but good to be explicit)
  nix.daemon.enable = true;

  # Set your system state version. This determines the compatibility of your system configuration.
  # It's recommended to set this to the NixOS version you initially install.
  system.stateVersion = "24.11"; # Replace with your desired version (e.g., "24.05")

  # Add other system configurations here

  # Enable suites
  suites.common.enable = true;
  suites.lab.enable = false;
  suites.desktop.enable = false;

}
