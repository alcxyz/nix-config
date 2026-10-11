{lib, ...}: {
  options.alc.shell = {
    default = lib.mkOption {
      type = lib.types.enum [
        "zsh"
        "bash"
        "xonsh"
      ];
      default = "zsh";
      description = "Default interactive login shell for the primary user.";
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
