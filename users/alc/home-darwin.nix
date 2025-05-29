# users/alc/home-darwin.nix
{ config, pkgs, lib, username, inputs, ... }:

with lib;
{
  imports = [ ./common.nix ];
  # macOS-specific packages
  home.packages = with pkgs; [
    mas # Mac App Store CLI
    darwin.system_cmds # If needed for `defaults` in other HM modules, but avoid in shell
  ];
  #programs.atuin.daemon.enable = true; # Optionally enable for macOS

  # This is the macOS-specific part of extraConfig.
  # It will be concatenated AFTER the common part from shell/default.nix.
  programs.nushell.extraConfig = ''
    # --- macOS-Specific Nushell Additions (Part 2) ---
    # Prepend Homebrew paths to $env.PATH
    let homebrew_bin_paths = [ "/opt/homebrew/bin", "/usr/local/bin" ]
    let homebrew_sbin_paths = [ "/opt/homebrew/sbin", "/usr/local/sbin" ]
    let existing_homebrew_paths = ($homebrew_bin_paths ++ $homebrew_sbin_paths | where {|p| ($p | path exists) })
    $env.PATH = ($env.PATH | prepend $existing_homebrew_paths | uniq) # Modifies PATH from common

    # macOS clipboard function (uses built-in pbcopy/pbpaste)
    def clipboard [action: string] {
        if $action == "copy" { pbcopy }
        else if $action == "paste" { pbpaste }
        else { print "Usage: clipboard <copy|paste>" }
    }
    # --- End macOS-Specific Nushell Additions (Part 2) ---
  '';

  home.shellAliases = {
    nixmac = "darwin-rebuild switch --flake .#mac";
  };

  programs.zsh = { # Keep Zsh minimal if Nushell is primary
    enable = true;
    initContent = ''
      export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH"
      if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
      fi
    '';
  };

  programs.git.managed = {
    userName = "alcxyz"; # Global default
    userEmail = "me@alc.no"; # Global default
    signingKey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub"; # Global default signing key
    signByDefault = true; # Sign commits by default globally

    # Other global extra configs
    extraConfig = {
      core = { editor = "nvim"; }; # Corrected
      # gpg.format = "ssh"; # This is already in the module's defaultExtraConfig
    };

    aliases = {
      co = "checkout";
      br = "branch";
      st = "status";
    };

    /*
    conditionalSigningConfigs = {
      # Condition for work projects
      "gitdir:~/work/" = {
        "user.name" = "Alc Work";
        "user.email" = "alc@company.com";
        "user.signingkey" = "${config.home.homeDirectory}/.ssh/id_ed25519_work.pub";
        "commit.gpgsign" = "true"; # Ensure work commits are signed
        # "gpg.format" = "ssh"; # Inherits global, or override if work key is different type
      };

      # Condition for a specific personal project needing a different key/email
      "gitdir:~/personal/my-special-project/" = {
        "user.email" = "alc+specialproject@personal.com";
        "user.signingkey" = "${config.home.homeDirectory}/.ssh/id_ed25519_special.pub";
        # Inherits global user.name ("alcxyz")
        # Inherits global commit.gpgsign ("true") unless explicitly set to "false"
      };

      # Condition for projects where you don't want to sign commits
      "gitdir:~/personal/no-signing-repos/" = {
        "commit.gpgsign" = "false"; # Explicitly disable signing
      };
    };
    */
  };

  # macOS-specific home activation (optional)
  home.activation.macosDefaults = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # Set some macOS defaults via home-manager
    $DRY_RUN_CMD defaults write com.apple.dock autohide -bool true
    $DRY_RUN_CMD defaults write com.apple.dock tilesize -int 44
    $DRY_RUN_CMD killall Dock 2>/dev/null || true
  '';
}
