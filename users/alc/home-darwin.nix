# users/alc/home-darwin.nix
{ config, pkgs, lib, username, inputs, hostName, ... }:

with lib;
{
  imports = [ ./common.nix ];
  # macOS-specific packages
  home.packages = with pkgs; [
    mas
    #darwin.system_cmds # If needed for `defaults` in other HM modules, but avoid in shell
  ];
  programs.atuin.daemon.enable = false;

    # This is the macOS-specific part of extraConfig.
  # It will be concatenated AFTER the common part from shell/default.nix.
  programs.nushell.extraConfig = ''
    # Common PATH setup (Nix, User, System base)
    # Platform-specific configs will MODIFY $env.PATH after this.
    let nix_paths = [
        $"($env.HOME)/.nix-profile/bin",
        "/run/current-system/sw/bin",
        "/nix/var/nix/profiles/default/bin"
    ]
    #let user_paths = [ $"($env.HOME)/.cargo/bin", $"($env.HOME)/.local/bin" ]
    let system_paths = [ "/usr/bin", "/bin", "/usr/sbin", "/sbin" ]
    #$env.PATH = ($nix_paths ++ $user_paths ++ $system_paths | where {|p| ($p | path exists)} | uniq)
    $env.PATH = ($nix_paths ++ $system_paths | where {|p| ($p | path exists)} | uniq)
    # --- macOS-Specific Nushell Additions (Part 2) ---
    # Prepend Homebrew paths to $env.PATH
    let homebrew_bin_paths = [ "/opt/homebrew/bin", "/usr/local/bin" ]
    let homebrew_sbin_paths = [ "/opt/homebrew/sbin", "/usr/local/sbin" ]
    let existing_homebrew_paths = ($homebrew_bin_paths ++ $homebrew_sbin_paths | where {|p| ($p | path exists) })
    $env.PATH = ($env.PATH | prepend $existing_homebrew_paths | uniq) # Modifies PATH from common

    # macOS clipboard function (uses built-in pbcopy/pbpaste)
    #def clipboard [action: string] {
    #    if $action == "copy" { pbcopy }
    #    else if $action == "paste" { pbpaste }
    #    else { print "Usage: clipboard <copy|paste>" }
    #}
    # --- End macOS-Specific Nushell Additions (Part 2) ---
  '';

  home.shellAliases = {
    nixmac = "darwin-rebuild switch --flake .#mac";
  };

  # Deploy SSH key pair for macOS
  secrets.ssh.keyPair = {
    enable = true;
    baseName = "mac_id_ed25519";
    forceRefresh = false;
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
  
  programs.gpg.managed.agent.pinentryPackage = pkgs.pinentry_mac;

  # Configure git signing
  programs.git.managed = {
    userName = "alcxyz";
    userEmail = "me@alc.no";
    signingKey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";  # Use the deployed public key
    signByDefault = true;

    extraConfig = {
      core = { editor = "nvim"; };
      gpg.format = "ssh";
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
}
