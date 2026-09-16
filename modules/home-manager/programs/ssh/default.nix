# modules/home-manager/programs/ssh/default.nix
{
  config,
  inputs,
  lib,
  pkgs,
  inventory ? {},
  username ? config.home.username,
  ...
}: let
  inherit (lib) mkIf mkMerge optionalAttrs;
  managedHosts = inventory.hosts or {};
  mkManagedHostBlock = name: hostAttrs: let
    aliases = hostAttrs.aliases or [];
    hostPatterns = [name] ++ aliases;
  in {
    ${name} = {
      header = "Host ${lib.concatStringsSep " " hostPatterns}";
      HostName = hostAttrs.sshHostname or name;
      User = hostAttrs.sshUser or username;
      ForwardAgent = hostAttrs.forwardAgent or false;
    };
  };
  managedHostSettings = lib.attrsets.mergeAttrsList (lib.mapAttrsToList mkManagedHostBlock managedHosts);
in {
  imports = [inputs.nix-secrets.homeManagerModules.sshClientPolicy];

  config = mkIf config.programs.ssh.enable (mkMerge [
    {
      programs.ssh = {
        # Don't use HM's built-in defaults; we define everything ourselves.
        enableDefaultConfig = false;
        includes = ["~/.ssh/config.d/*.conf"];

        settings =
          managedHostSettings
          // {
            "*" =
              {
                # Primary and hardware-backed keys (deployed by your secrets module)
                IdentityFile = [
                  "~/.ssh/id_ed25519"
                  "~/.ssh/id_ed25519_sk"
                  "~/.ssh/id_ed25519_sk_rk"
                ];

                AddKeysToAgent = "yes";
                ServerAliveInterval = 60;
                ServerAliveCountMax = 3;
                HashKnownHosts = true;
              }
              // optionalAttrs pkgs.stdenv.isDarwin {
                # macOS keychain integration
                #UseKeychain = "yes";
              };

            "github" = {
              HostName = "github.com";
              User = "git";
            };
          };
      };
    }

    # SSH refuses the nix store symlink (world-readable). On each activation:
    # home-manager recreates the symlink (force=true allows it to overwrite our copy),
    # then the hook replaces it with a chmod 600 copy.
    {
      home.file.".ssh/config".force = true;
      home.activation.fixSshConfigPermissions = lib.hm.dag.entryAfter ["linkGeneration"] ''
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

    # User-level ssh-agent only on Linux; macOS uses its own agent. This is
    # defined directly instead of services.ssh-agent because that module also
    # injects Nushell init code that assumes XDG_RUNTIME_DIR always exists.
    (mkIf pkgs.stdenv.isLinux {
      systemd.user.services.ssh-agent = {
        Install.WantedBy = ["default.target"];
        Unit = {
          Description = "SSH authentication agent";
          Documentation = ["man:ssh-agent(1)"];
        };
        Service = {
          ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -a %t/ssh-agent";
          SuccessExitStatus = 2;
        };
      };
    })
  ]);
}
