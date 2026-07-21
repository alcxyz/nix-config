{
  python3,
  writeShellApplication,
}:
writeShellApplication {
  name = "reportcraft";
  runtimeInputs = [python3];
  text = ''
    export REPORTCRAFT_TEMPLATE=${./templates/report.html}
    exec python3 ${./reportcraft.py} "$@"
  '';
  meta = {
    description = "Create and serve self-contained HTML presentation reports";
    mainProgram = "reportcraft";
  };
}
