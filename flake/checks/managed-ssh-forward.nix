{pkgs, ...}:
pkgs.testers.runNixOSTest {
  name = "managed-ssh-forward";
  nodes = {
    client = {pkgs, ...}: {
      imports = [../../modules/nixos/services/managed-ssh-forward];
      services.managed-ssh-forward = {
        enable = true;
        remoteHost = "server";
        remoteUser = "forwarder";
        hostPublicKey = "ssh-ed25519 AAAA_fixture";
        identityFile = "/var/lib/forward-test/key";
        localPort = 3781;
        targetPort = 3780;
      };
      # The test enrolls fresh VM-only public keys before starting the unit.
      systemd.services.managed-ssh-forward.wantedBy = pkgs.lib.mkForce [];
      environment.systemPackages = [pkgs.openssh pkgs.curl pkgs.python3 pkgs.ripgrep];
    };
    server = {pkgs, ...}: {
      imports = [../../modules/nixos/services/managed-ssh-forward];
      services.ssh-forward-target = {
        enable = true;
        user = "forwarder";
        targetPort = 3780;
        publicKeys = ["ssh-ed25519 AAAA_fixture"];
      };
      services.openssh.settings.PasswordAuthentication = false;
      virtualisation.memorySize = 4096;
      users.groups.test-t3 = {};
      users.users.test-t3 = {
        isSystemUser = true;
        group = "test-t3";
        home = "/var/lib/test-t3";
        createHome = true;
        homeMode = "0700";
      };
      systemd.services.endpoint = {
        wantedBy = ["multi-user.target"];
        environment = {
          HOME = "/var/lib/test-t3";
          T3CODE_AUTO_BOOTSTRAP_PROJECT_FROM_CWD = "false";
        };
        serviceConfig = {
          User = "test-t3";
          ExecStart = "${pkgs.t3code}/bin/t3 start --mode desktop --no-browser --host 127.0.0.1 --port 3780 --base-dir /var/lib/test-t3/.t3";
          StandardOutput = "null";
          StandardError = "null";
        };
      };
      systemd.services.other-endpoint = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 3782 --bind 127.0.0.1";
      };
    };
  };
  testScript = ''
    import json
    import shlex
    start_all()
    server.wait_for_unit("sshd.service")
    server.wait_for_open_port(3780)
    server.wait_for_open_port(3782)
    client.succeed('install -d -m 0700 /var/lib/forward-test; ssh-keygen -q -t ed25519 -N "" -f /var/lib/forward-test/key')
    public = client.succeed("cat /var/lib/forward-test/key.pub").strip()
    host = server.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
    key_file = "/etc/ssh/authorized_keys.d/forwarder"
    template = server.succeed("cat " + key_file).strip()
    enrolled = template.replace("ssh-ed25519 AAAA_fixture", public)
    server.succeed("unlink " + key_file + "; printf '%s\\n' " + shlex.quote(enrolled) + " > " + key_file)
    known = "/etc/managed-ssh-forward/known_hosts"
    client.succeed("unlink " + known + "; printf '%s\\n' " + shlex.quote("server " + host) + " > " + known)
    client.succeed("systemctl start managed-ssh-forward.service")
    client.wait_until_succeeds("curl --fail --connect-timeout 1 http://127.0.0.1:3781/ >/dev/null")
    # Exercise the actual T3 backend over SSH, not a mock authentication handler.
    session = json.loads(client.succeed("curl --fail --silent http://127.0.0.1:3781/api/auth/session"))
    assert session["authenticated"] is False
    for endpoint in ["/mcp", "/api/orchestration/shell", "/api/projects", "/ws?orchestrationProtocol=2"]:
        upgrade = " --http1.1 --header 'Connection: Upgrade' --header 'Upgrade: websocket' --header 'Sec-WebSocket-Version: 13' --header 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' " if endpoint.startswith("/ws?") else " "
        status = client.succeed("curl --max-time 5 --silent --output /dev/null --write-out '%{http_code}' --header 'x-t3-orchestration-protocol: 2' " + upgrade + shlex.quote("http://127.0.0.1:3781" + endpoint)).strip()
        assert status in ["401", "403"], (endpoint, status)
    pid = client.succeed("systemctl show managed-ssh-forward.service -p MainPID --value").strip()
    uid = client.succeed("awk '/^Uid:/ {print $2}' /proc/" + pid + "/status").strip()
    assert uid != "0", uid
    before = client.succeed("systemctl show managed-ssh-forward.service -p MainPID --value").strip()
    client.succeed("kill -KILL " + before)
    client.wait_until_succeeds("test $(systemctl show managed-ssh-forward.service -p MainPID --value) != " + before + " && curl --fail --connect-timeout 1 http://127.0.0.1:3781/ >/dev/null")
    ssh = "ssh -F /dev/null -i /var/lib/forward-test/key -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes -o UserKnownHostsFile=" + known + " -o ConnectTimeout=3 "
    client.fail(ssh + "-T forwarder@server 'touch /tmp/forward-shell-escaped'")
    server.succeed("test ! -e /tmp/forward-shell-escaped")
    # A generic nonzero result could be ForceCommand, so assert session-channel refusal.
    client.succeed("if " + ssh + "-tt forwarder@server true 2>/tmp/session-denial; then exit 1; fi; rg 'channel .*open failed:' /tmp/session-denial")
    client.fail(ssh + "-o ExitOnForwardFailure=yes -f -N -R 127.0.0.1:3790:127.0.0.1:3780 forwarder@server")
    client.succeed(ssh + "-o ExitOnForwardFailure=yes -f -N -L 127.0.0.1:3790:127.0.0.1:3782 forwarder@server")
    # A second real HTTP listener distinguishes forwarding denial from protocol mismatch.
    server.succeed("${pkgs.curl}/bin/curl --fail --silent http://127.0.0.1:3782/ >/dev/null")
    client.fail("curl --fail --max-time 2 http://127.0.0.1:3790/ >/dev/null")
    client.succeed("curl --fail --connect-timeout 2 http://127.0.0.1:3781/ >/dev/null")
  '';
}
