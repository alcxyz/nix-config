{lib, ...}: {
  options.alc.shell = {
    default = lib.mkOption {
      type = lib.types.enum [
        "zsh"
        "bash"
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
  };
}
