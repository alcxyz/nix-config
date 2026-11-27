# The kernel console of one host reaches another host's journal through
# netconsole: the sender's target appears once the receiver's MAC address is
# known, is repaired when disabled and outlives its service, informational
# messages pass the console log level, other sources are dropped, a `<N>`
# prefix does not set the journal priority, and a real panic arrives.
{pkgs}:
if pkgs.stdenv.hostPlatform.system != "x86_64-linux"
then pkgs.runCommand "pressure-recorder-netconsole-unsupported-platform" {} ''touch "$out"''
else let
  receiverAddress = "192.0.2.10";
  senderAddress = "192.0.2.20";
  module = ../../modules/nixos/services/pressure-recorder;
  lan = address: {lib, ...}: {
    virtualisation.vlans = [1];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
    system.stateVersion = "25.11";
  };
in
  pkgs.testers.runNixOSTest {
    name = "pressure-recorder-netconsole";
    nodes.receiver = {
      imports = [module (lan receiverAddress)];
      services.pressure-recorder.receiver = {
        enable = true;
        listenAddress = receiverAddress;
        allowedSources = [senderAddress];
        netconsole.sources.sender.address = senderAddress;
      };
    };
    nodes.sender = {
      imports = [module (lan senderAddress)];
      services.pressure-recorder.sender = {
        enable = true;
        url = "http://${receiverAddress}:19532";
        netconsole = {
          enable = true;
          interface = "eth1";
          localAddress = senderAddress;
          remoteAddress = receiverAddress;
        };
      };
    };

    testScript = ''
      target = "/sys/kernel/config/netconsole/receiver"
      journal = "journalctl -t netconsole-sender -o cat --no-pager"

      start_all()
      receiver.wait_for_unit("netconsole-sender.socket")
      receiver.wait_for_unit("firewall.service")
      sender.wait_for_unit("netconsole-target.service")
      sender.wait_until_succeeds(f"grep -qx 1 {target}/enabled", timeout=60)
      sender.succeed(f"grep -qx eth1 {target}/dev_name")
      sender.succeed(f"grep -qx ${receiverAddress} {target}/remote_ip")
      sender.succeed("test $(cut -f1 /proc/sys/kernel/printk) = 7")
      sender.succeed("grep -qw loglevel=7 /proc/cmdline")

      # An informational kernel message arrives. Whether the sender had to
      # probe for the receiver's MAC address depends on boot order, so the
      # probe line is not required.
      sender.succeed("echo '<6>fixture-info-message' > /dev/kmsg")
      receiver.wait_until_succeeds(f"{journal} | grep -F fixture-info-message", timeout=30)

      # Another source is dropped by the socket filter.
      receiver.succeed("bash -c 'echo fixture-foreign-source > /dev/udp/${receiverAddress}/6666'")

      # A priority prefix from the allowed source IP stays text and logs at
      # the service's default priority (info), not at emerg.
      sender.succeed("bash -c 'echo \"<0>fixture-priority-prefix\" > /dev/udp/${receiverAddress}/6666'")
      receiver.wait_until_succeeds(f"{journal} | grep -Fx '<0>fixture-priority-prefix'", timeout=30)
      receiver.succeed("journalctl -t netconsole-sender -p 6..6 -o cat --no-pager | grep -Fx '<0>fixture-priority-prefix'")
      receiver.fail("journalctl -t netconsole-sender -p 0..5 -o cat --no-pager | grep -F fixture-priority-prefix")

      # A target the kernel or an operator disabled is enabled again.
      sender.succeed(f"echo 0 > {target}/enabled")
      sender.wait_until_succeeds(f"grep -qx 1 {target}/enabled", timeout=60)
      sender.succeed("echo '<6>fixture-after-repair' > /dev/kmsg")
      receiver.wait_until_succeeds(f"{journal} | grep -F fixture-after-repair", timeout=30)
      receiver.fail(f"{journal} | grep -F fixture-foreign-source")

      # Stopping the service leaves the target working, and starting it
      # again keeps the target as it is.
      sender.succeed("systemctl stop netconsole-target.service")
      sender.succeed(f"grep -qx 1 {target}/enabled")
      sender.succeed("echo '<6>fixture-while-stopped' > /dev/kmsg")
      receiver.wait_until_succeeds(f"{journal} | grep -F fixture-while-stopped", timeout=30)
      sender.succeed("systemctl start netconsole-target.service")
      sender.sleep(2)
      sender.succeed("systemctl is-active netconsole-target.service")
      sender.succeed(f"grep -qx 1 {target}/enabled")
      sender.succeed("echo '<6>fixture-after-restart' > /dev/kmsg")
      receiver.wait_until_succeeds(f"{journal} | grep -F fixture-after-restart", timeout=30)

      # A panic reaches the receiver.
      sender.succeed("echo 1 > /proc/sys/kernel/sysrq")
      sender.execute("(sleep 1; echo c > /proc/sysrq-trigger) > /dev/null 2>&1 &")
      receiver.wait_until_succeeds(f"{journal} | grep -F 'Kernel panic - not syncing'", timeout=60)
      sender.crash()
    '';
  }
