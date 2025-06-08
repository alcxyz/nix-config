# modules/home-manager/programs/ssh/default.nix
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

{
  # This module now ONLY configures the SSH client.
  config = mkIf config.programs.ssh.enable {
    programs.ssh = {
      #enable = true;
      matchBlocks = {
        "rpi*" = { user = "root"; };
        "github" = {
          hostname = "github.com";
          user = "git";
        };
        "vps" = {
          hostname = "46.202.150.96";
          user = "root";
        };
        "*" = {
          identityFile = "~/.ssh/id_xyz";
          extraOptions = {
            AddKeysToAgent = "yes";
          };
        };
      };
      extraConfig = ''
        IdentityFile ~/.ssh/id_ed25519
        IdentityFile ~/.ssh/id_ed25519_sk
        IdentityFile ~/.ssh/id_ed25519_sk_rk
      '';
    };

  };
}
