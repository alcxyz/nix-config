# modules/home-manager/programs/kubernetes/default.nix
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.kubernetes.managed;
  bulletKubeconfigPaths = lib.optionals cfg.bullet.enable [
    cfg.bullet.sandboxKubeconfig
    cfg.bullet.stagingKubeconfig
    cfg.bullet.prodKubeconfig
    cfg.bullet.infraKubeconfig
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
      pkgs.gnugrep
      pkgs.kubectl
      pkgs.kubeswitch
    ];
    text = ''
      ${setManagedKubeconfig}

      if [ "$#" -eq 1 ] && kubectl config get-contexts -o name | grep -Fx -- "$1" >/dev/null; then
        exec kubectl config use-context "$1"
      fi

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

  switcherCommand = pkgs.writeShellApplication {
    name = "switcher";
    runtimeInputs = [
      pkgs.kubectl
      pkgs.kubeswitch
    ];
    text = ''
      ${setManagedKubeconfig}

      response="$(${pkgs.kubeswitch}/bin/switcher "$@")"
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

  wrapCommand = name: package: executable:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        package
        pkgs.kubelogin
      ];
      text = ''
        ${setManagedKubeconfig}
        exec ${package}/bin/${executable} "$@"
      '';
    };

  bulletEnv = ''
    export BULLET_AZURE_TENANT_ID_FILE=${lib.escapeShellArg cfg.bullet.azure.tenantIdFile}
    export BULLET_AZURE_SANDBOX_SUBSCRIPTION_ID_FILE=${lib.escapeShellArg cfg.bullet.azure.sandboxSubscriptionIdFile}
    export BULLET_AZURE_STAGING_SUBSCRIPTION_ID_FILE=${lib.escapeShellArg cfg.bullet.azure.stagingSubscriptionIdFile}
    export BULLET_AZURE_PROD_SUBSCRIPTION_ID_FILE=${lib.escapeShellArg cfg.bullet.azure.prodSubscriptionIdFile}
    export BULLET_AZURE_INFRA_SUBSCRIPTION_ID_FILE=${lib.escapeShellArg cfg.bullet.azure.infraSubscriptionIdFile}
    export BULLET_AZURE_PROD_BASTION_SUBSCRIPTION_ID_FILE=${lib.escapeShellArg cfg.bullet.azure.prodBastionSubscriptionIdFile}
    export BULLET_CONTEXT_SANDBOX=${lib.escapeShellArg cfg.bullet.sandboxContext}
    export BULLET_CONTEXT_STAGING=${lib.escapeShellArg cfg.bullet.stagingContext}
    export BULLET_CONTEXT_PROD=${lib.escapeShellArg cfg.bullet.prodContext}
    export BULLET_CONTEXT_INFRA=${lib.escapeShellArg cfg.bullet.infraContext}
    export BULLET_KUBECONFIG_SANDBOX=${lib.escapeShellArg cfg.bullet.sandboxKubeconfig}
    export BULLET_KUBECONFIG_STAGING=${lib.escapeShellArg cfg.bullet.stagingKubeconfig}
    export BULLET_KUBECONFIG_PROD=${lib.escapeShellArg cfg.bullet.prodKubeconfig}
    export BULLET_KUBECONFIG_INFRA=${lib.escapeShellArg cfg.bullet.infraKubeconfig}
  '';

  bulletCommand = name:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [cfg.bullet.package];
      text = ''
        ${bulletEnv}
        exec ${cfg.bullet.package}/bin/${name} "$@"
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
        description = "Install Bullet Azure/Bastion helper commands from bn-bootstrap.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = inputs.bn-bootstrap.packages.${pkgs.stdenv.hostPlatform.system}.default;
        description = "Package providing Bullet helper commands.";
      };

      stagingKubeconfig = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.kube/bullet-staging-config";
        description = "Kubeconfig path written by bullet-kube for the Bullet staging AKS cluster.";
      };

      sandboxKubeconfig = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.kube/bullet-sandbox-config";
        description = "Kubeconfig path written by bullet-kube for the Bullet sandbox AKS cluster.";
      };

      prodKubeconfig = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.kube/bullet-prod-config";
        description = "Kubeconfig path written by bullet-kube for the Bullet production AKS cluster.";
      };

      infraKubeconfig = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.kube/bullet-infra-config";
        description = "Kubeconfig path written by bullet-kube for the Bullet infrastructure AKS cluster.";
      };

      stagingContext = lib.mkOption {
        type = lib.types.str;
        default = "bullet-staging";
        description = "Context name written by bullet-kube for the Bullet staging AKS cluster.";
      };

      sandboxContext = lib.mkOption {
        type = lib.types.str;
        default = "bullet-sandbox";
        description = "Context name written by bullet-kube for the Bullet sandbox AKS cluster.";
      };

      prodContext = lib.mkOption {
        type = lib.types.str;
        default = "bullet-prod";
        description = "Context name written by bullet-kube for the Bullet production AKS cluster.";
      };

      infraContext = lib.mkOption {
        type = lib.types.str;
        default = "bullet-infra";
        description = "Context name written by bullet-kube for the Bullet infrastructure AKS cluster.";
      };

      azure = {
        tenantIdFile = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "SOPS-managed file containing the Bullet Azure tenant ID.";
        };

        sandboxSubscriptionIdFile = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "SOPS-managed file containing the Bullet sandbox subscription ID.";
        };

        stagingSubscriptionIdFile = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "SOPS-managed file containing the Bullet staging subscription ID.";
        };

        prodSubscriptionIdFile = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "SOPS-managed file containing the Bullet production subscription ID.";
        };

        infraSubscriptionIdFile = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "SOPS-managed file containing the Bullet infrastructure subscription ID.";
        };

        prodBastionSubscriptionIdFile = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "SOPS-managed file containing the Bullet shared production Bastion subscription ID.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.kubeconfig != "";
        message = "programs.kubernetes.managed.kubeconfig must be set";
      }
      {
        assertion =
          !cfg.bullet.enable
          || (
            cfg.bullet.azure.tenantIdFile
            != ""
            && cfg.bullet.azure.sandboxSubscriptionIdFile != ""
            && cfg.bullet.azure.stagingSubscriptionIdFile != ""
            && cfg.bullet.azure.prodSubscriptionIdFile != ""
            && cfg.bullet.azure.infraSubscriptionIdFile != ""
            && cfg.bullet.azure.prodBastionSubscriptionIdFile != ""
          );
        message = "programs.kubernetes.managed.bullet.azure secret file paths must be set when Bullet helpers are enabled";
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
            elif grep -q '^current-context: default$' "$current_file" && [ ${lib.escapeShellArg cfg.defaultContext} != default ]; then
              tmp_file="$(mktemp)"
              ${pkgs.gawk}/bin/awk -v ctx=${lib.escapeShellArg cfg.defaultContext} '
                /^current-context: default$/ { print "current-context: " ctx; next }
                { print }
              ' "$current_file" > "$tmp_file"
              cat "$tmp_file" > "$current_file"
              rm -f "$tmp_file"
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
        switcherCommand
        kubeContextCommand
        kubeNamespaceCommand
      ]
      ++ lib.optionals cfg.wrap.leantimeTidy [
        (wrapCommand "leantime-tidy" pkgs.leantime-tidy "leantime-tidy")
      ]
      ++ lib.optionals cfg.bullet.enable [
        (bulletCommand "bullet-login")
        (bulletCommand "bullet-connect")
        (bulletCommand "bullet-kube")
        (bulletCommand "bullet-proxy")
        (bulletCommand "bullet-boards")
      ];

    home.sessionVariables =
      lib.optionalAttrs cfg.exportSessionVariable {
        KUBECONFIG = managedKubeconfig;
      }
      // lib.optionalAttrs cfg.bullet.enable {
        BULLET_AZURE_TENANT_ID_FILE = cfg.bullet.azure.tenantIdFile;
        BULLET_AZURE_SANDBOX_SUBSCRIPTION_ID_FILE = cfg.bullet.azure.sandboxSubscriptionIdFile;
        BULLET_AZURE_STAGING_SUBSCRIPTION_ID_FILE = cfg.bullet.azure.stagingSubscriptionIdFile;
        BULLET_AZURE_PROD_SUBSCRIPTION_ID_FILE = cfg.bullet.azure.prodSubscriptionIdFile;
        BULLET_AZURE_INFRA_SUBSCRIPTION_ID_FILE = cfg.bullet.azure.infraSubscriptionIdFile;
        BULLET_AZURE_PROD_BASTION_SUBSCRIPTION_ID_FILE = cfg.bullet.azure.prodBastionSubscriptionIdFile;
        BULLET_CONTEXT_SANDBOX = cfg.bullet.sandboxContext;
        BULLET_CONTEXT_STAGING = cfg.bullet.stagingContext;
        BULLET_CONTEXT_PROD = cfg.bullet.prodContext;
        BULLET_CONTEXT_INFRA = cfg.bullet.infraContext;
        BULLET_KUBECONFIG_SANDBOX = cfg.bullet.sandboxKubeconfig;
        BULLET_KUBECONFIG_STAGING = cfg.bullet.stagingKubeconfig;
        BULLET_KUBECONFIG_PROD = cfg.bullet.prodKubeconfig;
        BULLET_KUBECONFIG_INFRA = cfg.bullet.infraKubeconfig;
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
