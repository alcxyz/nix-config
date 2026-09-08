{
  self,
  pkgs,
}: let
  lib = pkgs.lib;
  original = self.nixosConfigurations.xyz.config;
  remote = self.nixosConfigurations.xyz-tank-on-xev.config;
  owner = self.nixosConfigurations.xev-tank-owner.config;
  baseOwner = self.nixosConfigurations.xev.config;
  bulkBranches =
    builtins.filter
    (target: original.fileSystems.${target}.fsType == "xfs")
    original.fileSystems."/tank".depends;
  secureUnit = "xyz-secure-zfs-children";
  consumerNames = ["plex" "qbittorrent" "stash" "torrent-shared-media-permissions" "torrent-shared-media-zfs-properties"];
  ownerMount = lib.findFirst (mount: mount.where == "/tank") (throw "missing explicit tank mount") owner.systemd.mounts;
  guarded = name:
    builtins.elem "tank.mount" remote.systemd.services.${name}.bindsTo
    && remote.systemd.services.${name}.unitConfig ? ConditionPathExists;
in
  assert original.fileSystems."/tank".fsType == "fuse.mergerfs";
  assert !(baseOwner.fileSystems ? "/tank");
  assert remote.fileSystems."/tank".fsType == "nfs";
  assert builtins.elem "hard" remote.fileSystems."/tank".options;
  assert builtins.all (target: !(builtins.hasAttr target remote.fileSystems)) bulkBranches;
  assert builtins.all (target: owner.fileSystems.${target}.device == original.fileSystems.${target}.device) bulkBranches;
  assert owner.fileSystems."/tank".device == original.fileSystems."/tank".device;
  assert owner.fileSystems."/tank".options == original.fileSystems."/tank".options;
  assert builtins.length ownerMount.bindsTo == builtins.length bulkBranches;
  assert builtins.all (unit: builtins.elem unit ownerMount.after) ownerMount.bindsTo;
  assert builtins.elem "local-fs.target" ownerMount.wantedBy;
  assert builtins.elem "tank.mount" owner.systemd.services.nfs-server.bindsTo;
  assert builtins.all guarded consumerNames;
  assert builtins.all (s: !(lib.hasPrefix "/tank" s.path)) remote.services.nfs.managed.shares;
  assert builtins.all (s: builtins.elem s owner.services.nfs.managed.shares)
  (builtins.filter (s: lib.hasPrefix "/tank/" s.path) original.services.nfs.managed.shares);
  assert remote.systemd.services.${secureUnit}.script == original.systemd.services.${secureUnit}.script;
  assert remote.systemd.services.xyz-games-dataset.serviceConfig.ExecStart == original.systemd.services.xyz-games-dataset.serviceConfig.ExecStart;
  assert remote.boot.zfs.extraPools == original.boot.zfs.extraPools;
  assert owner.boot.zfs.extraPools == baseOwner.boot.zfs.extraPools;
  assert remote.fileSystems."/var/lib/plex".device == original.fileSystems."/var/lib/plex".device;
  assert remote.fileSystems."/var/lib/qbittorrent".device == original.fileSystems."/var/lib/qbittorrent".device;
  assert remote.fileSystems."/var/lib/stash".device == original.fileSystems."/var/lib/stash".device;
    pkgs.runCommand "tank-migration-contract" {} ''
      touch "$out"
    ''
