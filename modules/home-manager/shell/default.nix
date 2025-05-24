{ config, lib, pkgs, ... }:

# Keep 'with lib;' as lib is often needed for Home Manager configurations
with lib;

{
  # ========================================================================
  # 1. Core Packages for the Shell Environment
  #
  # These packages are installed directly into the user's profile
  # and are available for use in the shell.
  # ========================================================================
  home.packages = with pkgs; [
    # Ensure Nushell itself is installed for the user as the primary shell
    nushell

    # Essential shell tools and utilities
    zoxide        # Fast directory jumper
    starship      # Cross-shell prompt
    carapace    # Multi-shell completion
    atuin         # Sync, searchable shell history
    direnv        # Load and unload environment variables based on directory

    # Add any other fundamental shell utilities needed here.
    # Example: tools used by your aliases if not installed elsewhere.
    # If you use 'nitch' or 'clipboard' and they aren't pulled in by
    # other modules, consider adding them here:
    # nitch
    # wl-clipboard # For Wayland clipboard support often used by 'clipboard' command
    # xclip        # For X11 clipboard support
  ];

  # ========================================================================
  # 2. Home Manager Program Configurations
  #
  # Configure specific shell-related programs using Home Manager's modules.
  # These modules often handle shell integration automatically.
  # ========================================================================
  programs = {
    # Starship prompt configuration
    starship = {
      enable = true;
      # Enable Nushell integration for Starship.
      enableNushellIntegration = true;
      # The actual starship.toml configuration file is linked below via xdg.configFile
    };

    # Zoxide configuration
    zoxide = {
      enable = true;
      # Enable Nushell integration for Zoxide. This usually sets up the 'z' function.
      enableNushellIntegration = true;
    };

    # Carapace completion configuration
    carapace = {
      enable = true;
      # Enable Nushell integration for Carapace.
      enableNushellIntegration = true;
      # This integration typically handles sourcing the init script.
      # If you manually source it in extraConfig, it might be redundant.
    };

    # Atuin history configuration
    atuin = {
      enable = true;
      # Enable Nushell integration for Atuin.
      enableNushellIntegration = true;
      daemon.enable = true;
    };

    # Direnv configuration
    direnv = {
      enable = true;
      # Enable Nushell integration for Direnv.
      # Home Manager's module usually adds the necessary 'direnv hook nu' output
      # to your Nushell configuration automatically when this is enabled.
      enableNushellIntegration = true;
    };

    # Nushell specific configuration
    # This section handles settings specific to Nushell itself, like aliases
    # *only* for Nushell, environment variables loaded by Nushell, and custom
    # config.nu content (functions, hooks, etc.).
    nushell = {
      enable = true; # Explicitly enable Nushell as the user's shell program

      # shellAliases here are only applied if Home Manager is setting up Nushell
      # AND you need aliases that are *strictly* only for Nushell or override
      # default Nushell commands. General aliases go in home.shellAliases below.
      shellAliases = {
        # Example: 'ls' in Nushell is often formatted differently.
        # If you wanted to alias 'ls' specifically *within* Nushell
        # to something else, you could do it here.
        # ls = "ls -aF"; # Example, not required as your general alias uses 'ls -all'
      };

      # Remove envFile.text if not used; it implies sourcing an external file.
      # envFile.text = "";

      # Environment variables to be set when Nushell starts.
      # Use `${config.home.homeDirectory}` for more robust pathing.
      environmentVariables = {
        KUBECONFIG = "${config.home.homeDirectory}/.kube/config";
        # Add other Nushell-specific environment variables here.
      };

      # Extra configuration added to Nushell's config.nu.
      # This is the place for Nushell functions, keybindings, hooks,
      # and configuration options ($env.config).
      extraConfig = ''
        # Set Nushell configuration options
        $env.config = {
            show_banner: false,
            edit_mode: vi, # Enable Vi mode editing
        }

        # Explicitly add standard user binary paths to PATH.
        # While Nix manages paths well, some tools (like cargo install)
        # might place bins here. Consider managing these via Nix instead.
        $env.PATH = ($env.PATH | prepend $"($env.HOME)/.cargo/bin")
        # $env.PATH = ($env.PATH | prepend $"($env.HOME)/.local/bin") # Another common path

        # Define custom Nushell functions.
        # This function provides a shorthand for running nix shell.
        # Usage: , <package1> <package2> ...
        def , [...packages] {
            # Ensure packages are formatted correctly for 'nix shell'
            nix shell ($packages | each {|s| $"nixpkgs#($s)"})
        }

        # Source initialization scripts for integrated programs if
        # enableNushellIntegration is not sufficient or you need manual control.
        # Home Manager often handles this automatically for enabled programs.
        # If Carapace or Direnv integration feels incomplete, you might need
        # to source their hooks here.
        # Example if needed (check if enableNushellIntegration handles it first):
        # source ~/.config/carapace/init.nu
        # source ($env.HOME)/.config/nushell/direnv_hook.nu # direnv hook output destination

        # Add any other custom Nushell logic, prompts, or functions here.
      '';
    };
  };

  # ========================================================================
  # 3. XDG Base Directory Configuration
  #
  # Link configuration files respecting the XDG Base Directory Standard.
  # ========================================================================
  xdg.configFile."starship.toml" = {
    source = ./starship.toml;
    # The 'ensure' attribute defaults to true when 'source' is used,
    # meaning Home Manager will create the parent directory if needed.
  };

  # Add other config files you manage locally here.
  # Example: if you had custom Nushell keybindings or environment files:
  # xdg.configFile."nushell/env.nu".source = ./nushell/env.nu;
  # xdg.configFile."nushell/keybindings.nu".source = ./nushell/keybindings.nu;


  # ========================================================================
  # 4. General Shell Aliases
  #
  # These aliases are managed by Home Manager and configured in your
  # shell's startup files (like env.nu for Nushell). They work for basic
  # command mapping and are generally shell-agnostic, although the commands
  # they call must exist and behave as expected in the target shell.
  # ========================================================================
  home.shellAliases = {
    hmxyz = "home-manager switch --flake .#alc-xyz";
    hmmac = "home-manager switch --flake .#alc-mac";
    nixyz = "sudo nixos-rebuild switch --flake .#xyz";

    # Kubernetes aliases (Assuming 'kubectl' is in your PATH)
    k = "kubectl";
    ka = "kubectl apply -f";
    kg = "kubectl get";
    kd = "kubectl describe";
    kdel = "kubectl delete";
    kgpo = "kubectl get pod";
    kgd = "kubectl get deployments";
    kc = "switcher"; # Assumes 'switcher' tool is available
    kns = "switcher ns"; # Assumes 'switcher' tool is available
    kl = "kubectl logs -f";
    ke = "kubectl exec -it";

    # Terraform alias (Assuming 'terraform' is in your PATH)
    tf = "terraform";

    # Editor alias (Assuming 'nvim' is in your PATH)
    v = "nvim";

    # Docker alias (Assuming 'docker' is in your PATH)
    d = "docker";

    # Common navigation and listing aliases
    # Note: Nushell often has built-in commands or prefers piped commands
    # for complex output formatting (like 'ls | format -l'), but simple
    # aliases like 'l' for 'ls -all' work for brevity.
    l = "ls -all";
    ll = "ls -la";
    c = "clear";
    ".." = "cd .."; # Alias for changing to the parent directory
    # Override the built-in 'cd' command with zoxide's jump function.
    # This is a common pattern when using zoxide.
    cd = "z";

    # Git alias (Assuming 'lazygit' is in your PATH)
    g = "lazygit";

    # Tmux aliases (Assuming 'tmux' is in your PATH)
    t = "tmux";
    ta = "tmux a"; # Attach to the last session

    # Other general aliases
    neofetch = "nitch"; # Requires 'nitch' package to be available
    pbcopy = "clipboard copy"; # Requires a 'clipboard' command (e.g., from wl-clipboard/xclip wrappers)
    pbpaste = "clipboard paste"; # Requires a 'clipboard' command

    # Add any other general command aliases here.
    # Example: gs = "git status"
    gc = "git commit -m";
    gca = "git commit -am";
    gps = "git push";
    gpl = "git pull";
    gst = "git status";
    glog = "git log --graph --topo-order --pretty='%w(100,0,6)%C(yellow)%h%C(bold)%C(black)%d %C(cyan)%ar %C(green)%an%n%C(bold)%C(white)%s %N' --abbrev-commit";
  };

  # ========================================================================
  # 5. Module Metadata/Assumptions
  # ========================================================================
  # This module is designed for a user leveraging Nushell.
  # Assuming stateVersion is handled at a higher level in your config.
  # home.stateVersion = "YOUR_STATE_VERSION";
}

