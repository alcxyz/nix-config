# modules/home-manager/shell/default.nix
{
  config,
  lib,
  pkgs,
  osIcon ? "🐧",
  ...
}: let
  cfg = config.alc.shell;
  enableBash = cfg.enableBash;
  enableNushell = cfg.enableNushell;
  enableZsh = cfg.enableZsh;

  # Patch atuin's nushell integration: fixes the e>| stdout-drop bug introduced
  # in 18.13.0 (atuinsh/atuin PR#3358, merged but unreleased as of 18.13.6).
  # e>| redirects only stderr into the pipe, so ATUIN_HISTORY_ID is always empty
  # and history end never records. Replace e>| with | to restore correct behaviour.
  atuinNuFixed = pkgs.runCommand "atuin-nushell-config-fixed.nu" {} ''
    export HOME=$(mktemp -d)
    ${pkgs.atuin}/bin/atuin init nu \
      | ${pkgs.gnused}/bin/sed 's/e>| complete | get stdout/| complete | get stdout/g' \
      | ${pkgs.gnused}/bin/sed 's/job spawn -t/job spawn -d/g' \
      > $out
  '';
in {
  imports = [
    ../../shared/shell.nix
  ];

  home.packages = with pkgs;
    [
      bashInteractive
      eza
      sesh
      television
      carapace-bridge
      zsh
      # nixd is the only LSP not in Mason's registry
      nixd

      # Formatters/linters on PATH for CLI, CI, and Claude Code
      nixfmt
      shellcheck
      prettier
      shfmt
      ruff
      stylua
    ]
    ++ lib.optionals enableNushell [nushell];

  home.sessionPath = [
    "${config.home.homeDirectory}/.cargo/bin"
    "${config.home.homeDirectory}/.local/bin"
    "${config.home.homeDirectory}/go/bin"
  ];

  home.sessionVariables = {
    CARAPACE_BRIDGES = "zsh,bash,fish,powershell,inshellisense,cobra,argcomplete,clap";
    EDITOR = "nvim";

    # Ensure UTF-8 locale for SSH sessions; macOS does not always set these.
    LANG = "en_US.UTF-8";
    LC_ALL = "en_US.UTF-8";
  };

  programs = {
    bash = {
      enable = enableBash;
      enableCompletion = true;
    };

    zsh = {
      enable = enableZsh;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
    };

    starship = {
      enable = true;
      enableBashIntegration = enableBash;
      enableNushellIntegration = enableNushell;
      enableZshIntegration = enableZsh;
    };
    zoxide = {
      enable = true;
      enableBashIntegration = enableBash;
      enableNushellIntegration = enableNushell;
      enableZshIntegration = enableZsh;
    };
    carapace = {
      enable = true;
      enableBashIntegration = enableBash;
      enableNushellIntegration = enableNushell;
      enableZshIntegration = enableZsh;
    };
    atuin = {
      enable = true;
      enableBashIntegration = enableBash;
      enableNushellIntegration = false; # sourced manually below with patch applied
      enableZshIntegration = enableZsh;
      # daemon.enable = true;
    };
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      enableBashIntegration = enableBash;
      enableNushellIntegration = enableNushell;
      enableZshIntegration = enableZsh;
    };

    nushell = {
      enable = enableNushell;

      environmentVariables = {
        CARAPACE_BRIDGES = "zsh,bash,fish,powershell,inshellisense,cobra,argcomplete,clap";
        EDITOR = "nvim";
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

        source ${atuinNuFixed}
      '';
    };
  };

  # Read the starship.toml file, substitute the placeholder, and set the content.
  xdg.configFile."starship.toml".text = let
    template = builtins.readFile ./starship.toml;
  in
    lib.replaceStrings ["@osIcon@"] [osIcon] template;

  home.shellAliases = {
    tf = "terraform";
    v = "nvim";
    d = "docker";
    dcd = "docker compose down";
    dcu = "docker compose up -d";
    l = "eza -a";
    ll = "eza -la --git --icons=auto";
    lll = "eza -la --git --icons=auto --time-style=long-iso";
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
