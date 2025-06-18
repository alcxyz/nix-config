# modules/nixos/virtualisation/default.nix
{ config, pkgs, lib, ... }:

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

    # Configure Docker, including rootless mode
    virtualisation.docker = {
      enable = true;
      rootless.enable = true;
      rootless.setSocketVariable = true;
    };

    # Add other virtualization related tools
    environment.systemPackages = with pkgs; [ podman-compose lima ];
  };
}
