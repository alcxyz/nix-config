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

          "rpi1" = {
            user = "root";
          };

          "rpi2" = {
            user = "root";
          };

          "github" = {
            hostname = "github.com";
            user = "git";
          };

          "git-ssh.alc.xyz" = {
            user = "git";
            extraOptions.ProxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
          };

          "nux-ssh.alc.xyz" = {
            extraOptions.ProxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
          };

          "vps" = {
            hostname = "46.202.150.96";
            user = "root";
          };
        };
      };
    }

    # SSH refuses the nix store symlink (world-readable). On each activation:
    # home-manager recreates the symlink (force=true allows it to overwrite our copy),
    # then the hook replaces it with a chmod 600 copy.
    {
      home.file.".ssh/config".force = true;
      home.activation.fixSshConfigPermissions = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"

        if [ -L "$HOME/.ssh/config" ]; then
          _target=$(readlink "$HOME/.ssh/config")
          rm "$HOME/.ssh/config"
          cp "$_target" "$HOME/.ssh/config"
        fi

        if [ -f "$HOME/.ssh/config" ]; then
          chmod 600 "$HOME/.ssh/config"
        fi
      '';
    }

    # User-level ssh-agent only on Linux; macOS uses its own agent.
    (mkIf pkgs.stdenv.isLinux {
      services.ssh-agent.enable = true;
    })
  ]);
}
