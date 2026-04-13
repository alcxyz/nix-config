# users/alc/common.nix
{ config, pkgs, lib, username, hostName, configDir, inputs, system, ... }:

let
  pkgsets = import "${configDir}/modules/nixos/common/pkgsets.nix" {
    inherit pkgs inputs;
  };
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
    (pkgs.writeShellScriptBin "claude-work" ''
      export CLAUDE_CONFIG_DIR="$HOME/.claude-work"
      exec claude "$@"
    '')
    (pkgs.writeShellScriptBin "cc-handoff" ''
      set -euo pipefail

      if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
        echo "cc-handoff: not inside a git repo" >&2
        exit 1
      fi

      repo_root="$(git rev-parse --show-toplevel)"
      handoff_dir="$repo_root/.claude"
      handoff_file="$handoff_dir/handoff.md"
      exclude_file="$repo_root/.git/info/exclude"

      mkdir -p "$handoff_dir"
      touch "$exclude_file"

      if ! grep -Fxq "/.claude/handoff.md" "$exclude_file"; then
        printf "/.claude/handoff.md\n" >> "$exclude_file"
      fi

      if [ ! -f "$handoff_file" ]; then
        cat > "$handoff_file" <<EOF
# Claude handoff

Updated: $(date -Iseconds)

## Current goal

## Done so far

## Files changed

## Key decisions

## Open questions / blockers

## Exact next steps

## Useful commands
EOF
      fi

      branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"

      printf "Handoff file: %s\n\n" "$handoff_file"
      printf "Branch: %s\n\n" "''${branch:-detached}"

      printf "Git status:\n"
      git -C "$repo_root" status --short || true

      printf "\nDiff stat:\n"
      git -C "$repo_root" diff --stat || true

      printf "\nNext step:\n"
      printf "Ask Claude to update %s before you switch profiles.\n" \
        "$handoff_file"
    '')
  ];

  # ==================== Symlinked configs (live editing, all hosts) ====================
  xdg.configFile."television".source = config.lib.file.mkOutOfStoreSymlink
    "${config.home.homeDirectory}/nix/nix-config/users/alc/configs/television";

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

  programs.neovim.enable = true;

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
        sopsFile = (
          assert builtins.pathExists "${inputs.nix-secrets}/hosts/${hostName}/secrets.yaml";
          "${inputs.nix-secrets}/hosts/${hostName}/secrets.yaml"
        );
        key = "ssh_id_ed25519";
        path = ".ssh/id_ed25519";
        mode = "0600";
      };
      "ssh.${hostName}.public" = {
        sopsFile = (
          assert builtins.pathExists "${inputs.nix-secrets}/hosts/${hostName}/secrets.yaml";
          "${inputs.nix-secrets}/hosts/${hostName}/secrets.yaml"
        );
        key = "ssh_id_ed25519.pub";
        path = ".ssh/id_ed25519.pub";
        mode = "0644";
      };
    };
  };

  # Generate and manage the age key file
  home.activation.setupSopsAgeKey = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p $HOME/.config/sops/age
    if [ ! -f "$HOME/.config/sops/age/keys.txt" ]; then
      ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key < $HOME/.ssh/id_ed25519 > $HOME/.config/sops/age/keys.txt
      chmod 600 $HOME/.config/sops/age/keys.txt
    fi
  '';

  home.activation.claudeProfileDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.claude-personal" "$HOME/.claude-work"
  '';

}
