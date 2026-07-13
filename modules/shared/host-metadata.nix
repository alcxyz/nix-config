{
  lib,
  hostName,
  hostInventory,
  hostRole,
  hostK8sRole ? null,
  username,
  ...
}: let
  inherit (lib) mkOption types;

  k8sEnabled = hostK8sRole != null;
  k8sExtraFlags =
    if k8sEnabled
    then hostK8sRole.extraFlags or []
    else [];
  nodeLabels =
    map (lib.removePrefix "--node-label=")
    (lib.filter (lib.hasPrefix "--node-label=") k8sExtraFlags);
  nodeTaints =
    map (lib.removePrefix "--node-taint=")
    (lib.filter (lib.hasPrefix "--node-taint=") k8sExtraFlags);
in {
  options.alc.host = mkOption {
    description = "Typed host metadata projected from inventory.nix.";
    type = types.submodule {
      options = {
        name = mkOption {type = types.str;};
        system = mkOption {type = types.str;};
        platform = mkOption {type = types.enum ["nixos" "darwin"];};
        role = mkOption {type = types.str;};
        primaryUser = mkOption {type = types.str;};
        aliases = mkOption {
          type = types.listOf types.str;
          default = [];
        };
        roleMetadata = mkOption {
          type = types.attrs;
          default = {};
        };
        inventory = mkOption {
          type = types.attrs;
          default = {};
        };
        k8s = mkOption {
          type = types.submodule {
            options = {
              enabled = mkOption {
                type = types.bool;
                default = false;
              };
              inventoryRole = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
              role = mkOption {
                type = types.nullOr (types.enum ["server" "agent"]);
                default = null;
              };
              schedulable = mkOption {
                type = types.bool;
                default = false;
              };
              maxPods = mkOption {
                type = types.nullOr types.ints.positive;
                default = null;
              };
              labels = mkOption {
                type = types.listOf types.str;
                default = [];
              };
              taints = mkOption {
                type = types.listOf types.str;
                default = [];
              };
              extraFlags = mkOption {
                type = types.listOf types.str;
                default = [];
              };
            };
          };
          default = {};
        };
      };
    };
  };

  config.alc.host = {
    name = hostName;
    inherit (hostInventory) system platform role;
    primaryUser = username;
    aliases = hostInventory.aliases or [];
    roleMetadata = hostRole;
    inventory = hostInventory;
    k8s = {
      enabled = k8sEnabled;
      inventoryRole = hostInventory.k8sRole or null;
      role =
        if k8sEnabled
        then hostK8sRole.role
        else null;
      schedulable =
        if k8sEnabled
        then hostK8sRole.schedulable or true
        else false;
      maxPods =
        if k8sEnabled
        then hostK8sRole.maxPods or 110
        else null;
      labels = nodeLabels;
      taints = nodeTaints;
      extraFlags = k8sExtraFlags;
    };
  };
}
