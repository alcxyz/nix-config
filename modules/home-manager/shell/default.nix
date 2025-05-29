# modules/home-manager/shell/default.nix
{ config, lib, pkgs, ... }:

with lib;
{
  home.packages = with pkgs; [
    nushell
    zoxide
    starship
    carapace
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
      # This is the COMMON part of extraConfig, primarily for PATH and common functions.
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

        # Common PATH setup (Nix, User, System base)
        # Platform-specific configs will MODIFY $env.PATH after this.
        let nix_paths = [
            $"($env.HOME)/.nix-profile/bin",
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin"
        ]
        let user_paths = [ $"($env.HOME)/.cargo/bin", $"($env.HOME)/.local/bin" ]
        let system_paths = [ "/usr/bin", "/bin", "/usr/sbin", "/sbin" ]
        $env.PATH = ($nix_paths ++ $user_paths ++ $system_paths | where {|p| ($p | path exists)} | uniq)

        # Common Custom Nushell functions
        def , [...packages] { nix shell ($packages | each {|s| $"nixpkgs#($s)"}) }
        def la [] { ls -la | sort-by type name }
        def .. [] { cd .. }
        def ... [] { cd ../.. }
        def gs [] { git status --short }

        # Debugging tool check
        def check-tools [] {
            let tools = ["nvim", "git", "starship", "zoxide", "direnv", "atuin"]
            $tools | each {|tool|
                {
                    tool: $tool,
                    available: (which $tool | is-not-empty),
                    path: (which $tool | get path.0? | default "not found")
                }
            }
        }
        # --- End Common Nushell Configuration (Part 1) ---
      '';
    };
  };

  xdg.configFile."starship.toml".source = ./starship.toml;

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
    #neofetch = "nitch";
  };
}
