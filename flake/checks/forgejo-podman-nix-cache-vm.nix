# The CI Nix store (ADR-0109, #1038): Podman pool jobs mount a persistent,
# read-only store as the overlay lower layer of /nix/store, with their own
# paths in the RAM scratch; a credential-free filler adds only signed paths
# and narHash-verified GitHub inputs, within a budget, and collects by age
# and size. Jobs see the store ID-mapped to their own root.
{pkgs}:
if pkgs.stdenv.hostPlatform.system != "x86_64-linux"
then pkgs.runCommand "forgejo-podman-nix-cache-unsupported-platform" {} ''touch "$out"''
else let
  # A static busybox as a plain file: the image has no /nix of its own, as
  # node:20-bookworm has none.
  fixtureImage = pkgs.dockerTools.buildLayeredImage {
    name = "nix-cache-fixture";
    tag = "local";
    extraCommands = "mkdir -p bin && cp ${pkgs.pkgsStatic.busybox}/bin/busybox bin/busybox";
    config.Cmd = ["/bin/busybox" "true"];
  };
  nixPkg = pkgs.nix;
  dep = pkgs.writeText "nix-cache-fixture-dep" "a dependency\n";
  payload = pkgs.writeText "nix-cache-fixture-payload" "signed, depends on ${dep}\n";
  jobPayload = pkgs.writeText "nix-cache-fixture-job-payload" "signed, fetched by a job, uses ${dep}\n";
  capPayload = pkgs.writeText "nix-cache-fixture-cap-payload" "signed, offered past the cap\n";
  deferPayload = pkgs.writeText "nix-cache-fixture-defer-payload" "signed, offered while a job runs\n";
  limitA = pkgs.writeText "nix-cache-fixture-limit-a" "signed, offered past the run limit\n";
  limitB = pkgs.writeText "nix-cache-fixture-limit-b" "signed, offered past the run limit too\n";
  # A directory path, which Nix must delete in a job (chmod, then unlink)
  # before it substitutes it again.
  dirPayload = pkgs.runCommand "nix-cache-fixture-dir" {} ''
    mkdir -p "$out/share/doc" "$out/bin"
    echo "a directory path" > "$out/share/doc/readme"
    echo tool > "$out/bin/tool"
  '';
  unsigned = pkgs.writeText "nix-cache-fixture-unsigned" "in the cache without a signature\n";
  otherKey = pkgs.writeText "nix-cache-fixture-other-key" "signed by an untrusted key\n";
  localOnly = pkgs.writeText "nix-cache-fixture-local-only" "built here, in no cache\n";
  quietPressure = pkgs.writeText "fixture-quiet-pressure" "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n";
  # GitHub's hosts, answered by a fixture on a TEST-NET-3 address on
  # loopback, with a certificate the system trusts.
  fixtureAddress = "203.0.113.10";
  fixtureCert = pkgs.runCommand "nix-cache-fixture-cert" {nativeBuildInputs = [pkgs.openssl];} ''
    mkdir -p "$out"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=fixture.example \
      -addext "subjectAltName=DNS:github.com,DNS:api.github.com,DNS:codeload.github.com,DNS:git.sr.ht,DNS:fixture.example" \
      -keyout "$out/key.pem" -out "$out/cert.pem" 2>/dev/null
  '';
  # Records every request's host, path and headers. A repository owned by
  # "private" demands credentials; any other request naming a commit gets
  # the archive stored for that commit.
  httpsFixture = pkgs.writeText "nix-cache-https-fixture.py" ''
    import http.server, json, os, re, ssl

    class Handler(http.server.BaseHTTPRequestHandler):
        def reply(self, code, body=b"", headers=()):
            self.send_response(code)
            for name, value in headers:
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            with open("/srv/http.log", "a") as log:
                log.write(json.dumps({"path": self.path, "headers": dict(self.headers)}) + "\n")
            if "/private/" in self.path:
                return self.reply(401, headers=[("WWW-Authenticate", 'Basic realm="fixture"')])
            commit = re.search("[0-9a-f]{40}", self.path)
            archive = commit and "/srv/http/archive/" + commit.group(0) + ".tar.gz"
            if not archive or not os.path.exists(archive):
                return self.reply(404)
            with open(archive, "rb") as f:
                self.reply(200, f.read(), [("Content-Type", "application/x-gzip")])

        def do_POST(self):
            self.do_GET()

    server = http.server.ThreadingHTTPServer(("0.0.0.0", 443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain("${fixtureCert}/cert.pem", "${fixtureCert}/key.pem")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()
  '';
  jobScript = pkgs.writeText "nix-cache-job.sh" ''
    /bin/busybox --install -s /bin
    export PATH=/bin HOME=/tmp USER=root
    set -eu
    mkdir -p /tmp /nix/var/nix/db
    # The workflow step: the database snapshot into the job's own state.
    cp /nix-cache/db/db.sqlite /nix-cache/db/schema /nix/var/nix/db/
    export NIX_CONFIG="build-users-group =
    sandbox = false
    substituters = file:///srv/nix-fixture
    trusted-public-keys = $(cat /srv/pk)
    experimental-features = nix-command"
    N=/nix-cache/nix/bin
    $N/nix path-info --all | sort > /tmp/before
    $N/nix-store --verify-path ${payload} ${dirPayload}
    echo LOWER-READ-OK
    $N/nix-store --realise ${jobPayload} >/dev/null
    grep -q 'fetched by a job' ${jobPayload}
    echo SUBSTITUTE-OK
    dd if=/dev/urandom of=/tmp/big bs=1M count=64 2>/dev/null
    $N/nix-store --add /tmp/big
    echo ADD-OK
    if touch /nix-cache/x 2>/dev/null; then echo JOB-DIR-WRITABLE; exit 1; fi
    # Bound through the API socket, the drop directory is still not writable.
    if touch /nix-cache-drop/x 2>/dev/null; then echo DROP-DIR-WRITABLE; exit 1; fi
    # A list of the paths this job added and what they use, which root places
    # in the drop directory below, as no job can.
    $N/nix path-info --all | sort | comm -13 /tmp/before - |
      xargs $N/nix-store -qR --include-outputs | sort -u > /joblist/job.paths
    echo READY
    while [ ! -e /srv/go ]; do sleep 1; done
  '';
  # A job whose database does not list a directory path the lower store
  # holds: a snapshot older than the store, or no snapshot at all, as after
  # installing Nix on top of the store. Nix replaces the path in its upper.
  unlistedScript = pkgs.writeText "nix-cache-unlisted.sh" ''
    /bin/busybox --install -s /bin
    export PATH=/bin HOME=/tmp USER=root
    set -eu
    mkdir -p /tmp /nix/var/nix/db
    if [ "$1" = stale ]; then cp /srv/empty-db/db.sqlite /srv/empty-db/schema /nix/var/nix/db/; fi
    export NIX_CONFIG="build-users-group =
    sandbox = false
    substituters = file:///srv/nix-fixture
    trusted-public-keys = $(cat /srv/pk)
    experimental-features = nix-command"
    N=/nix-cache/nix/bin
    test -f ${dirPayload}/share/doc/readme
    if $N/nix-store --check-validity ${dirPayload} 2>/dev/null; then echo LISTED; exit 1; fi
    $N/nix-store --realise ${dirPayload} ${payload} >/dev/null
    test "$(cat ${dirPayload}/share/doc/readme)" = "a directory path"
    ls -ln ${dirPayload}
    echo REALISED
  '';
  fallbackScript = "/bin/busybox sh -c 'test -x /nix-cache/nix/bin/nix || echo FALLBACK; test -d /nix/store && echo STORE-DIR; test -s /nix-cache/db/db.sqlite && echo SNAPSHOT; test -d /nix-cache-drop && echo DROP-DIR'";
in
  pkgs.testers.runNixOSTest {
    name = "forgejo-podman-nix-cache";
    nodes.machine = {lib, ...}: {
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
          additionalPaths = [nixPkg payload jobPayload capPayload deferPayload limitA limitB dirPayload unsigned otherKey localOnly];
        };
        nix.settings = {
          experimental-features = ["nix-command"];
          # Credentials the host's own Nix and Git would send to the fixture
          # server; the filler must never use them.
          netrc-file = "/etc/nix/netrc";
        };
        environment.etc."nix/netrc".text = "machine github.com login fixture password planted-secret\nmachine api.github.com login fixture password planted-secret\n";
        environment.etc."gitconfig".text = "[credential]\n\thelper = store --file /etc/git-credentials\n";
        environment.etc."git-credentials".text = "https://fixture:planted-secret@github.com\n";
        systemd.tmpfiles.rules = ["f /root/.netrc 0600 root root - machine github.com login fixture password planted-secret"];
        security.pki.certificateFiles = ["${fixtureCert}/cert.pem"];
        networking.hosts.${fixtureAddress} = ["github.com" "api.github.com" "codeload.github.com" "git.sr.ht" "fixture.example"];
        systemd.services.fixture-https = {
          wantedBy = ["multi-user.target"];
          path = [pkgs.iproute2];
          preStart = "ip addr replace ${fixtureAddress}/32 dev lo";
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${httpsFixture}";
        };
        services.forgejo-actions-runner = {
          enable = true;
          name = "nix-cache-fixture";
          labels = ["fixture:docker://example.invalid/unused:local"];
          secretsFile = pkgs.writeText "fixture-secrets" "unused";
          isolatedDocker.enable = true;
          podmanStoreReset.enable = true;
          podmanCanary = {
            enable = true;
            registrationTokenFile = toString (pkgs.writeText "fixture-registration-token" "unused");
            labels = ["podman-fixture:docker://example.invalid/unused:local"];
            scratch = {
              enable = true;
              size = "512M";
            };
            nixCache = {
              enable = true;
              package = nixPkg;
              substituters = ["file:///srv/nix-fixture"];
              # Replaced by the key the test generates (a runtime drop-in).
              trustedPublicKeys = ["fixture-placeholder:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="];
              # The VM disk is small and mostly free; the test sets its own
              # caps through drop-ins.
              minFreePercent = 5;
            };
          };
        };
        systemd.timers.forgejo-nix-cache-fill.wantedBy = lib.mkForce [];
        systemd.timers.forgejo-podman-store-reset.wantedBy = lib.mkForce [];
        systemd.services.forgejo-podman-store-reset = {
          unitConfig.StartLimitIntervalSec = 0;
          environment.PRESSURE_FILE = toString quietPressure;
        };
        systemd.services.forgejo-nix-cache-fill.unitConfig.StartLimitIntervalSec = 0;
        systemd.sockets.forgejo-runner-podman.unitConfig.StartLimitIntervalSec = 0;
        systemd.services.forgejo-runner-docker.unitConfig.StartLimitIntervalSec = 0;
        systemd.services.forgejo-runner-podman.unitConfig.StartLimitIntervalSec = 0;
        systemd.services.forgejo-actions-runner = {
          unitConfig.StartLimitIntervalSec = 0;
          preStart = lib.mkForce "";
          script = lib.mkForce "exec sleep infinity";
        };
        systemd.services.forgejo-podman-runner = {
          unitConfig.StartLimitIntervalSec = 0;
          preStart = lib.mkForce "";
          script = lib.mkForce "exec sleep infinity";
        };
        environment.systemPackages = [pkgs.docker pkgs.sqlite pkgs.jq];
      };
    };
    testScript = {nodes, ...}: let
      canary = nodes.machine.services.forgejo-actions-runner.podmanCanary;
    in ''
      import json
      import re

      data = "${canary.nixCache.dataPath}"
      exposed = "${canary.nixCache.path}"
      drop = "${canary.nixCache.dropPath}"
      scratch = "${canary.scratch.path}"
      runs = f"{data}/nix/var/nix/gcroots/forgejo-nix-cache"
      fill = "forgejo-nix-cache-fill.service"
      prepare = "forgejo-nix-cache-prepare.service"
      api = "forgejo-runner-podman.service"
      podman = "docker -H unix:///run/forgejo-podman/podman.sock"
      fixture = "file:///srv/nix-fixture"
      dropin = "/run/systemd/system/forgejo-nix-cache-fill.service.d"
      binds = f"-v {exposed}/nix/store:/nix/store:O -v {exposed}/job:/nix-cache:ro -v {drop}:/nix-cache-drop"
      snap = f"find {data} -path {data}/job -prune -o -printf '%p %s %T@ %m %U\\n' | sort | sha256sum"

      def run_fill():
          cursor = machine.succeed("journalctl -q -n 0 --show-cursor | sed -n 's/^-- cursor: //p'").strip()
          machine.succeed(f"systemctl start {fill}", timeout=600)
          machine.succeed("journalctl --sync")
          return machine.succeed(f"journalctl -q --after-cursor='{cursor}' -u {fill} -o cat")

      def in_cache(path):
          return machine.execute(f"test -e {data}{path}")[0] == 0

      def in_snapshot(path):
          out = machine.succeed(f"sqlite3 {exposed}/job/db/db.sqlite \"select count(*) from ValidPaths where path = '{path}'\"")
          return out.strip() == "1"

      def container(name, opts, command, wait=True):
          machine.succeed(f"{podman} create --network none --name {name} {opts} nix-cache-fixture:local {command}")
          machine.succeed(f"{podman} start {name}")
          if not wait:
              return None, None
          code = machine.succeed(f"timeout 300 {podman} wait {name}").strip()
          machine.succeed("journalctl --sync")
          out = machine.succeed(f"journalctl -o cat -t {name}")
          machine.succeed(f"{podman} rm {name}")
          return int(code), out

      start_all()
      machine.wait_for_unit("multi-user.target")
      for unit in [prepare, api, "forgejo-podman-runner.service", "fixture-https.service"]:
          machine.wait_for_unit(unit)
      machine.wait_until_succeeds("ss -ltn | grep -q ':443 '")
      machine.succeed(f"{podman} load < ${fixtureImage}")

      with subtest("a fresh cache is exposed read-only, ID-mapped, with its bind sources before any fill"):
          machine.succeed(f"test \"$(stat -c %U:%a {data})\" = forgejo-nix-cache:755")
          machine.succeed(f"findmnt -rn --mountpoint {exposed} -o OPTIONS | tr , '\\n' | grep -qx ro")
          # Exactly the validated directory, its files shown as the API user's.
          machine.succeed(f"test \"$(stat -c %d:%i {exposed})\" = \"$(stat -c %d:%i {data})\"")
          machine.succeed(f"test \"$(stat -c %U:%G {exposed} {exposed}/job/db.0/db.sqlite | sort -u)\" = forgejo-podman-builder:forgejo-podman")
          machine.succeed(f"test \"$(stat -c %U {data}/job/db.0/db.sqlite)\" = forgejo-nix-cache")
          machine.succeed(f"test \"$(stat -c %U:%a {drop})\" = forgejo-nix-cache:700")
          machine.fail(f"touch {exposed}/x")
          machine.succeed(f"test -d {exposed}/nix/store && test -s {exposed}/job/db/db.sqlite && ! test -e {exposed}/job/nix")
          # Mounts are assembled out of reach, in a private root-only tmpfs.
          machine.succeed("test \"$(stat -c %U:%a /run/forgejo-nix-cache-stage)\" = root:700")
          machine.succeed("findmnt -rn -o PROPAGATION --mountpoint /run/forgejo-nix-cache-stage | grep -qx private")
          assert machine.succeed(f"sqlite3 {exposed}/job/db/db.sqlite 'select count(*) from ValidPaths'").strip() == "0"
          code, out = container("fresh", binds, "${fallbackScript}")
          assert code == 0 and all(m in out for m in ["FALLBACK", "STORE-DIR", "SNAPSHOT", "DROP-DIR"]), out
          # Kept for a job with a snapshot older than the store.
          machine.succeed(f"mkdir -p /srv/empty-db && cp -L {exposed}/job/db/db.sqlite {exposed}/job/db/schema /srv/empty-db/")

      with subtest("fixtures: a signed cache and pinned flake inputs, public, private and refused"):
          machine.succeed("nix-store --generate-binary-cache-key fixture-1 /root/sk /srv-pk && mkdir -p /srv/http && mv /srv-pk /srv/pk")
          machine.succeed("nix-store --generate-binary-cache-key other-1 /root/other-sk /root/other-pk")
          machine.succeed(f"nix copy --to {fixture} ${nixPkg} ${payload} ${jobPayload} ${capPayload} ${deferPayload} ${limitA} ${limitB} ${dirPayload} ${unsigned} ${otherKey}")
          machine.succeed(f"nix store sign --store {fixture} -k /root/sk -r ${nixPkg} ${payload} ${jobPayload} ${capPayload} ${deferPayload} ${limitA} ${limitB} ${dirPayload}")
          machine.succeed(f"nix store sign --store {fixture} -k /root/other-sk ${otherKey}")
          machine.succeed("cp ${jobScript} /srv/job.sh && cp ${unlistedScript} /srv/unlisted.sh && chmod -R a+rX /srv")
          pk = machine.succeed("cat /srv/pk").strip()
          machine.succeed(f"mkdir -p {dropin} && printf '[Service]\\nEnvironment=\"NIX_CONFIG=trusted-public-keys = {pk}\"\\n' > {dropin}/key.conf && systemctl daemon-reload")
          public_rev, wrong_rev, private_rev = "1" * 40, "2" * 40, "3" * 40
          machine.succeed("mkdir -p /srv/http/archive /tmp/pub/source /tmp/wrong/source")
          machine.succeed(f"echo public > /tmp/pub/source/hello.txt && tar czf /srv/http/archive/{public_rev}.tar.gz -C /tmp/pub source")
          machine.succeed(f"echo tampered > /tmp/wrong/source/hello.txt && tar czf /srv/http/archive/{wrong_rev}.tar.gz -C /tmp/wrong source")
          nar_hash = machine.succeed("nix hash path /tmp/pub/source").strip()
          public_source = machine.succeed("nix-store --add-fixed --recursive sha256 /tmp/pub/source").strip()
          wrong_source = machine.succeed("nix-store --add-fixed --recursive sha256 /tmp/wrong/source").strip()
          # The pin of content that is never served.
          machine.succeed("mkdir -p /tmp/expected/source && echo expected > /tmp/expected/source/hello.txt")
          expected_hash = machine.succeed("nix hash path /tmp/expected/source").strip()
          fake = "sha256-" + "A" * 43 + "="
          github = lambda owner, rev, h=fake, **extra: {"locked": {"type": "github", "owner": owner, "repo": "repo", "rev": rev, "narHash": h, **extra}}
          public_lock = {"version": 7, "root": "root", "nodes": {"root": {"inputs": {}}, "public": github("o", public_rev, nar_hash, lastModified=1)}}
          lock = {"version": 7, "root": "root", "nodes": {
              "root": {"inputs": {}},
              "public": github("o", public_rev, nar_hash, lastModified=1),
              # Served with 200 OK, but its content does not match the pin.
              "wrong": github("o", wrong_rev, expected_hash),
              "private": github("private", private_rev),
              # Refused before any request: other types, a host override,
              # submodules, a branch instead of a commit.
              "tarball": {"locked": {"type": "tarball", "url": "https://fixture.example/x.tar.gz", "narHash": nar_hash}},
              "git": {"locked": {"type": "git", "url": "https://fixture.example/x.git", "rev": public_rev, "narHash": nar_hash}},
              "file": {"locked": {"type": "file", "url": "https://fixture.example/x.tar.gz", "narHash": nar_hash}},
              "path": {"locked": {"type": "path", "path": "/etc", "narHash": fake}},
              "ssh": {"locked": {"type": "git", "url": "ssh://git@fixture.example/x.git", "rev": public_rev, "narHash": fake}},
              "githubhost": github("o", "4" * 40, nar_hash, host="fixture.example"),
              "gitlabhost": {"locked": {"type": "gitlab", "owner": "o", "repo": "repo", "rev": public_rev, "host": "fixture.example", "narHash": nar_hash}},
              "submodules": github("o", "5" * 40, nar_hash, submodules=True),
              "branch": github("o", "main", nar_hash),
              "tildegithub": github("~o", "7" * 40, nar_hash),
              # SourceHut owners start with a tilde; this one has no archive.
              "sourcehut": {"locked": {"type": "sourcehut", "owner": "~o", "repo": "repo", "rev": "6" * 40, "narHash": expected_hash}},
          }}
          machine.succeed(f"cat > {drop}/repo-1.lock <<'EOF'\n{json.dumps(lock)}\nEOF")
          bad_name = "/nix/store/" + "a" * 32 + "-.hidden"
          paths = ["${payload}", "${dirPayload}", "${unsigned}", "${otherKey}", "${localOnly}", "${payload.drvPath}", bad_name, "not a path", "/etc/passwd"]
          machine.succeed(f"printf '%s\\n' {' '.join(repr(p) for p in paths)} > {drop}/repo-1.paths")
          machine.succeed(f"ln -s /etc/shadow {drop}/evil.paths")
          # Entries the filler cannot remove itself; root clears them after
          # the fill.
          machine.succeed(f"touch {drop}/.junk && mkdir -p {drop}/subdir && touch {drop}/subdir/file")
          # Lists still being written, under names the filler ignores.
          machine.succeed(f"echo ${jobPayload} > {drop}/.half.paths && echo ${jobPayload} > {drop}/half.paths.tmp")

      with subtest("the filler adds signed paths and verified GitHub inputs only"):
          journal = run_fill()
          print(journal)
          assert "fill lists=1 locks=1 requested=5 renewed=0 substituted=2 skipped=3 inputs=1 inputs_present=0 inputs_failed=3 inputs_refused=10" in journal, journal
          # Rejected inputs leave nothing in the staging tmpfs.
          staged = [int(v) for v in re.findall(r"staging_left=(\d+)", journal)]
          assert staged and all(v < 65536 for v in staged), journal
          assert in_cache("${payload}") and in_cache("${dep}") and in_cache("${dirPayload}") and in_cache("${nixPkg}")
          for path in ["${unsigned}", "${otherKey}", "${localOnly}", "${payload.drvPath}"]:
              assert not in_cache(path), path
          assert in_cache(public_source), public_source
          # Fetched with 200 OK but not matching its pin: neither stored nor
          # published.
          assert not in_cache(wrong_source) and not in_snapshot(wrong_source), wrong_source
          # The first fill keeps entries it cannot read; the next fill sweeps
          # what has lain there since before the previous fill started.
          assert machine.succeed(f"ls -A {drop}").strip() != ""
          run_fill()
          assert machine.succeed(f"ls -A {drop}").strip() == ""
          assert in_snapshot("${payload}") and in_snapshot(public_source) and not in_snapshot("${unsigned}")
          assert machine.succeed(f"readlink {exposed}/job/nix").strip() == "${nixPkg}"
          print(machine.succeed(f"du -sh {data}/nix/store {exposed}/job/db/db.sqlite"))

      with subtest("the filler sends no credentials and contacts only GitHub"):
          requests = [json.loads(line) for line in machine.succeed("cat /srv/http.log").splitlines()]
          print(requests)
          seen = " ".join(r["path"] for r in requests)
          for rev in [public_rev, wrong_rev]:
              assert rev in seen, seen
          assert "/private/" in seen, seen
          hosts = {r["headers"].get("Host", "") for r in requests}
          assert hosts <= {"github.com", "api.github.com", "codeload.github.com", "git.sr.ht"}, hosts
          assert "/~o/repo/" in seen, seen
          for r in requests:
              assert not any(k.lower() in ("authorization", "proxy-authorization", "cookie") for k in r["headers"]), r

      with subtest("an input already in the store is rooted again without fetching"):
          fetched = machine.succeed("grep -c . /srv/http.log").strip()
          machine.succeed(f"cat > {drop}/repo-2.lock <<'EOF'\n{json.dumps(public_lock)}\nEOF")
          journal = run_fill()
          assert "inputs=0 inputs_present=1 inputs_failed=0 inputs_refused=0" in journal, journal
          assert machine.succeed("grep -c . /srv/http.log").strip() == fetched

      with subtest("a job whose database does not list a lower directory path replaces it in its upper"):
          before = machine.succeed(snap)
          for mode in ["stale", "fresh"]:
              code, out = container(f"unlisted-{mode}", f"{binds} -v /srv:/srv:ro", f"/bin/busybox sh /srv/unlisted.sh {mode}")
              assert code == 0 and "REALISED" in out, out
          assert machine.succeed(snap) == before, "a job changed the lower store"

      with subtest("a job reads the lower store and writes only to its RAM scratch"):
          before = machine.succeed(snap)
          machine.succeed("install -d -o forgejo-podman-builder /tmp/joblist")
          container("job", f"{binds} -v /srv:/srv:ro -v /tmp/joblist:/joblist", "/bin/busybox sh /srv/job.sh", wait=False)
          machine.wait_until_succeeds("journalctl --sync && journalctl -o cat -t job | grep -q READY", timeout=300)
          out = machine.succeed("journalctl -o cat -t job")
          for marker in ["LOWER-READ-OK", "SUBSTITUTE-OK", "ADD-OK"]:
              assert marker in out, out
          # The job's new paths, a 64M file among them, are in the tmpfs.
          machine.succeed(f"find {scratch} -name '*-big' | grep -q .")
          machine.succeed(f"find {scratch} -name '*-nix-cache-fixture-job-payload' | grep -q .")
          machine.fail(f"find {data} -name '*-big' | grep -q .")
          machine.fail(f"test -e {data}${jobPayload}")
          machine.succeed("touch /srv/go")
          assert machine.succeed(f"timeout 120 {podman} wait job").strip() == "0"
          assert machine.succeed(snap) == before, "a job changed the lower store"
          machine.succeed(f"{podman} rm job && rm /srv/go")
          machine.succeed(f"cp /tmp/joblist/job.paths {drop}/job.paths")
          listed = machine.succeed(f"cat {drop}/job.paths").split()
          # Its new paths and the lower path they use.
          assert "${jobPayload}" in listed and "${dep}" in listed, listed

      with subtest("a job cannot write the store through any bind of it"):
          for name, opts in [("bind-root", f"-v {exposed}:/c"), ("bind-store", f"-v {exposed}/nix/store:/c")]:
              code, out = container(name, opts, "/bin/busybox touch /c/x")
              assert code != 0 and "Read-only file system" in out, out
          assert machine.succeed(snap) == before

      with subtest("the job's list renews what it used and adds its signed path, never its local one"):
          journal = run_fill()
          assert "renewed=1 substituted=1 skipped=1" in journal, journal
          assert in_cache("${jobPayload}") and in_snapshot("${jobPayload}")
          machine.fail(f"find {data}/nix/store -maxdepth 1 -name '*-big' | grep -q .")

      with subtest("while a job runs the filler only renews; deferred paths are added once it ends"):
          machine.succeed(f"printf '%s\\n' ${deferPayload} ${dep} > {drop}/busy.paths")
          container("FORGEJO-ACTIONS-TASK-fixture", "", "/bin/busybox sleep 600", wait=False)
          journal = run_fill()
          assert "ingest_deferred reason=job_running" in journal and "renewed=1 substituted=0" in journal, journal
          assert "gc_deferred reason=job_running" in journal and "gc collected=0" in journal, journal
          assert "pending_paths=1 " in journal, journal
          assert not in_cache("${deferPayload}")
          # The list is gone from the drop directory; the queue keeps the path,
          # out of the jobs' reach.
          assert machine.succeed(f"ls -A {drop}").strip() == ""
          machine.succeed("grep -qx '${deferPayload}' /var/lib/forgejo-nix-cache-fill/pending.paths")
          machine.succeed("test \"$(stat -c %U:%a /var/lib/forgejo-nix-cache-fill)\" = forgejo-nix-cache:700")
          machine.succeed(f"{podman} rm -f FORGEJO-ACTIONS-TASK-fixture")
          journal = run_fill()
          assert "requested=1 renewed=0 substituted=1" in journal and "pending_paths=0 " in journal, journal
          assert in_cache("${deferPayload}") and in_snapshot("${deferPayload}")

      with subtest("a fill stops adding past its run limit; the rest waits for the next"):
          machine.succeed(f"printf '[Service]\\nEnvironment=RUN_LIMIT_BYTES=1\\n' > {dropin}/limit.conf && systemctl daemon-reload")
          machine.succeed(f"printf '%s\\n' ${limitA} ${limitB} > {drop}/limit.paths")
          journal = run_fill()
          assert "ingest_stopped reason=run_limit" in journal and "substituted=1" in journal and "pending_paths=1 " in journal, journal
          assert in_cache("${limitA}") != in_cache("${limitB}")
          machine.succeed(f"rm {dropin}/limit.conf && systemctl daemon-reload")
          journal = run_fill()
          assert "substituted=1" in journal and "pending_paths=0 " in journal, journal
          assert in_cache("${limitA}") and in_cache("${limitB}")

      with subtest("past the size cap ingestion stops"):
          used = int(machine.succeed(f"sqlite3 {data}/nix/var/nix/db/db.sqlite 'select sum(narSize) from ValidPaths'").strip())
          machine.succeed(f"printf '[Service]\\nEnvironment=SIZE_CAP_BYTES={used}\\n' > {dropin}/cap.conf && systemctl daemon-reload")
          machine.succeed(f"echo ${capPayload} > {drop}/cap.paths")
          journal = run_fill()
          assert "ingest_stopped reason=cap" in journal and "pending_paths=1 " in journal, journal
          assert not in_cache("${capPayload}")
          machine.succeed(f"rm {dropin}/cap.conf && systemctl daemon-reload")

      with subtest("roots expire by age; paths a later list renewed stay"):
          stamps = sorted(int(s) for s in machine.succeed(f"ls {runs}").split())
          # Every run's roots but those of the run that took the job's list.
          job_path = "${jobPayload}".split("/")[-1]
          old = [st for st in stamps if machine.execute(f"test -L {runs}/{st}/{job_path}")[0] != 0]
          assert len(old) >= 1 and len(old) < len(stamps), stamps
          for stamp in old:
              machine.succeed(f"mv {runs}/{stamp} {runs}/{stamp - 20 * 86400}")
          journal = run_fill()
          assert f"gc collected=1 expired={len(old)} dropped=0" in journal, journal
          # The path the cap held back is added once the cap allows it.
          assert in_cache("${capPayload}") and "pending_paths=0 " in journal, journal
          assert not in_cache("${payload}") and not in_cache(public_source) and not in_cache("${dirPayload}")
          assert in_cache("${dep}") and in_cache("${jobPayload}") and in_cache("${nixPkg}")
          assert not in_snapshot("${payload}") and in_snapshot("${jobPayload}")

      with subtest("the size cap drops the oldest roots but not those renewed within a day; the jobs' Nix stays"):
          machine.succeed(f"printf '[Service]\\nEnvironment=SIZE_CAP_BYTES=1\\n' > {dropin}/cap.conf && systemctl daemon-reload")
          journal = run_fill()
          assert "cap_held" in journal and "dropped=0" in journal, journal
          assert in_cache("${jobPayload}")
          # Two days old, within the age limit but no longer recent.
          for stamp in machine.succeed(f"ls {runs}").split():
              machine.succeed(f"mv {runs}/{stamp} {runs}/{int(stamp) - 2 * 86400}")
          journal = run_fill()
          assert "cap_unreachable" in journal and re.search(r"dropped=[1-9]", journal), journal
          assert not in_cache("${jobPayload}") and in_cache("${nixPkg}")
          machine.succeed(f"rm {dropin}/cap.conf && systemctl daemon-reload")

      with subtest("a store reset leaves the cache and its mount alone"):
          before = machine.succeed(snap)
          # The first check only starts the age clock.
          machine.succeed("systemctl start forgejo-podman-store-reset.service", timeout=600)
          machine.succeed("touch -d '-8 days' /var/lib/forgejo-podman-store-reset/reset-at")
          machine.succeed("systemctl start forgejo-podman-store-reset.service", timeout=600)
          journal = machine.succeed("journalctl -u forgejo-podman-store-reset.service -o cat")
          assert "reset due=store_age" in journal, journal
          machine.wait_for_unit(api)
          assert machine.succeed(snap) == before
          machine.succeed(f"findmnt -rn --mountpoint {exposed} -o OPTIONS | tr , '\\n' | grep -qx ro")
          machine.succeed(f"{podman} load < ${fixtureImage}")
          code, out = container("after-reset", f"-v {exposed}/nix/store:/nix/store:O", "/bin/busybox ls ${nixPkg}/bin")
          assert code == 0 and "nix-store" in out, out

      with subtest("a cache someone else owns is refused, with an empty placeholder; a retry restores both mounts"):
          # Stopped, as when the cache is disabled, it leaves a read-only
          # placeholder that jobs still start on.
          machine.succeed(f"systemctl stop {prepare}")
          machine.succeed(f"test \"$(findmnt -rn --mountpoint {exposed} -o FSTYPE)\" = tmpfs")
          machine.succeed(f"findmnt -rn --mountpoint {exposed} -o OPTIONS | tr , '\\n' | grep -qx ro")
          code, out = container("stopped", binds, "${fallbackScript}")
          assert code == 0 and "FALLBACK" in out and "STORE-DIR" in out and "SNAPSHOT" not in out, out
          machine.succeed(f"chown forgejo-podman-builder {data}")
          machine.fail(f"systemctl start {prepare}")
          assert "nix_cache_refused reason=owner" in machine.succeed(f"journalctl -u {prepare} -o cat")
          machine.succeed(f"test \"$(findmnt -rn --mountpoint {exposed} -o FSTYPE)\" = tmpfs")
          machine.succeed(f"findmnt -rn --mountpoint {exposed} -o OPTIONS | tr , '\\n' | grep -qx ro")
          machine.succeed(f"mountpoint -q {drop}")
          code, out = container("refused", binds, "${fallbackScript}")
          assert code == 0 and "FALLBACK" in out and "STORE-DIR" in out and "SNAPSHOT" not in out, out
          # Fixed, the next start replaces the placeholder with the cache.
          machine.succeed(f"chown forgejo-nix-cache {data} && systemctl reset-failed {prepare} && systemctl start {prepare}")
          machine.succeed(f"test \"$(stat -c %d:%i {exposed})\" = \"$(stat -c %d:%i {data})\"")
          machine.succeed(f"test \"$(stat -c %U:%a {drop})\" = forgejo-nix-cache:700")
          # A second start keeps both as they are.
          machine.succeed(f"systemctl restart {prepare}")
          machine.succeed(f"test \"$(stat -c %U:%a {drop})\" = forgejo-nix-cache:700")
          machine.succeed(f"test \"$(stat -c %U {exposed})\" = forgejo-podman-builder")
    '';
  }
