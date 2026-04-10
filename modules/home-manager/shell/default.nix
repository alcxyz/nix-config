# modules/home-manager/shell/default.nix
{ config, lib, pkgs, inputs, osIcon ? "🐧", ... }:

with lib;
let
  # Patch atuin's nushell integration: fixes the e>| stdout-drop bug introduced
  # in 18.13.0 (atuinsh/atuin PR#3358, merged but unreleased as of 18.13.6).
  # e>| redirects only stderr into the pipe, so ATUIN_HISTORY_ID is always empty
  # and history end never records. Replace e>| with | to restore correct behaviour.
  atuinNuFixed = pkgs.runCommand "atuin-nushell-config-fixed.nu" { } ''
    export HOME=$(mktemp -d)
    ${pkgs.atuin}/bin/atuin init nu \
      | ${pkgs.gnused}/bin/sed 's/e>| complete | get stdout/| complete | get stdout/g' \
      > $out
  '';
in
{
  home.packages = with pkgs; [
    nushell
    zoxide
    starship
    atuin
    sesh
    television
    carapace-bridge
    # nixd is the only LSP not in Mason's registry
    nixd

    # Formatters/linters on PATH for CLI, CI, and Claude Code
    nixfmt
    shellcheck
    prettier
    shfmt
    ruff
    stylua
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
      enableNushellIntegration = false; # sourced manually below with patch applied
      #daemon.enable = true;
    };
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      enableNushellIntegration = true;
    };

    nushell = {
      enable = true;
      
      environmentVariables = {
        KUBECONFIG = "${config.home.homeDirectory}/.kube/config";
        CARAPACE_BRIDGES = "zsh,bash,fish,powershell,inshellisense,cobra,argcomplete,clap";

        EDITOR = "nvim";
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

        let custom_paths = [
            $"($env.HOME)/.cargo/bin",
            $"($env.HOME)/.local/bin"
            $"($env.HOME)/go/bin"
        ]
        $env.PATH = ($env.PATH | append $custom_paths | uniq | where {|p| ($p | path exists) })

        source ${atuinNuFixed}
      '';
    };
  };

  # Read the starship.toml file, substitute the placeholder, and set the content.
  xdg.configFile."starship.toml".text =
    let
      template = builtins.readFile ./starship.toml;
    in lib.replaceStrings [ "@osIcon@" ] [ osIcon ] template;


  home.shellAliases = {
    k = "kubectl"; ka = "kubectl apply -f"; kg = "kubectl get"; kd = "kubectl describe";
    kdel = "kubectl delete"; kgpo = "kubectl get pod"; kgd = "kubectl get deployments";
    kc = "switcher"; kns = "switcher ns"; kl = "kubectl logs -f"; ke = "kubectl exec -it";
    tf = "terraform"; v = "nvim"; d = "docker"; dcd = "docker compose down"; dcu = "docker compose up -d"; l = "ls -all"; ll = "ls -la";
    c = "clear"; cd = "z";
    g = "gitui"; gc = "git commit -m"; gca = "git commit -am"; gps = "git push";
    gpl = "git pull"; gst = "git status";
    glog = "git log --graph --topo-order --pretty='%w(100,0,6)%C(yellow)%h%C(bold)%C(black)%d %C(cyan)%ar %C(green)%an%n%C(bold)%C(white)%s %N' --abbrev-commit";
    t = "tmux"; ta = "tmux a";
  };
}
