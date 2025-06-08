{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

{
  config = mkIf config.programs.ssh.enable {
    programs.ssh = {
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
          identityFile = "~/.ssh/id_ed25519";
          extraOptions = {
            AddKeysToAgent = "yes";
          };
        };
      };
      extraConfig = ''
        # Primary key (deployed by our secrets module)
        IdentityFile ~/.ssh/id_ed25519
        
        # Hardware security keys (if you have them)
        IdentityFile ~/.ssh/id_ed25519_sk
        IdentityFile ~/.ssh/id_ed25519_sk_rk
        
        # SSH client configuration
        ServerAliveInterval 60
        ServerAliveCountMax 3
        HashKnownHosts yes
        AddKeysToAgent yes
        
        ${optionalString pkgs.stdenv.isDarwin ''
        # macOS keychain integration
        UseKeychain yes
        ''}
      '';
    };
  };
}
