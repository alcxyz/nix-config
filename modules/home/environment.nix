{ config, pkgs, lib, ... }:

{
  config = {
    home.sessionVariables = {
      EDITOR = "nvim";
    };
  };
}
