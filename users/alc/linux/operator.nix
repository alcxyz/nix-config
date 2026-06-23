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

  sops.secrets.paperless_crm_docs_api_token = {
    sopsFile = inputs.nix-secrets.secrets.files.apps;
    key = "paperless_crm_docs_api_token";
  };

  home.sessionVariables.PAPERLESS_DEV_URL = "https://arq.dev.alc.xyz";
  home.sessionVariables.PAPERLESS_DEV_ENV = "dev";
  home.sessionVariables.PAPERLESS_DEV_API_TOKEN_FILE = config.sops.secrets.paperless_dev_api_token.path;
  home.sessionVariables.PAPERLESS_CRM_DOCS_URL = "https://crm-docs.alc.xyz";
  home.sessionVariables.PAPERLESS_CRM_DOCS_ENV = "crm-docs";
  home.sessionVariables.PAPERLESS_CRM_DOCS_API_TOKEN_FILE =
    config.sops.secrets.paperless_crm_docs_api_token.path;
  home.sessionVariables.PAPERLESS_AI_URL = "https://crm-docs.alc.xyz";
  home.sessionVariables.PAPERLESS_AI_ENV = "crm-docs";
  home.sessionVariables.PAPERLESS_AI_API_TOKEN_FILE =
    config.sops.secrets.paperless_crm_docs_api_token.path;

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
      export VISMA_API_URL="https://eaccountingapi.vismaonline.com/v2"
      export VISMA_AUTH_URL="https://identity.vismaonline.com/connect/authorize"
      export VISMA_TOKEN_URL="https://identity.vismaonline.com/connect/token"
      export VISMA_SCOPES="ea:api ea:sales ea:purchase ea:accounting offline_access"
      export VISMA_CLIENT_ID_FILE="''${VISMA_SANDBOX_CLIENT_ID_FILE:-$HOME/.config/sops-nix/secrets/visma_sandbox_client_id}"
      export VISMA_CLIENT_SECRET_FILE="''${VISMA_SANDBOX_CLIENT_SECRET_FILE:-$HOME/.config/sops-nix/secrets/visma_sandbox_client_secret}"
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

    [paperless]
    default_instance = "arq"

    [paperless.instances.arq]
    url = "https://arq.alc.xyz"
    api_token_file = "${config.sops.secrets.paperless_api_token.path}"

    [paperless.instances."crm-docs"]
    url = "https://crm-docs.alc.xyz"
    api_token_file = "${config.sops.secrets.paperless_crm_docs_api_token.path}"
  '';
}
