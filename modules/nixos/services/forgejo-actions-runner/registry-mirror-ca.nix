# Start-time setup of an engine's per-host certs.d: the module owns the whole
# directory, so it is rebuilt with only the mirror CA, or left empty when
# registryMirrorCaFile is null.
{
  cfg,
  lib,
  pkgs,
}: name: certsDir:
pkgs.writeShellScript name ''
  set -euo pipefail
  ${pkgs.coreutils}/bin/rm -rf -- ${lib.escapeShellArg certsDir}
  ${lib.optionalString (cfg.registryMirrorCaFile != null) ''
    ${pkgs.coreutils}/bin/install -D -m 0644 ${lib.escapeShellArg "${cfg.registryMirrorCaFile}"} \
      ${lib.escapeShellArg "${certsDir}/${cfg.registryMirror}/ca.crt"}
  ''}
''
