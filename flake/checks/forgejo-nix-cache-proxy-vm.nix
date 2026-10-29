# Qualifies the CI Nix cache proxy (ADR-0103) without network access: a local
# HTTPS binary cache, signed with a throwaway key and served with a test CA,
# stands in for cache.nixos.org. A Nix client in a job-like container, on a
# per-job network of the rootless Podman pool, substitutes through the cache
# with the runner's NIX_CONFIG and trusts only the upstream key. The cache
# keeps the upstream signatures, serves a second job without the upstream,
# refuses writes, other paths and other hosts, and a stopped cache only costs
# the job the detour.
{pkgs}:
if pkgs.stdenv.hostPlatform.system != "x86_64-linux"
then pkgs.runCommand "forgejo-nix-cache-proxy-unsupported-platform" {} ''touch "$out"''
else let
  busybox = pkgs.pkgsStatic.busybox;
  # Two store paths without references: one signed by the upstream key, one
  # by a key nobody trusts.
  signed = pkgs.writeText "ci-nix-cache-proxy-signed" "served through the proxy\n";
  rogue = pkgs.writeText "ci-nix-cache-proxy-rogue" "signed by an untrusted key\n";
  jobImage = pkgs.dockerTools.buildLayeredImage {
    name = "nix-cache-proxy-job";
    tag = "local";
    contents = [busybox pkgs.nix];
    extraCommands = ''
      mkdir -p -m 1777 tmp
      mkdir -p root etc
      # As in Debian job images, /etc/hosts (where Podman puts
      # host.containers.internal) is read before DNS.
      echo 'hosts: files dns' > etc/nsswitch.conf
    '';
    config.Env = [
      "PATH=/bin"
      "HOME=/root"
      "USER=root"
    ];
  };
  upstreamHost = "upstream.test";
  # A throwaway CA and server certificate, so the cache verifies its upstream
  # as it does cache.nixos.org.
  tls = pkgs.runCommand "nix-cache-proxy-test-tls" {nativeBuildInputs = [pkgs.openssl];} ''
    mkdir -p "$out"
    cd "$out"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 36500 \
      -subj /CN=fixture-ca -keyout ca.key -out ca.crt
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -subj /CN=${upstreamHost} -keyout server.key -out server.csr
    printf 'subjectAltName=DNS:${upstreamHost}\n' > ext
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
      -days 36500 -extfile ext -out server.crt
  '';
  # A plain HTTP copy of the upstream, the next substituter while the cache
  # is down.
  plainPort = 8080;
  proxyPort = 8501;
  registrationToken = pkgs.writeText "nix-cache-proxy-registration-token" "unused-fixture-token";
