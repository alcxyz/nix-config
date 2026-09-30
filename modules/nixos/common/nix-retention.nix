{lib, ...}: {
  options.alc.nix.keepGenerations = lib.mkOption {
    type = lib.types.ints.positive;
    default = 10;
    description = ''
      Generations kept per profile by guarded retention; pruning triggers
      above twice this count or on low free space (ADR-0013).
    '';
  };
}
