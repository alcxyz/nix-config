{pkgs}:
pkgs.testers.runNixOSTest {
  name = "zfs-linux73";
  node.pkgs = pkgs.lib.mkForce pkgs;
  nodes.machine = {
    imports = [../../modules/nixos/hardware/zfs-latest-kernel.nix];
    system.stateVersion = "26.05";
    networking.hostId = "deadbeef";
    virtualisation.memorySize = 2048;
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    release = machine.succeed("uname -r").strip()
    assert release == "7.3" or release.startswith("7.3."), release
    machine.succeed("modprobe zfs")
    versions = machine.succeed("zfs version").splitlines()
    assert len(versions) == 2, versions
    assert versions[0].removeprefix("zfs-") == versions[1].removeprefix("zfs-kmod-"), versions

    # File vdevs, cache writes and imports exercise filesystem access from
    # kernel threads, one of the Linux 7.3 compatibility changes.
    machine.succeed("truncate -s 512M /var/lib/zfs-candidate.img")
    machine.succeed("zpool create -f -o cachefile=/var/lib/zfs-candidate.cache -m /srv/candidate candidate /var/lib/zfs-candidate.img")
    machine.succeed("zfs set compression=lz4 candidate")
    machine.succeed("printf original > /srv/candidate/payload")
    machine.succeed("zfs snapshot candidate@initial")
    machine.succeed("printf changed > /srv/candidate/payload")
    machine.succeed("zfs rollback candidate@initial")
    assert machine.succeed("cat /srv/candidate/payload") == "original"
    machine.wait_until_succeeds("test -s /var/lib/zfs-candidate.cache", timeout=30)
    machine.succeed("zpool scrub candidate")
    machine.succeed("zpool wait -t scrub candidate")
    assert "is healthy" in machine.succeed("zpool status -x candidate")
    machine.succeed("zpool export candidate")
    machine.succeed("zpool import -d /var/lib candidate")
    assert machine.succeed("cat /srv/candidate/payload") == "original"
    machine.succeed("zpool destroy candidate")
  '';
}
