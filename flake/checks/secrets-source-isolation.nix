# Fails when a configuration hands a path inside the nix-secrets source tree
# to sops or to a file it installs. A path inside that tree makes a generation
# depend on the whole private repository, so every commit there would give
# every host a new generation and copy the repository into its store
# (nix-secrets#286). Reference files through
# `inputs.nix-secrets.secrets.files`, which copies each file on its own.
#
# Checked: `sops.secrets.*.sopsFile`, `environment.etc.*.source` and
# `home.file.*.source` (which includes `xdg.configFile`), for standalone Home
# Manager configurations and for Home Manager users inside NixOS hosts. Other
# paths, such as a unit script that reads a file from the source, are not
# traced; these options are where secrets files enter configurations.
{
  lib,
  secretsSource,
  configurations,
}: let
  # Only the text is compared; matching rejects strings that carry store context.
  plain = builtins.unsafeDiscardStringContext;
  source = plain secretsSource;

  # Plain replacement instead of a regular expression, which can overflow on
  # long build scripts.
  contains = text: builtins.replaceStrings [source] [""] text != text;

  dependsOnSource = value: let
    path = plain (toString value);
  in
    (path == source)
    || lib.hasPrefix "${source}/" path
    # A derivation such as a Home Manager out-of-store symlink can embed the
    # path in its build instead of in its output path.
    || (lib.isDerivation value && contains (plain (builtins.toJSON value.drvAttrs)));

  sopsFiles = config:
    lib.mapAttrsToList (name: secret: {
      option = "sops.secrets.${name}.sopsFile";
      value = secret.sopsFile or null;
    }) (config.sops.secrets or {});

  fileSources = option: files:
    lib.mapAttrsToList (name: file: {
      option = "${option}.\"${name}\".source";
      value = file.source or null;
    })
    files;

  ownReferences = config:
    sopsFiles config
    ++ fileSources "environment.etc" (config.environment.etc or {})
    ++ fileSources "home.file" (config.home.file or {});

  references = config:
    ownReferences config
    ++ lib.concatLists (lib.mapAttrsToList (
        user: home:
          map (reference: reference // {option = "home-manager.users.${user}.${reference.option}";})
          (ownReferences home)
      )
      (config.home-manager.users or {}));

  offenders = kind: configs:
    lib.concatLists (lib.mapAttrsToList (
        name: configuration:
          map (reference: "${kind} ${name}: ${reference.option}")
          (lib.filter (reference: reference.value != null && dependsOnSource reference.value)
            (references configuration.config))
      )
      configs);

  found =
    offenders "nixos" configurations.nixos
    ++ offenders "home" configurations.home
    ++ offenders "darwin" configurations.darwin;
in
  if found == []
  then true
  else throw "configurations depend on the nix-secrets source; use inputs.nix-secrets.secrets.files: ${lib.concatStringsSep ", " found}"
