{
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "nixbox-report";
  runtimeInputs = [python3];
  text = ''
    exec python3 ${./nixbox-report.py} "$@"
  '';
}
