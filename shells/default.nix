{pkgs, ...}:
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    treefmt

    # alejandra # Commented out
    # python310Packages.mdformat # Commented out
    # shfmt # Commented out
  ];
}
