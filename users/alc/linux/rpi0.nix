# users/alc/linux/rpi0.nix
{
  inputs,
  config,
  configDir,
  pkgs,
  hostRole,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  imports = [
    "${configDir}/users/alc/linux/common.nix"
    "${configDir}/modules/home-manager/services/dms/default.nix"
    "${configDir}/modules/home-manager/services/waynergy/default.nix"
  ];

  home.packages = pkgsets.home.${hostRole.homePackageSet};

  # Keep rpi0's user profile narrow. It needs cluster client access for local
  # checks, but should not consume the full operator secret set.
  sops.secrets.k3s_kubeconfig = {
    sopsFile = "${inputs.nix-secrets}/cluster-bootstrap/k3s-kubeconfig.yaml";
    key = "k3s_kubeconfig";
  };

  programs.kubernetes.managed = {
    enable = true;
    kubeconfig = config.sops.secrets.k3s_kubeconfig.path;
    defaultContext = "funhouse";
  };

  services.dms = {
    enable = true;
    profile = "compact";
    pluginSettingsFile = null;
    dock = {
      enable = true;
      autoHide = true;
    };
    polkitDialog = {
      width = 760;
      height = 460;
    };
    settings = {
      customPowerActionReboot = "couch-session-power-action reboot";
      customPowerActionPowerOff = "couch-session-power-action poweroff";
    };
  };

  services.waynergy = {
    enable = true;
    screenName = "rpi0";
    sourceKeyboard = "mac";
    backend = "uinput";
    requireLanAddress = true;
    useFocusedMonitorGeometry = true;
  };
}
