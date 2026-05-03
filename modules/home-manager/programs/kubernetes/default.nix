# modules/home-manager/programs/kubernetes/default.nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.kubernetes.managed;

  wrapCommand =
    name: package: executable:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ package ];
      text = ''
        if [ -z "''${KUBECONFIG:-}" ]; then
          export KUBECONFIG="${cfg.kubeconfig}"
        fi
        exec ${package}/bin/${executable} "$@"
      '';
    };
in
{
  options.programs.kubernetes.managed = {
    enable = lib.mkEnableOption "managed Kubernetes client wrappers";

    kubeconfig = lib.mkOption {
      type = lib.types.str;
      description = "Path to the kubeconfig file used by managed Kubernetes client wrappers.";
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

      kubeswitch = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install kubeswitch unchanged. It manages kubeconfig state itself.";
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
      ++ lib.optionals cfg.wrap.kubeswitch [
        pkgs.kubeswitch
      ]
      ++ lib.optionals cfg.wrap.leantimeTidy [
        (wrapCommand "leantime-tidy" pkgs.leantime-tidy "leantime-tidy")
      ];

    home.sessionVariables = lib.mkIf cfg.exportSessionVariable {
      KUBECONFIG = cfg.kubeconfig;
    };

    home.shellAliases = lib.mkIf cfg.aliases.enable {
      k = "kubectl";
      ka = "kubectl apply -f";
      kg = "kubectl get";
      kd = "kubectl describe";
      kdel = "kubectl delete";
      kgpo = "kubectl get pod";
      kgd = "kubectl get deployments";
      kc = "switcher";
      kns = "switcher ns";
      kl = "kubectl logs -f";
      ke = "kubectl exec -it";
    };
  };
}
