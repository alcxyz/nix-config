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
  enableXonsh = cfg.enableXonsh;
  enableXonshCarapace = cfg.enableXonshCarapace;
  enableZsh = cfg.enableZsh;
  xonshPackage = pkgs.xonsh-with-direnv or pkgs.xonsh;
  xonshDirenvIntegration = pkgs ? xonsh-with-direnv;

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
    gst = "git status";
    glog = "git log --graph --topo-order --pretty='%w(100,0,6)%C(yellow)%h%C(bold)%C(black)%d %C(cyan)%ar %C(green)%an%n%C(bold)%C(white)%s %N' --abbrev-commit";
    t = "tmux";
    ta = "tmux a";
  };
  xonshOnlyAliases = {
    # Keep this out of Bash/Zsh: ':' is a POSIX no-op builtin used by prompt
    # init scripts, and aliasing it corrupts Starship/Atuin Bash startup.
    ":" = "nix-shell -p";
  };

  xonshAliases =
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (
        name: value: "aliases[${builtins.toJSON name}] = ${builtins.toJSON value}"
      )
      (shellAliases // xonshOnlyAliases));

  xonshSessionVariables =
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (
        name: value: "__xonsh__.env[${builtins.toJSON name}] = ${builtins.toJSON value}"
      )
      (lib.filterAttrs (
          _name: value: builtins.isString value && ! lib.hasInfix "$" value
        )
        config.home.sessionVariables));

  xonshSessionPath =
    lib.concatMapStringsSep "\n"
    (path: ''
      if os.path.isdir(${builtins.toJSON path}) and ${builtins.toJSON path} not in $PATH:
          $PATH.append(${builtins.toJSON path})
    '')
    config.home.sessionPath;
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
    ++ lib.optionals enableXonsh [xonshPackage];

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
      '';
    };

    zsh = {
      enable = enableZsh;
      enableCompletion = true;
      defaultKeymap = "viins";
      shellAliases.".." = "builtin cd ..";
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
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

  xdg.configFile."xonsh/rc.xsh" = lib.mkIf enableXonsh {
    text = ''
      import os

      $VI_MODE = True

      ${xonshSessionVariables}

      ${xonshSessionPath}

      if "XDG_RUNTIME_DIR" in __xonsh__.env:
          __xonsh__.env["SSH_AUTH_SOCK"] = os.path.join($XDG_RUNTIME_DIR, "ssh-agent")

      ${xonshAliases}

      execx($(${pkgs.starship}/bin/starship init xonsh --print-full-init))
      execx($(${pkgs.zoxide}/bin/zoxide init xonsh))
      execx($(${pkgs.atuin}/bin/atuin init xonsh))
      ${lib.optionalString enableXonshCarapace ''
        if __xonsh__.env.get("XONSH_INTERACTIVE"):
            execx($(${pkgs.carapace}/bin/carapace _carapace xonsh))
      ''}
      ${lib.optionalString xonshDirenvIntegration ''
        xontrib load direnv
      ''}
    '';
  };

  home.shellAliases = shellAliases;
}
