# modules/home-manager/shell/default.nix
{ config, lib, pkgs, osIcon ? "🐧", ... }:

with lib;
{
  home.packages = with pkgs; [
    nushell
    zoxide
    starship
    carapace
    carapace-bridge
    atuin
    direnv
    neovim
  ];

  programs = {
    starship = {
      enable = true;
      enableNushellIntegration = true;
    };
    zoxide = {
      enable = true;
      enableNushellIntegration = true;
    };
    carapace = {
      enable = true;
      enableNushellIntegration = true;
    };
    atuin = {
      enable = true;
      enableNushellIntegration = true;
      #daemon.enable = true;
    };
    direnv = {
      enable = true;
      enableNushellIntegration = true;
    };

    nushell = {
      enable = true;
      environmentVariables = {
        KUBECONFIG = "${config.home.homeDirectory}/.kube/config";
      };
      extraConfig = ''
        # --- Common Nushell Configuration (Part 1) ---
        $env.config = {
            show_banner: false,
            edit_mode: vi,
            table: { mode: rounded, index_mode: always, trim: { methodology: wrapping, wrapping_try_keep_words: true } },
            ls: { use_ls_colors: true, clickable_links: true },
            rm: { always_trash: false },
            history: { max_size: 10000, sync_on_enter: true, file_format: "plaintext" },
            completions: { case_sensitive: false, quick: true, partial: true, algorithm: "prefix" },
        }

        # In your nushell extraConfig, IF NEEDED:
        let custom_paths = [
            $"($env.HOME)/.cargo/bin",
            $"($env.HOME)/.local/bin"
        ]
        $env.PATH = ($env.PATH | append $custom_paths | uniq | where {|p| ($p | path exists) })
      '';
    };
  };

  # Configure Carapace to use various bridges.
  home.sessionVariables = {
    CARAPACE_BRIDGES = "zsh,bash,fish,powershell,inshellisense,cobra,argcomplete,clap";
  };

  # Read the starship.toml file, substitute the placeholder, and set the content.
  xdg.configFile."starship.toml".text =
    let
      template = builtins.readFile ./starship.toml;
    in lib.replaceStrings [ "@osIcon@" ] [ osIcon ] template;


  home.shellAliases = {
    hmxyz = "home-manager switch --flake .#alc-xyz";
    hmmac = "home-manager switch --flake .#alc-mac";
    nixyz = "sudo nixos-rebuild switch --flake .#xyz";
    k = "kubectl"; ka = "kubectl apply -f"; kg = "kubectl get"; kd = "kubectl describe";
    kdel = "kubectl delete"; kgpo = "kubectl get pod"; kgd = "kubectl get deployments";
    kc = "switcher"; kns = "switcher ns"; kl = "kubectl logs -f"; ke = "kubectl exec -it";
    tf = "terraform"; v = "nvim"; d = "docker"; l = "ls -all"; ll = "ls -la";
    c = "clear"; cd = "z";
    g = "lazygit"; gc = "git commit -m"; gca = "git commit -am"; gps = "git push";
    gpl = "git pull"; gst = "git status";
    glog = "git log --graph --topo-order --pretty='%w(100,0,6)%C(yellow)%h%C(bold)%C(black)%d %C(cyan)%ar %C(green)%an%n%C(bold)%C(white)%s %N' --abbrev-commit";
    t = "tmux"; ta = "tmux a";
  };
}
