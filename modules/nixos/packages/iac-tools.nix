# modules/nixos/packages/iac-tools.nix
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.iacTools;
in
{
  options.iacTools = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Infrastructure as Code (IaC) tools like Terraform and Ansible.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      terraform
      opentofu
      ansible
    ];
  };
}
