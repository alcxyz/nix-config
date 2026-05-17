{python3Packages}:
python3Packages.buildPythonApplication {
  pname = "stashdb-acquisition-list";
  version = "0.1.0";
  pyproject = false;

  src = ./.;

  installPhase = ''
    runHook preInstall

    install -Dm755 stashdb-acquisition-list.py \
      "$out/bin/stashdb-acquisition-list"

    runHook postInstall
  '';
}
