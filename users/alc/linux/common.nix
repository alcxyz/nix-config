# users/alc/linux/common.nix
{
  inputs,
  config,
  pkgs,
  hostName,
  configDir,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  # Import the global common config first.
  imports = [
    "${configDir}/users/alc/common.nix"
    "${configDir}/modules/home-manager/programs/vidown/default.nix"
    "${configDir}/modules/home-manager/programs/videdupe/default.nix"
  ];

  # ==================== Common Linux Packages ====================
  # Small Linux-specific additions; common.nix already provides the shared base.
  home.packages = pkgsets.hm.linux;

  # ==================== Common Linux Programs & Services ====================
  programs.atuin.daemon.enable = true;
  programs.vidown.enable = true;
  programs.videdupe.enable = true;

  programs.nushell = {
    extraConfig = ''
      # Set SSH_AUTH_SOCK at runtime so $XDG_RUNTIME_DIR is properly
      # expanded. This matches the socket path used by services.ssh-agent
      # on Linux, while preserving forwarded agents in SSH sessions.
      if ("SSH_AUTH_SOCK" not-in $env) and ("XDG_RUNTIME_DIR" in $env) {
        $env.SSH_AUTH_SOCK = ($env.XDG_RUNTIME_DIR | path join "ssh-agent")
      }
    '';
  };

  programs.bash.initExtra = ''
    if [ -z "''${SSH_AUTH_SOCK:-}" ] && [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
      export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent"
    fi
  '';

  programs.zsh.initContent = ''
    if [ -z "''${SSH_AUTH_SOCK:-}" ] && [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
      export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent"
    fi
  '';

  # Switch aliases
  home.shellAliases = {
    nxsw = "sudo nixos-rebuild switch --flake .#${hostName}";
  };

  xdg.mimeApps.defaultApplications = {
    "text/html" = "zen.desktop";
    "x-scheme-handler/http" = "zen.desktop";
    "x-scheme-handler/https" = "zen.desktop";
    "x-scheme-handler/about" = "zen.desktop";
    "x-scheme-handler/unknown" = "zen.desktop";
  };

  # Configure git signing key to use the deployed public key
  programs.git.managed = {
    signingKey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
  };
}
