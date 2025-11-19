# modules/nixos/virtualisation/default.nix
{ config, pkgs, lib, username, ... }:

with lib;

let
  cfg = config.containerRuntimes;
in
{
  options.containerRuntimes = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable container runtimes and related settings.";
    };
  };

  config = mkIf cfg.enable {
    # Enable general container support
    virtualisation.containers.enable = true;

    # Configure Docker (system-level, not rootless)
    virtualisation.docker = {
      enable = true;
    };

    users.users.${username}.extraGroups = [ "docker" ]; 

    # Add other virtualization related tools
    environment.systemPackages = with pkgs; [ ];
  };
}
