{
  config,
  configDir,
  inputs,
  pkgs,
  ...
}: {
  imports = [
    inputs.nix-secrets.homeManagerModules.linuxOperator
  ];

  sops.secrets.paperless_dev_api_token = {
    sopsFile = inputs.nix-secrets.secrets.files.apps;
    key = "paperless_dev_api_token";
  };

  home.sessionVariables.PAPERLESS_DEV_URL = "https://arq.dev.alc.xyz";
  home.sessionVariables.PAPERLESS_DEV_ENV = "dev";
  home.sessionVariables.PAPERLESS_DEV_API_TOKEN_FILE = config.sops.secrets.paperless_dev_api_token.path;

  home.file.".local/bin/bokfor-dev" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      repo="''${BOKFOR_REPO:-$HOME/src/platform/regnskap}"
      gitops="''${GITOPS_REPO:-$HOME/src/infra/gitops}"
      configmap="$gitops/k8s/apps/bokfor-admin-dev/configmap-files.yaml"
      accounts_toml="$(mktemp)"
      dev_token_file="''${PAPERLESS_DEV_API_TOKEN_FILE:-$HOME/.config/sops-nix/secrets/paperless_dev_api_token}"
      trap 'rm -f "$accounts_toml"' EXIT

      ${pkgs.yq-go}/bin/yq -r '.data["accounts.toml"]' "$configmap" > "$accounts_toml"

      export VISMA_ENV="sandbox"
      export VISMA_CONFIG="$accounts_toml"
      export PAPERLESS_URL="''${PAPERLESS_DEV_URL:-https://arq.dev.alc.xyz}"
      export PAPERLESS_ENV="''${PAPERLESS_DEV_ENV:-dev}"
      export PAPERLESS_API_TOKEN_FILE="$dev_token_file"
      unset PAPERLESS_API_TOKEN

      if [ -n "''${BOKFOR_BINARY:-}" ]; then
        exec "$BOKFOR_BINARY" "$@"
      fi
      cd "$repo"
      exec ${pkgs.go}/bin/go run ./cmd/bokfor "$@"
    '';
  };

  xdg.configFile."paperweight/config.toml".text = ''
    accounts_toml_path = "${config.programs.workspace.root}/platform/regnskap/cmd/bokfor/accounts.toml"
  '';
}
