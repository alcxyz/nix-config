# modules/home-manager/programs/ssh/default.nix
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkMerge optionalAttrs;
in {
  config = mkIf config.programs.ssh.enable (mkMerge [
    {
      programs.ssh = {
        # Don't use HM's built-in defaults; we define everything ourselves.
        enableDefaultConfig = false;

        matchBlocks = {
          "*" = {
            # Primary and hardware-backed keys (deployed by your secrets module)
            identityFile = [
              "~/.ssh/id_ed25519"
              "~/.ssh/id_ed25519_sk"
              "~/.ssh/id_ed25519_sk_rk"
            ];

            # New-style location for AddKeysToAgent
            addKeysToAgent = "yes";

            extraOptions =
              {
                ServerAliveInterval = "60";
                ServerAliveCountMax = "3";
                HashKnownHosts = "yes";
              }
              // optionalAttrs pkgs.stdenv.isDarwin {
                # macOS keychain integration
                #UseKeychain = "yes";
              };
          };

          "rpi*" = {
            user = "root";
          };

          "github" = {
            hostname = "github.com";
            user = "git";
          };

          "vps" = {
            hostname = "46.202.150.96";
            user = "root";
          };
        };
      };
    }

    # User-level ssh-agent only on Linux; macOS uses its own agent.
    (mkIf pkgs.stdenv.isLinux {
      services.ssh-agent.enable = true;
    })
  ]);
}
