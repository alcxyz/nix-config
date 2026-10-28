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
  enableZsh = cfg.enableZsh;

  shellAliases = {
    tf = "terraform";
    np = "nix-shell -p";
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
    g = "gitui";
    gc = "git commit -m";
    gca = "git commit -am";
    gps = "git push";
    gpl = "git pull";
    gsp = "git pull --autostash";
    gst = "git status";
    glog = "git log --graph --topo-order --pretty='%w(100,0,6)%C(yellow)%h%C(bold)%C(black)%d %C(cyan)%ar %C(green)%an%n%C(bold)%C(white)%s %N' --abbrev-commit";
    t = "tmux";
    ta = "tmux a";
  };

  # `wt switch` changes directory through a shell function. Only hosts with
  # the AI package set install worktrunk, so guard on it being on PATH.
  worktrunkInit = shell: ''
    if command -v wt >/dev/null 2>&1; then
      eval "$(command wt config shell init ${shell})"
    fi
  '';
in {
  imports = [
    ../../shared/shell.nix
  ];

  home.packages = with pkgs; [
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
  ];

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
      initExtra = lib.mkOrder 2000 ''
        # Starship 1.25 emits Bash \[...\] prompt guards. In nested Bash
        # sessions those guards can be rendered literally after ANSI stripping,
        # so use Starship's plain ANSI prompt rendering for Bash too.
        export STARSHIP_SHELL=unknown

        ${worktrunkInit "bash"}
      '';
    };

    zsh = {
      enable = enableZsh;
      enableCompletion = true;
      defaultKeymap = "viins";
      shellAliases.".." = "builtin cd ..";
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      initContent = worktrunkInit "zsh";
    };

    starship = {
      enable = true;
      enableBashIntegration = enableBash;
      enableZshIntegration = enableZsh;
    };
    zoxide = {
      enable = true;
      enableBashIntegration = enableBash;
      enableZshIntegration = enableZsh;
    };
    carapace = {
      enable = true;
      enableBashIntegration = enableBash;
      enableZshIntegration = enableZsh;
    };
    atuin = {
      enable = true;
      # atuin 18.23.0 has no cached darwin build, and its end-to-end tests that
      # drive bash over a pty time out when built on macOS (its unit tests
      # pass). The version check drops the override once nixpkgs moves on.
      package =
        if pkgs.stdenv.hostPlatform.isDarwin && pkgs.atuin.version == "18.23.0"
        then pkgs.atuin.overrideAttrs {doCheck = false;}
        else pkgs.atuin;
      enableBashIntegration = enableBash;
      enableZshIntegration = enableZsh;
      # daemon.enable = true;
    };
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      enableBashIntegration = enableBash;
      enableZshIntegration = enableZsh;
    };
  };

  # Read the starship.toml file, substitute the placeholder, and set the content.
  xdg.configFile."starship.toml".text = let
    template = builtins.readFile ./starship.toml;
  in
    lib.replaceStrings ["@osIcon@"] [osIcon] template;

  home.shellAliases = shellAliases;
}
