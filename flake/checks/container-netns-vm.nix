{pkgs}: let
  audit = pkgs.writeShellApplication {
    name = "container-netns-audit";
    runtimeInputs = [pkgs.gawk];
    text = builtins.readFile ../../modules/nixos/virtualisation/container-netns/audit.sh;
  };
  unsafeFixture = pkgs.writeShellApplication {
    name = "container-netns-unsafe-kernel-fixture";
    runtimeInputs = [
      audit
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.util-linux
    ];
    text = ''
      set -euo pipefail

      mount --types tmpfs tmpfs /run
      mount --make-shared /run
      install -d -m 0755 /run/netns
      mount --rbind /run/netns /run/netns
      mount --make-rshared /run/netns

      ancestor_shared=$(awk '$5 == "/run" { for (i = 7; i <= NF && $i != "-"; i++) if ($i ~ /^shared:/) print $i }' /proc/self/mountinfo)
      netns_shared=$(awk '$5 == "/run/netns" { for (i = 7; i <= NF && $i != "-"; i++) if ($i ~ /^shared:/) print $i }' /proc/self/mountinfo)
      test -n "$ancestor_shared"
      test "$netns_shared" = "$ancestor_shared"

      touch /run/netns/cni-fixture
      mount --bind /proc/self/ns/net /run/netns/cni-fixture
      test "$(awk '$5 == "/run/netns/cni-fixture" { count++ } END { print count + 0 }' /proc/self/mountinfo)" -eq 2

      if container-netns-audit >audit.out 2>audit.err; then
        echo "audit accepted the shared-ancestor shadow topology" >&2
        exit 1
      fi
      grep -Fq 'shares a propagation peer group with ancestor /run' audit.err
      grep -Fq 'is outside the /run/netns mount subtree' audit.err
    '';
  };
  correctedFixture = pkgs.writeShellApplication {
    name = "container-netns-corrected-kernel-fixture";
    runtimeInputs = [
      audit
      pkgs.coreutils
      pkgs.gawk
      pkgs.util-linux
    ];
    text = ''
      set -euo pipefail

      mount --types tmpfs tmpfs /run
      mount --make-shared /run
      install -d -m 0755 /run/netns
      mount --rbind /run/netns /run/netns
      mount --make-rprivate /run/netns
      mount --make-rshared /run/netns

      ancestor_shared=$(awk '$5 == "/run" { for (i = 7; i <= NF && $i != "-"; i++) if ($i ~ /^shared:/) print $i }' /proc/self/mountinfo)
      netns_shared=$(awk '$5 == "/run/netns" { for (i = 7; i <= NF && $i != "-"; i++) if ($i ~ /^shared:/) print $i }' /proc/self/mountinfo)
      test -n "$ancestor_shared"
      test -n "$netns_shared"
      test "$netns_shared" != "$ancestor_shared"

      touch /run/netns/cni-fixture
      mount --bind /proc/self/ns/net /run/netns/cni-fixture
      test "$(awk '$5 == "/run/netns/cni-fixture" { count++ } END { print count + 0 }' /proc/self/mountinfo)" -eq 1
      container-netns-audit
    '';
  };
in
  pkgs.testers.runNixOSTest {
    name = "container-netns-kernel-propagation";
    nodes.machine = {
      virtualisation.memorySize = 768;
      environment.systemPackages = [pkgs.util-linux];
      system.stateVersion = "25.11";
    };
    testScript = ''
      start_all()
      machine.wait_for_unit("multi-user.target")
      before = machine.succeed("awk '$5 == \"/run\" { print $1, $2, $4, $5, $6 }' /proc/self/mountinfo")
      machine.fail("findmnt --mountpoint /run/netns")

      machine.succeed("unshare --mount --propagation private ${unsafeFixture}/bin/container-netns-unsafe-kernel-fixture")
      assert machine.succeed("awk '$5 == \"/run\" { print $1, $2, $4, $5, $6 }' /proc/self/mountinfo") == before
      machine.fail("findmnt --mountpoint /run/netns")

      machine.succeed("unshare --mount --propagation private ${correctedFixture}/bin/container-netns-corrected-kernel-fixture")
      assert machine.succeed("awk '$5 == \"/run\" { print $1, $2, $4, $5, $6 }' /proc/self/mountinfo") == before
      machine.fail("findmnt --mountpoint /run/netns")
    '';
  }
