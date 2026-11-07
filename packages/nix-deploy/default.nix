{
  lib,
  coreutils,
  dnsutils,
  gawk,
  git,
  gnugrep,
  gnused,
  jq,
  nixDeploy,
  symlinkJoin,
  writeShellApplication,
  writeShellScript,
  writeShellScriptBin,
  writeText,
}: let
  inventory = import ../../inventory.nix;

  hostNames = builtins.attrNames inventory.hosts;
  nixosHostNames = lib.filter (host: inventory.hosts.${host}.platform == "nixos") hostNames;
  homeManagerHostNames = lib.filter (host: inventory.hosts.${host}.homeManager or true) hostNames;
  deployableInAll = host: inventory.hosts.${host}.deployAll or true;
  # Embedded-etcd members switch one at a time behind a readiness gate so a
  # fleet deploy cannot disrupt more than one quorum member at once (#511).
  k3sServerHostNames =
    lib.filter (
      host: let
        role = inventory.hosts.${host}.k8sRole or null;
      in
        role != null && inventory.k8sRoles.${role}.role == "server"
    )
    nixosHostNames;
  # nixfleet reboot sends every Kubernetes node, servers and agents alike,
  # through its node power gates; the node name is the host name.
  kubernetesNodeHostNames = lib.filter (host: (inventory.hosts.${host}.k8sRole or null) != null) nixosHostNames;
  # The kubeconfig context of their cluster: nixfleet's cluster reads and
  # node steps use it, as does the serial ready gate below, so a switched
  # kubectx cannot point them at another cluster.
  kubernetesContext = "funhouse";
  # The PriorityClass the cluster gives its core services (edge, identity,
  # forge). nixfleet reboot reboots the nodes holding fewer of their
  # single-Pod workloads first, so each moves as few times as it can.
  kubernetesCorePriorityClass = "core-infra";

  # Someone may be using these hosts, so nixfleet runs their reboot guard
  # (modules/nixos/services/nixfleet-reboot-guard) before rebooting them.
  interactiveHostNames = lib.filter (host: inventory.roles.${inventory.hosts.${host}.role}.interactive or false) nixosHostNames;

  # The network's DNS servers must never be down together, so they form their
  # own serial group, gated by DNS answers rather than the cluster check.
  dnsServerHostNames = lib.filter (host: inventory.hosts.${host} ? dnsAddress) nixosHostNames;
  # A server is ready when Pi-hole answers pi.hole itself with an address and
  # gets an authoritative answer for a random name under a public domain,
  # which no cache can hold, so its upstream resolver must answer fresh. dig
  # reports failures on stdout too, so its status and the answer are both
  # checked. Without upstream connectivity the gate fails, which keeps the
  # second server up.
  dnsReady = writeShellScript "deploy-dns-ready" ''
    set -o pipefail
    case "$1" in
    ${lib.concatMapStringsSep "\n" (host: "  ${host}) server=${inventory.hosts.${host}.dnsAddress} ;;") dnsServerHostNames}
      *) echo "deploy-dns-ready: unknown DNS server $1" >&2; exit 2 ;;
    esac
    local_answer=$(${dnsutils}/bin/dig +time=2 +tries=1 +short "@$server" pi.hole) || exit 1
    ${gnugrep}/bin/grep -Eqx '[0-9.]+|[0-9a-fA-F:]+' <<<"$local_answer" || exit 1
    probe="deploy-ready-$RANDOM$RANDOM.nixos.org"
    upstream=$(${dnsutils}/bin/dig +time=3 +tries=1 "@$server" "$probe" A) || exit 1
    ${gnugrep}/bin/grep -Eq 'status: (NOERROR|NXDOMAIN)' <<<"$upstream"
  '';

  deployAllHostNames =
    lib.optional (builtins.elem "xyz" nixosHostNames && deployableInAll "xyz") "xyz"
    ++ lib.filter (host: host != "xyz" && deployableInAll host) nixosHostNames;

  aliases = builtins.listToAttrs (lib.concatMap (
      host:
        map (alias: {
          name = alias;
          value = host;
        }) (inventory.hosts.${host}.aliases or [])
    )
    hostNames);

  sshHosts = builtins.listToAttrs (lib.filter (entry: entry.value != entry.name) (
    map (host: {
      name = host;
      value = inventory.hosts.${host}.sshHostname or host;
    })
    hostNames
  ));

  systemSshUsers = builtins.listToAttrs (lib.filter (entry: entry.value != "root") (
    map (host: {
      name = host;
      value = inventory.hosts.${host}.systemSshUser or "root";
    })
    nixosHostNames
  ));

  systemActivationModes = builtins.listToAttrs (lib.filter (entry: entry.value != "switch") (
    map (host: {
      name = host;
      value = inventory.hosts.${host}.systemActivationMode or "switch";
    })
    nixosHostNames
  ));

  # nixfleet triage starts this agent in the flake checkout, with the prompt
  # as its last argument (nix-packages#783). Where T3 Code runs and knows the
  # checkout as a project, the session goes to a new T3 thread, so it stays
  # visible and resumable, and the command exits once the thread has started.
  # Otherwise, or with NIXFLEET_TRIAGE_TERMINAL=1, Claude runs in this
  # terminal. The deep agent role is resolved at run time, so no model is
  # pinned here. agent-role, claude and t3 come from the user's PATH, where the
  # agent stack installs them. `t3 thread start` takes no effort setting, so a
  # T3 session uses the provider's default effort for the role's model.
  triageAgent = writeShellScript "nixfleet-triage-agent" ''
    if ! command -v agent-role >/dev/null 2>&1; then
      echo "nixfleet-triage-agent: agent-role is not on PATH; install the agent stack to launch the triage agent" >&2
      exit 127
    fi
    model="$(agent-role deep claude model)" || {
      echo "nixfleet-triage-agent: agent-role could not resolve the deep role's model" >&2
      exit 1
    }

    if [ "''${NIXFLEET_TRIAGE_TERMINAL:-}" != 1 ] && [ "$#" -gt 0 ] && command -v t3 >/dev/null 2>&1; then
      prompt="''${*: -1}"
      if t3 thread list --project . >/dev/null 2>&1; then
        title="nixfleet triage"
        case "$prompt" in
          "This is warning triage"*) title="nixfleet warning triage" ;;
        esac
        # A run handed over from another host is copied under
        # handoffs/<host>/<run>.
        run="$(printf '%s\n' "$prompt" | ${gnused}/bin/sed -n -e 's|.*/nix-deploy/handoffs/\([^/ ]*\)/\([^/ ]*\)/.*|\2 from \1|p' -e 't' -e 's|.*/nix-deploy/runs/\([^/ ]*\)/.*|\1|p' | ${coreutils}/bin/head -n 1)"
        if [ -n "$run" ]; then
          title="$title: $run"
        fi
        if thread="$(printf '%s\n' "$prompt" | t3 thread start --title "$title" --provider claudeAgent --model "$model" . -)"; then
          echo "nixfleet-triage-agent: triage runs in the T3 Code thread \"$title\" ($thread). Open it in T3 Code, or read it with: t3 thread show $thread"
          exit 0
        fi
        echo "nixfleet-triage-agent: T3 Code could not start a thread; running the agent in this terminal instead" >&2
      else
        echo "nixfleet-triage-agent: T3 Code is not running or has no project for $PWD; running the agent in this terminal instead" >&2
      fi
    fi

    if ! command -v claude >/dev/null 2>&1; then
      echo "nixfleet-triage-agent: claude is not on PATH; install the agent stack to launch the triage agent" >&2
      exit 127
    fi
    # Effort is optional for a role; without one, Claude keeps its default.
    effort="$(agent-role deep claude effort 2>/dev/null)" || effort=""
    if [ -n "$effort" ]; then
      exec claude --model "$model" --effort "$effort" "$@"
    fi
    exec claude --model "$model" "$@"
  '';

  config = {
    schemaVersion = 1;
    operatorHost = "xyz";
    homeManagerUser = "alc";
    homeOutputPrefix = "alc-";
    knownHosts = hostNames;
    homeManagerHosts = homeManagerHostNames;
    remoteHosts = lib.filter (host: host != "xyz") nixosHostNames;
    deployAllHosts = deployAllHostNames;
    inherit aliases sshHosts systemSshUsers systemActivationModes;
    systemRemoteSudoHosts = lib.filter (host: inventory.hosts.${host}.systemUseRemoteSudo or false) nixosHostNames;
    kubernetesNodes = kubernetesNodeHostNames;
    inherit kubernetesContext kubernetesCorePriorityClass;
    interactiveHosts = interactiveHostNames;
    rebootGuardCommand = "nixfleet-reboot-guard";
    # Planned reboots quiet monitoring and announce progress through the
    # operator's hook (nix-packages ADR-0010), which the private flake
    # installs where it applies; elsewhere a run calls nothing.
    rebootHookCommand = "if command -v nixfleet-reboot-hook >/dev/null; then exec nixfleet-reboot-hook; fi";
    # Every NixOS host records a boot check (modules/nixos/services/nixfleet-boot-check).
    bootCheck = true;
    serialSystemHosts = k3sServerHostNames;
    # The node's own API server must be ready (this includes etcd health) and
    # the control plane must report the node Ready. kubectl comes from PATH so
    # the managed kubeconfig wrapper applies.
    serialReadyCommand = "kubectl --context ${kubernetesContext} --request-timeout=10s --server https://{host}:6443 get --raw=/readyz >/dev/null && kubectl --context ${kubernetesContext} wait --for=condition=Ready node/{host} --timeout=30s";
    serialReadyTimeoutSeconds = 600;
    serialGroups = lib.optional (dnsServerHostNames != []) {
      hosts = dnsServerHostNames;
      readyCommand = "${dnsReady} {host}";
      readyTimeoutSeconds = 300;
    };
    # Read only by nixfleet triage (nix-packages ADR-0016): the agent it
    # launches and the local checkouts of the operator's own flake inputs.
    # Inputs without a local checkout are not mapped. Other hosts hand their
    # failed runs to xyz, whose T3 Code server the operator's apps use; the
    # hint is printed when xyz cannot reach the host back over SSH.
    triage = {
      agentCommand = ["${triageAgent}"];
      triageHost = "xyz";
      sshHint = "on the Mac, run mac-ssh-on; elsewhere, check that sshd runs and accepts xyz's key";
      inputCheckouts = {
        bivrost = "~/src/apps/bivrost";
        bivrost-dev = "~/src/apps/bivrost";
        canopy = "~/src/apps/canopy";
        canopy-dev = "~/src/apps/canopy";
        devstats = "~/src/personal/devstats";
        dms-plugins = "~/src/tools/dms-plugins";
        grove = "~/src/apps/grove";
        grove-dev = "~/src/apps/grove";
        hedgedoc = "~/src/tools/hedgedoc";
        nix-packages = "~/src/infra/nix-packages";
        nix-secrets = "~/src/infra/nix-secrets";
        pandora = "~/src/infra/pandora";
        paperflow = "~/src/apps/paperflow";
        paperless-tools = "~/src/tools/paperless-tools";
        paperless-tools-dev = "~/src/tools/paperless-tools";
        paw = "~/src/apps/paw";
        regnskap = "~/src/platform/regnskap";
        regnskap-dev = "~/src/platform/regnskap";
        reportcraft = "~/src/tools/reportcraft";
        stashdb-pop = "~/src/tools/stashdb-pop";
        t3rry = "~/src/apps/t3rry";
        t3rry-dev = "~/src/apps/t3rry";
        vidown = "~/src/apps/vidown";
      };
    };
    hostColors = {
      xyz = "137;180;250";
      nux = "166;227;161";
      nex = "249;226;175";
      xev = "148;226;213";
      xps = "245;194;231";
      rpi0 = "235;160;172";
      mac = "203;166;247";
    };
  };

  configFile = writeText "nix-deploy-inventory-v1.json" (builtins.toJSON config);
  # Warns, without failing or changing the checkout, when the lock differs from
  # the validated package revision (ADR-0080).
  lockCheck = writeShellApplication {
    name = "nix-deploy-lock-check";
    runtimeInputs = [coreutils gawk git jq];
    text = builtins.readFile ../../scripts/update-inputs/lock-promoted-packages.sh;
  };
  deploy = writeShellScriptBin "deploy" ''
    ${lockCheck}/bin/nix-deploy-lock-check --check || true
    exec ${nixDeploy}/bin/deploy --config "''${NIX_DEPLOY_CONFIG:-${configFile}}" "$@"
  '';
  # nixfleet's deploy, status, runners and reboot read the inventory from
  # NIX_DEPLOY_CONFIG unless given --config; off and on are k8s-node-power and
  # reject --config, so the wrapper exports it rather than passing it
  # (nix-packages#548). Node power runs the Go
  # command, as kreboot, koff and kon do (ADR-0068, nix-packages#552).
  nixfleet = writeShellScriptBin "nixfleet" ''
    if [ "''${1:-}" = deploy ]; then
      ${lockCheck}/bin/nix-deploy-lock-check --check || true
    fi
    export NIX_DEPLOY_CONFIG="''${NIX_DEPLOY_CONFIG:-${configFile}}"
    exec ${nixDeploy}/bin/nixfleet "$@"
  '';
  # runners is nixfleet runners.
  runners = writeShellScriptBin "runners" ''
    export NIX_DEPLOY_CONFIG="''${NIX_DEPLOY_CONFIG:-${configFile}}"
    exec ${nixDeploy}/bin/runners "$@"
  '';
in
  symlinkJoin {
    name = "nix-deploy-configured-0.3.0";
    paths = [deploy nixfleet runners];
    passthru = {
      deployConfig = configFile;
      unconfiguredPackage = nixDeploy;
    };
    meta =
      nixDeploy.meta
      // {
        description = "nix-deploy and nixfleet configured from the nix-config public inventory";
        mainProgram = "deploy";
      };
  }
