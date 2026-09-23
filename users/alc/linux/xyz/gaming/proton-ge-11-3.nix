{pkgs}:
# Keep standalone launchers on the release used for gameplay qualification.
(pkgs.proton-ge-bin.overrideAttrs (finalAttrs: _: {
  version = "GE-Proton11-3";
  # This release predates architecture suffixes in compatibilitytool.vdf.
  toolName = finalAttrs.version;
  src = pkgs.fetchzip {
    url = "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${finalAttrs.version}/${finalAttrs.version}.tar.gz";
    hash = "sha256-RiCmnUKeZRhPUCgm7fsROKFkAl37+/tYkA47tQtkIF4=";
  };
})).steamcompattool
