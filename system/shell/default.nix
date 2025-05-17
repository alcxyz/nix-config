{ options
, config
, lib
, pkgs
, ...
}:
with lib;
with lib.custom; let
  cfg = config.system.shell;
in
{
  options.system.shell = with types; {
    shell = mkOpt (enum [ "nushell" "bash" "zsh" ]) "nushell" "What shell to use";
  };

  config = {
    environment.systemPackages = with pkgs; [
      bat
      nitch
      zoxide
      starship
      carapace
      glow
    ];

    users.defaultUserShell = pkgs.${cfg.shell};
    users.users.root.shell = pkgs.bashInteractive;

    home.programs.starship = {
      enable = true;
      enableZshIntegration = true;
      enableNushellIntegration = true;
    };
    home.configFile."starship.toml".source = ./starship.toml;

    home.programs.zoxide = {
      enable = true;
      enableZshIntegration = true;
      enableNushellIntegration = true;
    };

    home.programs.carapace = {
      enable = true;
      enableZshIntegration = true;
      enableNushellIntegration = true;
    };

    home.programs.atuin = {
      enable = true;
      enableZshIntegration = true;
      enableNushellIntegration = true;
    };
    
    home.programs.direnv = {
      enable = true;
      enableZshIntegration = true;
      enableNushellIntegration = true;
    };

    # zsh configuration
    #programs.zsh.enable = true;
    home.programs.zsh = mkIf (cfg.shell == "zsh") {
      enable = true;
      #defaultKeymap = "vicmd";
      oh-my-zsh.enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      initExtra = "";
      localVariables = {
      };
      shellAliases = {
      };
    };


    # Enable all if nushell
    home.programs.nushell = mkIf (cfg.shell == "nushell") {
      enable = true;
      shellAliases = config.environment.shellAliases // { ls = "ls"; };
      envFile.text = "";
      environmentVariables = { 
        KUBECONFIG = "/home/alc/.kube/config";
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
        def wezterm [] {
          $env.WAYLAND_DISPLAY = ""
          ${pkgs.wezterm}/bin/wezterm
        }

        source ~/.config/carapace/init.nu
      '';
    };


    environment.pathsToLink = [ "/share/zsh" ];

    environment.shellAliases = {
      nixyz = "nixos-rebuild switch --flake .#xyz";
      # K8s
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
      cd = "z";
      neofetch = "nitch";
      #pbcopy = "xsel --input --clipboard";
      #pbpaste = "xsel --output --clipboard";
      pbcopy = "clipboard copy";
      pbpaste = "clipboard paste";
    };

  };
}
