# users/alc/linux/madsil.nix
{
  pkgs,
  configDir,
  ...
}: {
  home.username = "alc";
  home.homeDirectory = "/home/alc";
  home.stateVersion = "24.11";

  home.packages = with pkgs; [
    btop
    git
    jq
    nix-deploy
    ripgrep
    tmux
    vim
  ];

  home.sessionVariables = {
    FLAKE = configDir;
  };
}
