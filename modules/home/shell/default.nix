{ config, lib, pkgs, ... }:
with lib; # Keep 'with lib;' as lib is needed

{
  # User-specific packages for the shell environment
  home.packages = with pkgs; [
    zoxide
    starship
    carapace
    atuin
    direnv
    # Ensure Nushell itself is installed for the user
    nushell
  ];

  # Home Manager configurations for shell programs and user aliases (specific to Nushell)
  home.programs.starship = {
    enable = true;
    # Enable Nushell integration directly as this module is for Nushell users
    enableNushellIntegration = true;
  };
  # Assuming starship.toml exists relative to this home module
  home.configFile."starship.toml".source = ./starship.toml;

  home.programs.zoxide = {
    enable = true;
    enableNushellIntegration = true;
  };

  home.programs.carapace = {
    enable = true;
    enableNushellIntegration = true;
  };

  home.programs.atuin = {
    enable = true;
    enableNushellIntegration = true;
  };

  home.programs.direnv = {
    enable = true;
    enableNushellIntegration = true;
  };

  # Nushell configuration (no longer conditional, as this module is for Nushell users)
  home.programs.nushell = {
    enable = true;
    shellAliases = {
      # Nushell-specific aliases/overrides if any.
      # The original had "ls = "ls";" merged with config.environment.shellAliases.
      # We can add specific overrides here if needed, but general aliases go below.
    };
    envFile.text = "";
    environmentVariables = {
      KUBECONFIG = "/home/alc/.kube/config"; # User-specific env var example
    };
    extraConfig = ''
      # In config.nu
      $env.PATH = ($env.PATH | prepend $"($env.HOME)/.cargo/bin")
      $env.config = {
      	show_banner: false,
              edit_mode: vi,
      }

      def , [...packages] {
          nix shell ($packages | each {|s| $"nixpkgs#($s)"})
      }

      source ~/.config/carapace/init.nu
    '';
  };

  # User-specific shell aliases (applied by Home Manager to the user's shell)
  home.shellAliases = {
    # General aliases moved from the original system module
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

    tf = "terraform";
    v = "nvim";
    l = "ls -all";
    c = "clear";
    t = "tmux";
    ta = "tmux a";
    ".." = "cd ..";
    cd = "z"; # Assuming zoxide is used and 'z' is the alias for jumping
    neofetch = "nitch"; # Assuming nitch is preferred over neofetch
    pbcopy = "clipboard copy"; # Assuming 'clipboard' is a available command
    pbpaste = "clipboard paste"; # Assuming 'clipboard' is a available command
  };
}
