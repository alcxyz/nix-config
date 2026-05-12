# modules/home-manager/programs/kubernetes/default.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.kubernetes.managed;
  azureCli = pkgs.azure-cli.withExtensions (
    with pkgs.azure-cli.extensions; [
      ssh
      bastion
    ]
  );
  bulletKubeconfigPaths = lib.optionals cfg.bullet.enable [
    cfg.bullet.stagingKubeconfig
    cfg.bullet.prodKubeconfig
  ];
  managedKubeconfigPaths = lib.unique (
    [
      cfg.currentContextFile
      cfg.kubeconfig
    ]
    ++ cfg.extraKubeconfigs
    ++ bulletKubeconfigPaths
  );
  managedKubeconfig = lib.concatStringsSep ":" managedKubeconfigPaths;
  addManagedKubeconfigs =
    lib.concatMapStringsSep "\n" (
      path: "        add_kubeconfig ${lib.escapeShellArg path}"
    )
    managedKubeconfigPaths;
  setManagedKubeconfig = ''
        if [ -z "''${KUBECONFIG:-}" ]; then
          kubeconfigs=()
          add_kubeconfig() {
            if [ -r "$1" ]; then
              kubeconfigs+=("$1")
            fi
          }

    ${addManagedKubeconfigs}

          if [ "''${#kubeconfigs[@]}" -gt 0 ]; then
            old_ifs="$IFS"
            IFS=:
            export KUBECONFIG="''${kubeconfigs[*]}"
            IFS="$old_ifs"
          fi
        fi
  '';

  kubeContextCommand = pkgs.writeShellApplication {
    name = "kube-context";
    runtimeInputs = [
      pkgs.kubectl
      pkgs.kubeswitch
    ];
    text = ''
      ${setManagedKubeconfig}

      response="$(switcher set-context "$@")"
      status="$?"
      if [ "$status" -ne 0 ]; then
        printf '%s\n' "$response"
        exit "$status"
      fi

      case "$response" in
        "__ "*)
          payload="''${response#__ }"
          selected="''${payload#*,}"
          selected="''${selected%%,*}"
          exec kubectl config use-context "$selected"
          ;;
        *)
          printf '%s\n' "$response"
          ;;
      esac
    '';
  };

  kubeNamespaceCommand = pkgs.writeShellApplication {
    name = "kube-namespace";
    runtimeInputs = [pkgs.kubectl];
    text = ''
      ${setManagedKubeconfig}

      if [ "$#" -ne 1 ]; then
        printf 'Usage: kube-namespace <namespace>\n' >&2
        exit 2
      fi

      current_context="$(kubectl config current-context)"
      current_cluster="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')"
      current_user="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.user}')"
      writable_kubeconfig="''${KUBECONFIG%%:*}"

      kubectl config set-context \
        --kubeconfig "$writable_kubeconfig" \
        "$current_context" \
        --cluster "$current_cluster" \
        --user "$current_user" \
        --namespace "$1"
      exec kubectl config use-context --kubeconfig "$writable_kubeconfig" "$current_context"
    '';
  };

  bulletConnectCommand = pkgs.writeShellApplication {
    name = "bullet-connect";
    runtimeInputs = [azureCli];
    text = ''
      usage() {
        cat <<'EOF'
      Usage: bullet-connect [staging|prod]

      Connect to a Bullet management VM through Azure Bastion.

      Environments:
        staging  aliases: stg, nonprod, test
        prod     alias: production, requires PIM elevation
      EOF
      }

      ENV="''${1:-staging}"

      case "$ENV" in
        -h|--help)
          usage
          exit 0
          ;;
        staging|stg|nonprod|test)
          SUB="78b79a31-1a31-4ea7-b30f-9da053196f3c"
          RG="bn-rcmeaks-neu-rg-test"
          BASTION="bn-rcmeaks-neu-bas-test"
          VM_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Compute/virtualMachines/bn-rcmeaksmgmt-neu-vm-test"
          LABEL="staging"
          ;;
        prod|production)
          SUB="b62e975d-f464-43e3-a867-f860d71fccc6"
          RG="bn-rcmeaks-nwe-rg-prod02"
          BASTION="bn-rcmeaks-nwe-bas-prod02"
          VM_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Compute/virtualMachines/bn-rcmeaksmgmt-nwe-vm-prod01-02"
          LABEL="production"
          ;;
        *)
          usage >&2
          exit 2
          ;;
      esac

      printf '==> Connecting to Bullet %s management VM via Bastion...\n' "$LABEL"
      printf '    Subscription: %s\n\n' "$SUB"

      if [ "$LABEL" = "production" ]; then
        cat <<'EOF'
          NOTE: Production requires PIM elevation.
          Activate the relevant bn-platform-<TEAM>-prod group, then run:
            az logout && az login

      EOF
      fi

      az account set --subscription "$SUB"
      exec az network bastion ssh \
        --name "$BASTION" \
        --resource-group "$RG" \
        --target-resource-id "$VM_ID" \
        --auth-type AAD
    '';
  };

  bulletKubeCommand = pkgs.writeShellApplication {
    name = "bullet-kube";
    runtimeInputs = [
      azureCli
      pkgs.coreutils
      pkgs.kubelogin
    ];
    text = ''
      usage() {
        cat <<'EOF'
      Usage: bullet-kube [staging|prod] [--file PATH]

      Fetch Bullet AKS credentials into a dedicated kubeconfig file and convert
      it to Azure CLI exec auth so managed Kubernetes wrappers can discover it.

      Default output files:
        staging  ${cfg.bullet.stagingKubeconfig}
        prod     ${cfg.bullet.prodKubeconfig}

      Notes:
        - Production requires PIM elevation before running this command.
        - The generated kubeconfig lets switcher list/select the context.
        - Actual kubectl access still requires network reachability to the private AKS API.
      EOF
      }

      ENV="''${1:-staging}"
      if [ "$ENV" = "-h" ] || [ "$ENV" = "--help" ]; then
        usage
        exit 0
      fi

      if [ "$#" -gt 0 ]; then
        shift
      fi

      DEST_OVERRIDE=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --file)
            if [ "$#" -lt 2 ]; then
              printf 'bullet-kube: --file requires a path\n' >&2
              exit 2
            fi
            DEST_OVERRIDE="$2"
            shift 2
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            usage >&2
            exit 2
            ;;
        esac
      done

      case "$ENV" in
        staging|stg|nonprod|test)
          SUB="78b79a31-1a31-4ea7-b30f-9da053196f3c"
          RG="bn-rcmeaks-neu-rg-test"
          AKS="bn-rcmeaks-neu-aks-test"
          LABEL="staging"
          CONTEXT=${lib.escapeShellArg cfg.bullet.stagingContext}
          DEST=${lib.escapeShellArg cfg.bullet.stagingKubeconfig}
          ;;
        prod|production)
          SUB="b62e975d-f464-43e3-a867-f860d71fccc6"
          RG="bn-rcmeaks-nwe-rg-prod02"
          AKS="bn-rcmeaks-nwe-aks-prod02"
          LABEL="production"
          CONTEXT=${lib.escapeShellArg cfg.bullet.prodContext}
          DEST=${lib.escapeShellArg cfg.bullet.prodKubeconfig}
          ;;
        *)
          usage >&2
          exit 2
          ;;
      esac

      if [ -n "$DEST_OVERRIDE" ]; then
        DEST="$DEST_OVERRIDE"
      fi

      printf '==> Fetching Bullet %s AKS credentials...\n' "$LABEL"
      printf '    Cluster: %s\n' "$AKS"
      printf '    Context: %s\n' "$CONTEXT"
      printf '    File: %s\n\n' "$DEST"

      if [ "$LABEL" = "production" ]; then
        cat <<'EOF'
          NOTE: Production requires PIM elevation.
          Activate the relevant bn-platform-<TEAM>-prod group, then run:
            az logout && az login

      EOF
      fi

      mkdir -p "$(dirname "$DEST")"
      az account set --subscription "$SUB"
      az aks get-credentials \
        --resource-group "$RG" \
        --name "$AKS" \
        --file "$DEST" \
        --context "$CONTEXT" \
        --overwrite-existing
      kubelogin convert-kubeconfig \
        --kubeconfig "$DEST" \
        --context "$CONTEXT" \
        -l azurecli
      chmod 600 "$DEST"

      cat <<EOF

      ==> Done.
          Run 'kc' or 'switcher set-context' and select: $CONTEXT
      EOF
    '';
  };

  bulletProxyCommand = pkgs.writeShellApplication {
    name = "bullet-proxy";
    runtimeInputs = [
      azureCli
      pkgs.coreutils
      pkgs.openssh
    ];
    text = ''
      usage() {
        cat <<'EOF'
      Usage: bullet-proxy [staging|prod] [--tunnel-only]

      Create a Bastion tunnel to a Bullet management VM and, by default, run a
      SOCKS5 proxy through that tunnel.

      Environment variables:
        BULLET_TUNNEL_PORT  local SSH tunnel port, default 2222
        BULLET_SOCKS_PORT   local SOCKS5 port, default 8080
        BULLET_SSH_TARGET   SSH target through the tunnel, default 127.0.0.1
      EOF
      }

      ENV="''${1:-staging}"
      TUNNEL_ONLY="''${2:-}"
      LOCAL_PORT="''${BULLET_TUNNEL_PORT:-2222}"
      SOCKS_PORT="''${BULLET_SOCKS_PORT:-8080}"
      SSH_TARGET="''${BULLET_SSH_TARGET:-127.0.0.1}"

      case "$ENV" in
        -h|--help)
          usage
          exit 0
          ;;
        staging|stg|nonprod|test)
          SUB="78b79a31-1a31-4ea7-b30f-9da053196f3c"
          RG="bn-rcmeaks-neu-rg-test"
          BASTION="bn-rcmeaks-neu-bas-test"
          VM_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Compute/virtualMachines/bn-rcmeaksmgmt-neu-vm-test"
          LABEL="staging"
          ;;
        prod|production)
          SUB="b62e975d-f464-43e3-a867-f860d71fccc6"
          RG="bn-rcmeaks-nwe-rg-prod02"
          BASTION="bn-rcmeaks-nwe-bas-prod02"
          VM_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Compute/virtualMachines/bn-rcmeaksmgmt-nwe-vm-prod01-02"
          LABEL="production"
          ;;
        *)
          usage >&2
          exit 2
          ;;
      esac

      if [ -n "$TUNNEL_ONLY" ] && [ "$TUNNEL_ONLY" != "--tunnel-only" ]; then
        usage >&2
        exit 2
      fi

      printf '==> Starting Bastion tunnel to Bullet %s management VM...\n' "$LABEL"
      printf '    Local port %s -> VM port 22\n\n' "$LOCAL_PORT"

      if [ "$LABEL" = "production" ]; then
        cat <<'EOF'
          NOTE: Production requires PIM elevation.
          Activate the relevant bn-platform-<TEAM>-prod group, then run:
            az logout && az login

      EOF
      fi

      az account set --subscription "$SUB"

      if [ "$TUNNEL_ONLY" = "--tunnel-only" ]; then
        exec az network bastion tunnel \
          --name "$BASTION" \
          --resource-group "$RG" \
          --target-resource-id "$VM_ID" \
          --port "$LOCAL_PORT" \
          --resource-port 22
      fi

      az network bastion tunnel \
        --name "$BASTION" \
        --resource-group "$RG" \
        --target-resource-id "$VM_ID" \
        --port "$LOCAL_PORT" \
        --resource-port 22 &
      TUNNEL_PID="$!"

      cleanup() {
        kill "$TUNNEL_PID" 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM

      sleep 3
      if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        printf 'ERROR: Bastion tunnel failed to start.\n' >&2
        exit 1
      fi

      printf '==> Tunnel running (PID %s). Starting SOCKS5 proxy on port %s...\n' "$TUNNEL_PID" "$SOCKS_PORT"
      printf '    Configure your browser to use SOCKS5 at localhost:%s\n' "$SOCKS_PORT"
      printf '    Press Ctrl+C to stop.\n\n'

      ssh -D "$SOCKS_PORT" -N -o StrictHostKeyChecking=no -p "$LOCAL_PORT" "$SSH_TARGET"
    '';
  };

  wrapCommand = name: package: executable:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [package];
      text = ''
        ${setManagedKubeconfig}
        exec ${package}/bin/${executable} "$@"
      '';
    };
