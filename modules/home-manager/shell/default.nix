# modules/home-manager/shell/default.nix
{
  config,
  lib,
  pkgs,
  inputs,
  osIcon ? "🐧",
  ...
}:

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
      | ${pkgs.gnused}/bin/sed 's/job spawn -t/job spawn -d/g' \
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
        CARAPACE_BRIDGES = "zsh,bash,fish,powershell,inshellisense,cobra,argcomplete,clap";

        EDITOR = "nvim";

        # Ensure UTF-8 locale for SSH sessions (macOS doesn't set these by default)
        LANG = "en_US.UTF-8";
        LC_ALL = "en_US.UTF-8";
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

        def colorize-name [] {
          $in | update name {|r|
            if $r.type == "dir" { $"(ansi blue_bold)($r.name)(ansi reset)" } else if $r.type == "symlink" { $"(ansi cyan_italic)($r.name)(ansi reset)" } else if ($r.mode | str starts-with "-rwx") { $"(ansi red_bold)($r.name)(ansi reset)" } else { $r.name }
          }
        }

        def drop-empty-target [] {
          let result = $in
          if ($result | columns | any {|c| $c == "target"}) and ($result.target | all {|t| $t == null}) {
            $result | reject target
          } else {
            $result
          }
        }

        def lll [pattern?: glob] {
          if ($pattern == null) {
            ls -la | reject inode readonly | rename -c { num_links: lnk } | colorize-name | drop-empty-target
          } else {
            ls -la $pattern | reject inode readonly | rename -c { num_links: lnk } | colorize-name | drop-empty-target
          }
        }

        def ll [pattern?: glob] {
          if ($pattern == null) {
            ls -la | reject inode readonly created accessed | rename -c { num_links: lnk } | colorize-name | drop-empty-target
          } else {
            ls -la $pattern | reject inode readonly created accessed | rename -c { num_links: lnk } | colorize-name | drop-empty-target
          }
        }

        source ${atuinNuFixed}
      '';
    };
  };

  # Read the starship.toml file, substitute the placeholder, and set the content.
  xdg.configFile."starship.toml".text =
    let
      template = builtins.readFile ./starship.toml;
    in
    lib.replaceStrings [ "@osIcon@" ] [ osIcon ] template;

  home.shellAliases = {
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
    d = "docker";
    dcd = "docker compose down";
    dcu = "docker compose up -d";
    l = "ls -a";
    c = "clear";
    cd = "z";
    "," = "z";
    ",," = "z -";
    ":" = "nix-shell -p";
    g = "gitui";
    gc = "git commit -m";
    gca = "git commit -am";
    gps = "git push";
    gpl = "git pull";
    gst = "git status";
    glog = "git log --graph --topo-order --pretty='%w(100,0,6)%C(yellow)%h%C(bold)%C(black)%d %C(cyan)%ar %C(green)%an%n%C(bold)%C(white)%s %N' --abbrev-commit";
    t = "tmux";
    ta = "tmux a";
  };
}
