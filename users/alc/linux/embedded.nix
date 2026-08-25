{
  configDir,
  hostRole,
  inputs,
  pkgs,
  username,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  imports = [
    # Keep the shared private defaults evaluable without enabling the
    # Kubernetes operator toolchain on these appliances.
    "${configDir}/modules/home-manager/programs/kubernetes/default.nix"
    "${configDir}/modules/shared/host-metadata.nix"
  ];

  home = {
    inherit username;
    homeDirectory = "/home/${username}";
    stateVersion = "24.11";
    packages = pkgsets.home.${hostRole.homePackageSet};
    sessionVariables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
    };
    shellAliases = {
      l = "ls -lah";
      v = "nvim";
      t = "tmux";
      gst = "git status";
    };
  };

  programs = {
    home-manager.enable = true;
    bash = {
      enable = true;
      enableCompletion = true;
    };
    zsh = {
      enable = true;
      enableCompletion = true;
      defaultKeymap = "viins";
      shellAliases.".." = "builtin cd ..";
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
    };
    starship = {
      enable = true;
      enableBashIntegration = true;
      enableZshIntegration = true;
    };
    tmux = {
      enable = true;
      shell = "${pkgs.zsh}/bin/zsh";
    };
  };
}
