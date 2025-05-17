{ config, pkgs, lib, ... }:

{
  config = {
    home.sessionVariables = {
      EDITOR = "nvim";
      DIRENV_LOG_FORMAT = ""; # Moved from users/alc/home.nix
      FLAKE = "/home/alc/nix-config"; # Added from old user module
    };
  };
}
