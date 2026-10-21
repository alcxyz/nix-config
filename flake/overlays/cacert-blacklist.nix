{lib}: _final: prev:
lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
  # buildcatrust 0.5.1 retains blacklisted certificates as rejected OpenSSL
  # entries. Omit them from every output instead, including the plain bundle
  # and p11-kit. Keep the default, uncustomized cacert derivation unchanged.
  # Remove with the emSign workaround:
  # https://git.alc.xyz/alcxyz/nix-config/issues/775
  cacert = lib.makeOverridable (args: let
    cacert = prev.cacert.override args;
  in
    if (args.blacklist or []) == []
    then cacert
    else
      (prev.cacert.override (args
        // {
          buildcatrust = prev.buildcatrust.overridePythonAttrs (old: {
            patches = (old.patches or []) ++ [./buildcatrust-omit-blocklisted.patch];
          });
        }))
      .overrideAttrs (old: {
        buildPhase = assert lib.hasInfix "--blocklist " old.buildPhase;
          builtins.replaceStrings
          ["--blocklist "]
          ["--omit-blocklisted --blocklist "]
          old.buildPhase;
      })) {};
}
