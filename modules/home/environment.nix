{ config, pkgs, lib, ... }:

{
  home.sessionVariables = {
    EDITOR = "nvim";
    DIRENV_LOG_FORMAT = "";
    FLAKE = "/home/alc/nix-config";
  };
}
