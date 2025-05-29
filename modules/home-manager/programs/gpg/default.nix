# modules/home-manager/programs/gpg/default.nix
{ lib, config, pkgs, ... }:

with lib;

let
  # cfg refers to the options defined by this module,
  # specifically under config.programs.gpg.managed
  cfg = config.programs.gpg.managed;
in
{
  options.programs.gpg.managed = {
    enable = mkEnableOption "a managed GPG and GPG Agent setup";

    # Options that would normally go into programs.gpg
    /*
    defaultKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Default GPG key ID to use for signing.";
      example = "0xDEADBEEFDEADBEEF";
    };
    */
    # You could expose other programs.gpg options here if you want your
    # module to control them (e.g., homedir, mutableKeys).
    # For now, we'll assume the standard programs.gpg.homedir is sufficient.

    # Options for configuring services.gpg-agent
    agent = {
      # services.gpg-agent.enable will be true if programs.gpg.managed.enable is true.
      # No separate agent.enable is strictly needed here unless you want to allow
      # disabling the agent even when programs.gpg.managed.enable is true,
      # which might be unusual for a "managed" setup.

      enableSshSupport = mkEnableOption "SSH agent support via GPG Agent";

      pinentryPackage = mkOption {
        type = types.nullOr types.package;
        default = null; # Crucial: User MUST specify this for pinentry.
        description = ''
          The pinentry package to use for gpg-agent. This is required for
          gpg-agent to prompt for passphrases.
        '';
        example = lib.literalExpression "pkgs.pinentry_mac"; # For macOS
        # example = lib.literalExpression "pkgs.pinentry-qt"; # For Linux/Qt
      };

      defaultCacheTtl = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Set the time a cache entry is valid (seconds).";
      };

      maxCacheTtl = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Set the maximum time a cache entry is valid (seconds).";
      };

      # You can add other services.gpg-agent options here if you want to control them
      # through your managed module, for example:
      # defaultCacheTtlSsh = mkOption { type = types.nullOr types.int; default = null; };
      # maxCacheTtlSsh = mkOption { type = types.nullOr types.int; default = null; };
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra raw lines to add to gpg-agent.conf.";
        example = ''
          ignore-cache-for-signing
          allow-loopback-pinentry
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # 1. Enable and configure the standard Home Manager GPG program module.
    # This is essential as it handles:
    #   - Adding the gnupg package (config.programs.gpg.package) to home.packages.
    #   - Setting up the GNUPGHOME environment variable.
    #   - Managing the main gpg.conf file.
    programs.gpg = {
      enable = true;
      #defaultKey = cfg.defaultKey;
      # If you added other options like programs.gpg.homedir to your
      # managed options, you would set them here:
      # homedir = cfg.homedir;
    };

    # 2. Enable and configure the GPG agent service using settings
    #    from this managed module.
    services.gpg-agent = {
      enable = true; # The agent is enabled if the managed gpg setup is enabled.
      enableSshSupport = cfg.agent.enableSshSupport;
      defaultCacheTtl = cfg.agent.defaultCacheTtl;
      maxCacheTtl = cfg.agent.maxCacheTtl;
      extraConfig = cfg.agent.extraConfig;
      # defaultCacheTtlSsh = cfg.agent.defaultCacheTtlSsh; # If you added this option
      # maxCacheTtlSsh = cfg.agent.maxCacheTtlSsh;       # If you added this option

      # Configure pinentry using the correct structure.
      # This section is only included if a pinentryPackage is actually specified.
      pinentry = mkIf (cfg.agent.pinentryPackage != null) {
        package = cfg.agent.pinentryPackage;
        # The 'program' executable name is usually derived automatically by the
        # services.gpg-agent module from the package's meta.mainProgram.
        # So, explicit setting of 'program' is often not needed here.
      };
    };
  };
}