in
  pkgs.testers.runNixOSTest {
    name = "forgejo-nix-cache-proxy";
    nodes.runner = {lib, ...}: {
      imports = [../../modules/nixos/services/forgejo-actions-runner];
      options.sops.secrets = lib.mkOption {
        type = lib.types.attrs;
        default = {};
      };
      config = {
        system.stateVersion = "25.11";
        virtualisation = {
          memorySize = 3072;
          cores = 2;
          diskSize = 8192;
          docker.enable = true;
          additionalPaths = [signed rogue];
        };
        nix.settings.experimental-features = ["nix-command"];
        networking.hosts."127.0.0.1" = [upstreamHost];
        security.pki.certificateFiles = ["${tls}/ca.crt"];
        # The host's resolver, answering the upstream's name from /etc/hosts;
        # the cache's nginx resolves through it, not through /etc/hosts.
        services.dnsmasq.enable = true;
        # The LAN interface is trusted as k3s trusts its pod interfaces: the
        # cache's own rule must still refuse it.
        networking.firewall.trustedInterfaces = ["eth1"];
        services.forgejo-actions-runner = {
          enable = true;
          name = "nix-cache-proxy-fixture";
          labels = ["fixture:docker://example.invalid/unused:local"];
          secretsFile = pkgs.writeText "nix-cache-proxy-secrets" "fixture-only";
          isolatedDocker.enable = true;
          ioPressureGuard.admissionControl.enable = true;
          podmanCanary = {
            enable = true;
            registrationTokenFile = toString registrationToken;
            labels = ["podman-fixture:docker://example.invalid/unused:local"];
          };
          nixCacheProxy = {
            enable = true;
            upstreams = ["https://${upstreamHost}"];
          };
        };
        systemd.tmpfiles.rules = ["d /srv/upstream 0755 root root -"];
        services.nginx = {
          enable = true;
          virtualHosts.${upstreamHost} = {
            onlySSL = true;
            sslCertificate = "${tls}/server.crt";
            sslCertificateKey = "${tls}/server.key";
            root = "/srv/upstream";
          };
        };
        systemd.services =
          lib.genAttrs ["forgejo-actions-runner" "forgejo-podman-runner"] (_: {
            preStart = lib.mkForce "";
            script = lib.mkForce "while :; do sleep 1; done";
          })
          // {
            fixture-pressure-init = {
              serviceConfig.Type = "oneshot";
              script = ''
                printf 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > /run/fixture-pressure
              '';
            };
            forgejo-runner-io-pressure-guard = {
              requires = ["fixture-pressure-init.service"];
              after = ["fixture-pressure-init.service"];
              environment.PRESSURE_FILE = "/run/fixture-pressure";
            };
            plain-upstream = {
              wantedBy = ["multi-user.target"];
              serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server ${toString plainPort} --bind :: --directory /srv/upstream";
            };
          };
        environment.systemPackages = [pkgs.docker pkgs.curl pkgs.iproute2];
      };
    };
    nodes.lan = {
      environment.systemPackages = [pkgs.curl];
    };
    testScript = {nodes, ...}: let
      proxy = nodes.runner.services.forgejo-actions-runner.nixCacheProxy;
    in
      assert proxy.maxSize == "10G";
      assert !(nodes.runner.services ? ncps) || !nodes.runner.services.ncps.enable; ''
        import shlex

        podman = "docker -H unix:///run/forgejo-podman/podman.sock"
        nix = "nix --extra-experimental-features nix-command"
        cache = "http://127.0.0.1:${toString proxyPort}/${upstreamHost}"
        job_nix_config = """${proxy.jobNixConfig}"""
        assert "extra-substituters = http://host.containers.internal:${toString proxyPort}/${upstreamHost}?priority=10" in job_nix_config
        assert "fallback = true" in job_nix_config

        start_all()
        runner.wait_for_unit("multi-user.target")
        runner.wait_for_unit("nginx.service")
        runner.wait_for_unit("forgejo-nix-cache.service")
        runner.wait_for_unit("plain-upstream.service")
        runner.wait_until_succeeds("systemctl is-active --quiet forgejo-runner-podman.service", timeout=90)
        lan.wait_for_unit("multi-user.target")

        # The cache is bounded and shares fetches; nothing else serves it, and
        # its only listener is the cache port.
        conf = runner.succeed(
            "grep -o '/nix/store/[a-z0-9]*-forgejo-nix-cache.conf' /etc/systemd/system/forgejo-nix-cache.service | head -1"
        ).strip()
        for directive in ["max_size=10G", "use_temp_path=off", "proxy_cache_valid 404 1m;", "proxy_cache_lock on;", "proxy_ssl_verify on;"]:
            runner.succeed(f"grep -Fq {shlex.quote(directive)} {conf}")
        runner.fail("systemctl cat ncps.service")
        # nginx resolves upstreams through the host's resolvers, taken from
        # /etc/resolv.conf when it starts.
        resolver = runner.succeed("cat /run/forgejo-nix-cache/resolver.conf")
        assert resolver.startswith("resolver 127.0.0.1 "), resolver
        runner.succeed(f"grep -Fq 'set $nix_upstream ${upstreamHost};' {conf}")
        pids = runner.succeed("cat /sys/fs/cgroup/system.slice/forgejo-nix-cache.service/cgroup.procs").split()
        listeners = [
            line.split()[3]
            for line in runner.succeed("ss -Hltn -p").splitlines()
            if any(f"pid={pid}," in line for pid in pids)
        ]
        assert sorted(listeners) == ["0.0.0.0:${toString proxyPort}", "[::]:${toString proxyPort}"], listeners

        # A static upstream cache: the first path signed by the upstream key,
        # the second by a key no one trusts.
        runner.succeed(f"{nix} key generate-secret --key-name ${upstreamHost}-1 > /root/upstream.sec")
        runner.succeed(f"{nix} key convert-secret-to-public < /root/upstream.sec > /root/upstream.pub")
        runner.succeed(f"{nix} key generate-secret --key-name rogue.test-1 > /root/rogue.sec")
        upstream_key = runner.succeed("cat /root/upstream.pub").strip()
        runner.succeed(f"{nix} copy --to 'file:///srv/upstream?secret-key=/root/upstream.sec' ${signed}")
        runner.succeed(f"{nix} copy --to 'file:///srv/upstream?secret-key=/root/rogue.sec' ${rogue}")
        runner.succeed("chmod -R a+rX /srv/upstream")
        signed_hash = "${builtins.substring 11 32 (toString signed)}"
        rogue_hash = "${builtins.substring 11 32 (toString rogue)}"
        upstream_sig = runner.succeed(f"grep '^Sig: ' /srv/upstream/{signed_hash}.narinfo").strip()
        assert upstream_sig.startswith("Sig: ${upstreamHost}-1:"), upstream_sig
        runner.succeed("curl -fsS https://${upstreamHost}/nix-cache-info")

        # Jobs run on a per-job network of the rootless Podman pool, as the
        # runner creates one when its container network is empty.
        runner.succeed(f"{podman} load < ${jobImage}")
        runner.succeed(f"{podman} network create job-net")

        def job(nix_config, command):
            runner.succeed(f"cat > /tmp/job-nix-config <<'EOF'\n{nix_config}EOF")
            return runner.succeed(
                f"NIX_CONFIG=\"$(cat /tmp/job-nix-config)\" {podman} run --rm --network job-net -e NIX_CONFIG "
                f"nix-cache-proxy-job:local sh -c {shlex.quote(command)}"
            )

        # The job reads the narinfo through host.containers.internal, with the
        # upstream signature unchanged and no other.
        narinfo = job(job_nix_config, f"wget -qO- http://host.containers.internal:${toString proxyPort}/${upstreamHost}/{signed_hash}.narinfo")
        sigs = [line for line in narinfo.splitlines() if line.startswith("Sig: ")]
        assert sigs == [upstream_sig], narinfo

        # A Nix client trusting only the upstream key substitutes through the
        # cache alone, with the runner's NIX_CONFIG.
        only_cache = (
            "substituters =\n"
            f"trusted-public-keys = {upstream_key}\n"
            "sandbox = false\n"
            "build-users-group =\n"
            + job_nix_config
        )
        out = job(only_cache, "nix-store --realise ${signed} && cat ${signed}")
        assert "served through the proxy" in out, out
        runner.succeed("find /var/lib/forgejo-nix-cache -type f | grep -q .")

        # The job refuses a path no key it trusts signed.
        job(only_cache, "! nix-store --realise ${rogue}")

        # Only GET and HEAD of substituter paths reach the upstream; every
        # other method or path is answered by the cache itself.
        nar_url = runner.succeed(f"grep '^URL: ' /srv/upstream/{signed_hash}.narinfo").split()[1]
        runner.succeed(f"curl -fsS -I {cache}/{signed_hash}.narinfo")
        runner.succeed(f"curl -fsS -o /dev/null {cache}/{nar_url}")
        runner.succeed(f"cp /srv/upstream/{rogue_hash}.narinfo /tmp/rogue.narinfo")
        refused = [
            ("PUT", f"/${upstreamHost}/{rogue_hash}.narinfo", "403"),
            ("POST", f"/${upstreamHost}/{signed_hash}.narinfo", "403"),
            ("DELETE", f"/${upstreamHost}/{signed_hash}.narinfo", "403"),
            ("DELETE", f"/${upstreamHost}/{nar_url}", "403"),
            ("GET", f"/{signed_hash}.narinfo", "404"),
            ("GET", "/${upstreamHost}/", "404"),
            ("GET", "/${upstreamHost}/index.html", "404"),
            ("GET", f"/${upstreamHost}/../${upstreamHost}x/{signed_hash}.narinfo", "404"),
            ("POST", f"/pin/{signed_hash}.narinfo", "404"),
            ("PUT", f"/upload/{rogue_hash}.narinfo", "404"),
            ("GET", "/other.test/nix-cache-info", "404"),
        ]
        for method, path, expected in refused:
            code = runner.succeed(
                f"curl -s -o /dev/null -w '%{{http_code}}' --path-as-is -X {method} --data-binary @/tmp/rogue.narinfo "
                f"http://127.0.0.1:${toString proxyPort}{path}"
            ).strip()
            assert code == expected, f"{method} {path}: {code}"
        job(job_nix_config, f"! wget -qO- --post-data= http://host.containers.internal:${toString proxyPort}/${upstreamHost}/{signed_hash}.narinfo")

        # The cache starts without DNS and resolves the upstream once DNS is
        # back, without a restart.
        missing = f"{cache}/{'0' * 32}.narinfo"
        runner.succeed("systemctl stop dnsmasq.service")
        runner.succeed("systemctl restart forgejo-nix-cache.service")
        runner.succeed("systemctl is-active --quiet forgejo-nix-cache.service")
        runner.wait_for_open_port(${toString proxyPort})
        code =runner.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {missing}").strip()
        assert code == "502", code
        runner.succeed("systemctl start dnsmasq.service")
        runner.wait_until_succeeds(f"test \"$(curl -s -o /dev/null -w '%{{http_code}}' {missing})\" = 404", timeout=60)

        # A second job is served from the cache with the upstream gone.
        runner.succeed("systemctl stop nginx.service")
        runner.fail("curl -fsS https://${upstreamHost}/nix-cache-info")
        out = job(only_cache, "nix-store --realise ${signed} && cat ${signed}")
        assert "served through the proxy" in out, out

        # Other hosts are refused even on a trusted interface, where the plain
        # upstream's port stays open, and even when another chain accepts the
        # port in INPUT ahead of the NixOS firewall, as kube-router or NetBird
        # rules may.
        runner.succeed("iptables -w -I INPUT 1 -p tcp --dport ${toString proxyPort} -j ACCEPT")
        runner.succeed("ip6tables -w -I INPUT 1 -p tcp --dport ${toString proxyPort} -j ACCEPT")
        for family in ["-4", "-6"]:
            lan.succeed(f"curl {family} -fsS --max-time 5 http://runner:${toString plainPort}/nix-cache-info >/dev/null")
            lan.fail(f"curl {family} -fsS --max-time 5 http://runner:${toString proxyPort}/${upstreamHost}/nix-cache-info")

        # With the cache down, the job falls back to the next substituter.
        runner.succeed("systemctl stop forgejo-nix-cache.service")
        with_upstream = (
            "substituters = http://host.containers.internal:${toString plainPort}\n"
            f"trusted-public-keys = {upstream_key}\n"
            "sandbox = false\n"
            "build-users-group =\n"
            + job_nix_config
        )
        out = job(with_upstream, "nix-store --realise ${signed} && cat ${signed}")
        assert "served through the proxy" in out, out
      '';
  }
