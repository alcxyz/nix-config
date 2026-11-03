# Production probe and VRRP election against synthetic local HTTPS APIs.
# No k3s instance, host access or cluster credentials are used.
{pkgs}: let
  node = address: peer: priority: {
    config,
    pkgs,
    ...
  }: {
    imports = [../../modules/nixos/services/k8s-api-vip];
    networking.interfaces.eth1.ipv4.addresses = [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
    services.k8s-api-vip = {
      enable = true;
      interface = "eth1";
      sourceIp = address;
      peers = [peer];
      vip = "192.0.2.20";
      prefixLength = 24;
      virtualRouterId = 42;
      inherit priority;
      readinessCaFile = "/run/api-fixture/ca.pem";
      readinessClient = {
        certificateFile = "/run/api-fixture/cert.pem";
        keyFile = "/run/api-fixture/key.pem";
      };
    };
    # The production ordering hooks stay in place; only k3s is a stand-in.
    systemd.services.k3s = {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./k8s-api-vip-fixture.py}";
        RuntimeDirectory = "api-fixture";
      };
      preStart = ''
        echo 500 > /run/api-state
        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /run/api-fixture/key.pem -out /run/api-fixture/cert.pem \
          -days 1 -subj /CN=fixture.invalid -addext subjectAltName=IP:127.0.0.1 2>/dev/null
        cp /run/api-fixture/cert.pem /run/api-fixture/ca.pem
      '';
    };
    environment.etc."api-ready-probe".source = config.services.keepalived.vrrpScripts.k3s_api.script;
    environment.systemPackages = [pkgs.curl];
    system.stateVersion = "26.11";
  };
in
  pkgs.testers.runNixOSTest {
    name = "k8s-api-vip-readiness";
    nodes = {
      primary = node "192.0.2.10" "192.0.2.11" 150;
      backup = node "192.0.2.11" "192.0.2.10" 100;
    };
    testScript = ''
      import time

      vip = "ip -4 -o address show dev eth1 | grep -F '192.0.2.20/24'"
      probe = "/etc/api-ready-probe"

      def state(machine, response):
          machine.succeed(f"echo {response} > /run/api-state")

      def holds(machine):
          machine.wait_until_succeeds(vip, timeout=30)

      def withdrawn(machine):
          machine.wait_until_fails(vip, timeout=30)

      def stays_withdrawn():
          # More than an election and probe hysteresis, including on startup.
          deadline = time.monotonic() + 8
          while time.monotonic() < deadline:
              primary.fail(vip)
              backup.fail(vip)
              time.sleep(1)

      start_all()
      for machine in (primary, backup):
          machine.wait_for_unit("keepalived.service")
          machine.wait_for_open_port(6443)

      with subtest("TCP listeners and unready APIs cannot acquire the VIP"):
          for machine in (primary, backup):
              machine.fail(probe)
          stays_withdrawn()

      with subtest("only completed HTTP 200 qualifies"):
          for response in ("204", "302", "401", "403", "500", "503", "timeout", "disconnect"):
              state(primary, response)
              primary.fail(probe)
          state(primary, "200")
          # A missing or unusable trust anchor cannot qualify even HTTP 200.
          primary.succeed("mv /run/api-fixture/ca.pem /run/api-fixture/ca.saved")
          primary.fail(probe)
          primary.succeed("echo invalid-fixture-ca > /run/api-fixture/ca.pem")
          primary.fail(probe)
          primary.succeed("mv /run/api-fixture/ca.saved /run/api-fixture/ca.pem")
          # A curlrc must not inject credentials or change the request path.
          primary.succeed("echo 'header = Authorization: forbidden-fixture' > /root/.curlrc")
          primary.succeed("HTTPS_PROXY=http://unreachable.invalid:1 ALL_PROXY=http://unreachable.invalid:1 " + probe)
          holds(primary)
          backup.fail(vip)

      with subtest("existing client fallback, missing files and authenticated failures"):
          state(primary, "auth200")
          primary.succeed(probe)
          for response in ("auth204", "auth302", "auth401", "auth403", "auth500", "authtimeout", "authdisconnect"):
              state(primary, response)
              primary.fail(probe)
          state(primary, "auth200")
          primary.succeed("mv /run/api-fixture/key.pem /run/api-fixture/key.saved")
          primary.fail(probe)
          # Anonymous success must not need any fallback file.
          state(primary, "200")
          primary.succeed(probe)
          primary.succeed("mv /run/api-fixture/key.saved /run/api-fixture/key.pem")
          state(primary, "auth200")
          primary.succeed(probe)
          holds(primary)

      with subtest("an unready preferred node yields to a ready backup"):
          state(backup, "auth200")
          backup.succeed(probe)
          state(primary, "auth500")
          holds(backup)
          withdrawn(primary)
          # Recovery must not preempt an already ready holder.
          state(primary, "200")
          primary.succeed(probe)
          time.sleep(8)
          primary.fail(vip)
          backup.succeed(vip)

      with subtest("all APIs unready withdraws the endpoint, then recovery elects again"):
          for machine in (primary, backup):
              state(machine, "auth500")  # synthetic quorum-loss readiness result
              machine.wait_for_open_port(6443)
          withdrawn(primary)
          withdrawn(backup)
          stays_withdrawn()
          state(primary, "200")
          holds(primary)
          backup.fail(vip)
          primary.succeed("systemctl stop k3s.service")
          withdrawn(primary)
          primary.fail(probe)
    '';
  }
