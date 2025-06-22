# modules/nixos/packages/kubernetes-tools.nix
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.kubernetesTools;
in
{
  options.kubernetesTools = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable common Kubernetes command-line tools.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      kubectl
      kubernetes-helm
      kubeswitch
      k9s
    ];
  };
}
