# modules/home-manager/programs/kubernetes/default.nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.kubernetes.managed;
  managedKubeconfigPaths = [
    cfg.currentContextFile
    cfg.kubeconfig
  ]
  ++ cfg.extraKubeconfigs;
  managedKubeconfig = lib.concatStringsSep ":" managedKubeconfigPaths;
  addManagedKubeconfigs = lib.concatMapStringsSep "\n" (
    path: "        add_kubeconfig ${lib.escapeShellArg path}"
  ) managedKubeconfigPaths;
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
    runtimeInputs = [ pkgs.kubectl ];
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

  wrapCommand =
    name: package: executable:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ package ];
      text = ''
        ${setManagedKubeconfig}
        exec ${package}/bin/${executable} "$@"
      '';
    };
in
{
  options.programs.kubernetes.managed = {
    enable = lib.mkEnableOption "managed Kubernetes client wrappers";

    kubeconfig = lib.mkOption {
      type = lib.types.str;
      description = "Primary kubeconfig file used by managed Kubernetes client wrappers.";
    };

    extraKubeconfigs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
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
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.kubeconfig != "";
        message = "programs.kubernetes.managed.kubeconfig must be set";
      }
    ];

    home.activation.kubernetesCurrentContext = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
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
