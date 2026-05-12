{
  config,
  inputs,
  self,
  ...
}: let
  inherit (config.alc) inventory username;

  hostK8sRoleFor = hostAttrs: let
    k8sRole = hostAttrs.k8sRole or null;
  in
    if k8sRole == null
    then null
    else inventory.k8sRoles.${k8sRole};
in {
  specialArgsFor = hostName: hostAttrs: {
    inherit inputs inventory hostName username;
    configDir = self;
    hostInventory = hostAttrs;
    hostRole = inventory.roles.${hostAttrs.role};
    hostK8sRole = hostK8sRoleFor hostAttrs;
  };
}
