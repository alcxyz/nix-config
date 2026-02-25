# modules/home-manager/programs/ai/default.nix
{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.programs.ai;
in
{
  options.programs.ai = {
    enable = mkEnableOption "Module for vibe coding stuff";
  };

  config = mkIf cfg.enable {
    programs.opencode = {
      enable = true;
      settings = {
        theme = "opencode";
      };
    };

    programs.gemini-cli = {
      enable = true;
    };
  };

}
