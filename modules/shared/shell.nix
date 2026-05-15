{lib, ...}: {
  options.alc.shell = {
    default = lib.mkOption {
      type = lib.types.enum [
        "nu"
        "nushell"
        "zsh"
        "bash"
        "xonsh"
      ];
      default = "nu";
      description = "Default interactive login shell for the primary user.";
    };

    enableNushell = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Nushell and its interactive integrations.";
    };

    enableZsh = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Zsh and its interactive integrations.";
    };

    enableBash = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Bash and its interactive integrations.";
    };

    enableXonsh = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Xonsh and its interactive integrations.";
    };

    enableXonshCarapace = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable experimental Carapace completion integration for Xonsh.";
    };
  };
}
