{pkgs, ...}:
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    treefmt

    alejandra
    # python310Packages.mdformat # Commented out
    shfmt
  ];
}
