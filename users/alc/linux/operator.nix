{
  config,
  configDir,
  inputs,
  ...
}:
{
  imports = [
    inputs.nix-secrets.homeManagerModules.linuxOperator
  ];

  xdg.configFile."paperweight/config.toml".text = ''
    accounts_toml_path = "${config.programs.workspace.root}/platform/regnskap/cmd/bokfor/accounts.toml"
  '';
}
