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
  specialArgsFor = hostName: hostAttrs: let
    accountUsername = hostAttrs.accountUsername or username;
    accountHomeDirectory =
      hostAttrs.accountHomeDirectory
      or (
        if hostAttrs.platform == "darwin"
        then "/Users/${accountUsername}"
        else "/home/${accountUsername}"
      );
  in {
    inherit inputs inventory hostName username accountUsername accountHomeDirectory;
    # Keep the repository identity stable when a host's OS account differs.
    configDir = self;
    hostInventory = hostAttrs;
    hostRole = inventory.roles.${hostAttrs.role};
    hostK8sRole = hostK8sRoleFor hostAttrs;
  };
}