in {
  options.programs.kubernetes.managed = {
    enable = lib.mkEnableOption "managed Kubernetes client wrappers";

    kubeconfig = lib.mkOption {
      type = lib.types.str;
      description = "Primary kubeconfig file used by managed Kubernetes client wrappers.";
    };

    extraKubeconfigs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional kubeconfig files merged by managed Kubernetes client wrappers when they exist.";
    };

    currentContextFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.kube/nix-current-context";
      description = "Writable kubeconfig file used to persist the active context across merged kubeconfigs.";
    };

    defaultContext = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "Initial current context written to currentContextFile when it does not exist.";
    };

    exportSessionVariable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Export KUBECONFIG for the whole user session. Wrappers work without this.";
    };

    aliases.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install kubectl shell aliases.";
    };

    wrap = {
      kubectl = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install a kubectl wrapper that supplies KUBECONFIG when unset.";
      };

      flux = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install a flux wrapper that supplies KUBECONFIG when unset.";
      };

      helm = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install a helm wrapper that supplies KUBECONFIG when unset.";
      };

      k9s = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install a k9s wrapper that supplies KUBECONFIG when unset.";
      };

      kdash = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install a kdash wrapper that supplies KUBECONFIG when unset.";
      };

      kubeswitch = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install switcher and context helper wrappers that use the managed kubeconfig set.";
      };

      leantimeTidy = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Install a leantime-tidy wrapper that supplies KUBECONFIG when unset.";
      };
    };

    bullet = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default =
          builtins.elem cfg.bullet.stagingKubeconfig cfg.extraKubeconfigs
          || builtins.elem cfg.bullet.prodKubeconfig cfg.extraKubeconfigs;
        description = "Install Bullet Azure/Bastion helper commands.";
      };

      stagingKubeconfig = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.kube/bullet-staging-config";
        description = "Kubeconfig path written by bullet-kube for the Bullet staging AKS cluster.";
      };

      prodKubeconfig = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.kube/bullet-prod-config";
        description = "Kubeconfig path written by bullet-kube for the Bullet production AKS cluster.";
      };

      stagingContext = lib.mkOption {
        type = lib.types.str;
        default = "bullet-staging";
        description = "Context name written by bullet-kube for the Bullet staging AKS cluster.";
      };

      prodContext = lib.mkOption {
        type = lib.types.str;
        default = "bullet-prod";
        description = "Context name written by bullet-kube for the Bullet production AKS cluster.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.kubeconfig != "";
        message = "programs.kubernetes.managed.kubeconfig must be set";
      }
    ];

    home.activation.kubernetesCurrentContext = lib.hm.dag.entryAfter ["writeBoundary"] ''
            current_file=${lib.escapeShellArg cfg.currentContextFile}
            if [ ! -e "$current_file" ]; then
              mkdir -p "$(dirname "$current_file")"
              cat > "$current_file" <<EOF
      apiVersion: v1
      kind: Config
      preferences: {}
      current-context: ${cfg.defaultContext}
      clusters: []
      contexts: []
      users: []
      EOF
              chmod 600 "$current_file"
            fi
    '';

    home.packages =
      lib.optionals cfg.wrap.kubectl [
        (wrapCommand "kubectl" pkgs.kubectl "kubectl")
      ]
      ++ lib.optionals cfg.wrap.flux [
        (wrapCommand "flux" pkgs.fluxcd "flux")
      ]
      ++ lib.optionals cfg.wrap.helm [
        (wrapCommand "helm" pkgs.kubernetes-helm "helm")
      ]
      ++ lib.optionals cfg.wrap.k9s [
        (wrapCommand "k9s" pkgs.k9s "k9s")
      ]
      ++ lib.optionals cfg.wrap.kdash [
        (wrapCommand "kdash" pkgs.kdash "kdash")
      ]
      ++ lib.optionals cfg.wrap.kubeswitch [
        (wrapCommand "switcher" pkgs.kubeswitch "switcher")
        kubeContextCommand
        kubeNamespaceCommand
      ]
      ++ lib.optionals cfg.wrap.leantimeTidy [
        (wrapCommand "leantime-tidy" pkgs.leantime-tidy "leantime-tidy")
      ]
      ++ lib.optionals cfg.bullet.enable [
        bulletConnectCommand
        bulletKubeCommand
        bulletProxyCommand
      ];

    home.sessionVariables = lib.mkIf cfg.exportSessionVariable {
      KUBECONFIG = managedKubeconfig;
    };

    home.shellAliases = lib.mkIf cfg.aliases.enable {
      k = "kubectl";
      ka = "kubectl apply -f";
      kg = "kubectl get";
      kd = "kubectl describe";
      kdel = "kubectl delete";
      kgpo = "kubectl get pod";
      kgd = "kubectl get deployments";
      kc = "kube-context";
      kns = "kube-namespace";
      kl = "kubectl logs -f";
      ke = "kubectl exec -it";
    };
  };
}
