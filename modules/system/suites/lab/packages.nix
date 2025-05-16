{ config, pkgs, lib, ... }:

{
  config = {
    environment.systemPackages = with pkgs; [
      terraform
      opentofu
      ansible
      k3s
      kubectl
      kubernetes-helm
      kubeswitch
      k9s
      lens
      termshark
      atac
      azure-cli
      google-cloud-sdk
      devbox
      cockpit
      podman-compose
      lima
    ];
  };
}
