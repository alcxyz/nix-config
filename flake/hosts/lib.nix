{
  config,
  inputs,
  self,
  ...
}: let
  inherit (config.alc) inventory username;

  hostK8sRoleFor = hostAttrs:
    if hostAttrs.k8sRole == null
    then null
    else inventory.k8sRoles.${hostAttrs.k8sRole};
in {
  specialArgsFor = hostName: hostAttrs: {
    inherit inputs inventory hostName username;
    configDir = self;
    hostInventory = hostAttrs;
    hostRole = inventory.roles.${hostAttrs.role};
    hostK8sRole = hostK8sRoleFor hostAttrs;
  };
}
