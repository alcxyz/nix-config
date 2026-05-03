# users/alc/common.nix
{ config, pkgs, lib, username, hostName, configDir, inputs, system, ... }:

let
  pkgsets = import "${configDir}/modules/nixos/common/pkgsets.nix" {
    inherit pkgs inputs;
  };
  hostSopsFile = (
    assert builtins.pathExists "${inputs.nix-secrets}/hosts/${hostName}/secrets.yaml";
    "${inputs.nix-secrets}/hosts/${hostName}/secrets.yaml"
  );
  operatorSshKeysFile = (
    assert builtins.pathExists "${inputs.nix-secrets}/operators/ssh_keys.yaml";
    "${inputs.nix-secrets}/operators/ssh_keys.yaml"
  );
  operatorSshKeyPairs = lib.optionals (hostName == "xyz") [
    "aur_key"
    "aur_paperflow"
    "docker"
    "github_actions_vps"
  ];
  operatorSshSecrets = lib.listToAttrs (
    lib.concatMap (name: [
      {
        name = "ssh.operator.${name}.private";
        value = {
          sopsFile = operatorSshKeysFile;
          key = "ssh_${name}";
          path = ".ssh/${name}";
          mode = "0600";
        };
      }
      {
        name = "ssh.operator.${name}.public";
        value = {
          sopsFile = operatorSshKeysFile;
          key = "ssh_${name}.pub";
          path = ".ssh/${name}.pub";
          mode = "0644";
        };
      }
    ]) operatorSshKeyPairs
  );
in

with lib;

{
  # ==================== Imports of truly common modules ====================
  imports = [
    # These are modules that are guaranteed to work on both OSes
    # or handle their own platform differences internally if needed
    "${configDir}/modules/home-manager/shell/default.nix"
    #"${configDir}/modules/home-manager/programs/wezterm/default.nix"
    "${configDir}/modules/home-manager/programs/git/default.nix"
    "${configDir}/modules/home-manager/programs/ssh/default.nix"
    #../../modules/home-manager/secrets/ssh-keys.nix
  ];

  # ==================== Home Manager Core Settings ====================
  home.username = username;
  # This still needs a conditional, as `homeDirectory` is fundamentally different!
  home.homeDirectory = if pkgs.stdenv.isDarwin
                       then "/Users/${username}"
                       else "/home/${username}";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  # ==================== Nix-Colors Settings ====================
  colorscheme.name = "catppuccin-mocha";

  # ==================== User Environment ====================
  home.sessionVariables = {
    DIRENV_LOG_FORMAT = "";
    CGO_ENABLED = "1";
    # FLAKE path still needs to be conditional, as it's an absolute path
    # relative to the OS's file system root
    FLAKE = "${config.home.homeDirectory}/nix/nix-config";
  };

  # Swtich aliases
  home.shellAliases = {
    hmsw = "home-manager switch --flake .#alc-${hostName}";
  };

  # ==================== Packages ====================
  home.packages =
    pkgsets.hm.base
    ++ [
    inputs.grove.packages.${pkgs.stdenv.hostPlatform.system}.default
    inputs.canopy.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  # ==================== Symlinked configs (live editing, all hosts) ====================
  xdg.configFile."television".source = config.lib.file.mkOutOfStoreSymlink
    "${config.home.homeDirectory}/nix/nix-config/users/alc/configs/television";

  xdg.configFile."llm/config.toml".source = config.lib.file.mkOutOfStoreSymlink
    "${config.home.homeDirectory}/nix/nix-config/users/alc/configs/llm/config.toml";

  home.file.".claude/CLAUDE.md".source = config.lib.file.mkOutOfStoreSymlink
    "${config.home.homeDirectory}/nix/nix-secrets/shared/claude/CLAUDE.md";

  home.file."AGENTS.md".source = config.lib.file.mkOutOfStoreSymlink
    "${config.home.homeDirectory}/nix/nix-secrets/shared/AGENTS.md";

  # ==================== Files ====================
  home.file = {
    "Documents/.keep".text = "";
    "Downloads/.keep".text = "";
    "Music/.keep".text = "";
    "Pictures/.keep".text = "";
    # Profile picture is usually common regardless of OS
    ".face".source = ./profile.jpg; # Relative to users/alc/
    "Pictures/profile.jpg".source = ./profile.jpg;

    # If you have general dotfiles that are always the same
    # e.g., a common nvim config
    # ".config/nvim/init.lua".source = ../../path/to/common/nvim/init.lua;
  };

  # ==================== Program Enabling for Common Programs ====================
  programs.ssh.enable = true;

  programs.git.managed.enable = true;

  # Forgejo credential helper — moved to linux/common.nix and darwin/mac.nix
  # where the sops secret path is available for inline injection.


  #programs.wezterm.enable = true;

  programs.ncspot.enable = true;
  
  # ==================== Sops with age over ssh ====================
  # Deploy user-level SSH keypair from sops
  sops = {
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    # optionally, fallback to SSH keys if you like:
    # age.sshKeyPaths = [ "${config.home.homeDirectory}/.ssh/id_ed25519" ];
    secrets = {
      "ssh.${hostName}.private" = {
        sopsFile = hostSopsFile;
        key = "ssh_id_ed25519";
        path = ".ssh/id_ed25519";
        mode = "0600";
      };
      "ssh.${hostName}.public" = {
        sopsFile = hostSopsFile;
        key = "ssh_id_ed25519.pub";
        path = ".ssh/id_ed25519.pub";
        mode = "0644";
      };
    } // operatorSshSecrets;
  };

  # Generate and manage the age key file
  home.activation.setupSopsAgeKey = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p $HOME/.config/sops/age
    if [ ! -f "$HOME/.config/sops/age/keys.txt" ]; then
      ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key < $HOME/.ssh/id_ed25519 > $HOME/.config/sops/age/keys.txt
      chmod 600 $HOME/.config/sops/age/keys.txt
    fi
  '';


  # Configure Forgejo as the local primary remote for repos that exist on
  # Forgejo. Runs on every home-manager switch; skips silently when offline.
  home.activation.forgejoPrimary = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if command -v forge-mirror >/dev/null 2>&1; then
      forge-mirror primary 2>/dev/null || true
    fi
  '';

}
