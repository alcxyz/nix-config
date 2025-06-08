{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.secrets.ssh;
in
{
  options.secrets.ssh = {
    privateKey = {
      enable = mkEnableOption "Deploy a specific SSH private key from gopass";

      gopassPath = mkOption {
        type = types.str;
        description = "The path to the secret within gopass (e.g., 'ssh/xyz_id_ed25519').";
      };

      fileName = mkOption {
        type = types.str;
        default = "id_ed25519";
        description = "The name of the file to create in ~/.ssh/";
      };
    };

    publicKey = {
      enable = mkEnableOption "Deploy a specific SSH public key from gopass";

      gopassPath = mkOption {
        type = types.str;
        description = "The path to the public key within gopass (e.g., 'ssh/xyz_id_ed25519.pub').";
      };

      fileName = mkOption {
        type = types.str;
        default = "id_ed25519.pub";
        description = "The name of the public key file to create in ~/.ssh/";
      };
    };

    keyPair = {
      enable = mkEnableOption "Deploy both private and public SSH keys from gopass";

      baseName = mkOption {
        type = types.str;
        description = "Base name for the key pair (e.g., 'xyz_id_ed25519' will look for 'ssh/xyz_id_ed25519' and 'ssh/xyz_id_ed25519.pub')";
      };

      privateFileName = mkOption {
        type = types.str;
        default = "id_ed25519";
        description = "The name of the private key file to create in ~/.ssh/";
      };

      publicFileName = mkOption {
        type = types.str;
        default = "id_ed25519.pub";
        description = "The name of the public key file to create in ~/.ssh/";
      };

      forceRefresh = mkOption {
        type = types.bool;
        default = false;
        description = "Force refresh keys from gopass even if they already exist locally";
      };
    };
  };

  config = mkMerge [
    # Handle individual private key deployment
    (mkIf cfg.privateKey.enable {
      home.activation.provision-ssh-private-key = lib.hm.dag.entryAfter ["writeBoundary"] ''
        mkdir -p -m 700 "$HOME/.ssh"
        
        if [[ ! -f "$HOME/.ssh/${cfg.privateKey.fileName}" ]]; then
          echo "Deploying SSH private key from gopass..."
          ${pkgs.gopass}/bin/gopass show "${cfg.privateKey.gopassPath}" > "$HOME/.ssh/${cfg.privateKey.fileName}"
          chmod 600 "$HOME/.ssh/${cfg.privateKey.fileName}"
          echo "✓ Deployed SSH private key to ~/.ssh/${cfg.privateKey.fileName}"
        else
          echo "✓ SSH private key ~/.ssh/${cfg.privateKey.fileName} already exists, skipping gopass fetch"
          # Ensure correct permissions even if file exists
          chmod 600 "$HOME/.ssh/${cfg.privateKey.fileName}"
        fi
      '';
    })

    # Handle individual public key deployment
    (mkIf cfg.publicKey.enable {
      home.activation.provision-ssh-public-key = lib.hm.dag.entryAfter ["writeBoundary"] ''
        mkdir -p -m 700 "$HOME/.ssh"
        
        if [[ ! -f "$HOME/.ssh/${cfg.publicKey.fileName}" ]]; then
          echo "Deploying SSH public key from gopass..."
          ${pkgs.gopass}/bin/gopass show "${cfg.publicKey.gopassPath}" > "$HOME/.ssh/${cfg.publicKey.fileName}"
          chmod 644 "$HOME/.ssh/${cfg.publicKey.fileName}"
          echo "✓ Deployed SSH public key to ~/.ssh/${cfg.publicKey.fileName}"
        else
          echo "✓ SSH public key ~/.ssh/${cfg.publicKey.fileName} already exists, skipping gopass fetch"
          # Ensure correct permissions even if file exists
          chmod 644 "$HOME/.ssh/${cfg.publicKey.fileName}"
        fi
      '';
    })

    # Handle key pair deployment (convenience option)
    (mkIf cfg.keyPair.enable {
      home.activation.provision-ssh-key-pair = lib.hm.dag.entryAfter ["writeBoundary"] ''
        mkdir -p -m 700 "$HOME/.ssh"
        
        PRIVATE_KEY_PATH="$HOME/.ssh/${cfg.keyPair.privateFileName}"
        PUBLIC_KEY_PATH="$HOME/.ssh/${cfg.keyPair.publicFileName}"
        FORCE_REFRESH="${if cfg.keyPair.forceRefresh then "true" else "false"}"
        
        # Function to deploy private key
        deploy_private_key() {
          echo "Deploying SSH private key from gopass..."
          ${pkgs.gopass}/bin/gopass show "ssh/${cfg.keyPair.baseName}" > "$PRIVATE_KEY_PATH"
          chmod 600 "$PRIVATE_KEY_PATH"
          echo "✓ Deployed SSH private key to $PRIVATE_KEY_PATH"
        }
        
        # Function to deploy public key
        deploy_public_key() {
          echo "Deploying SSH public key from gopass..."
          ${pkgs.gopass}/bin/gopass show "ssh/${cfg.keyPair.baseName}.pub" > "$PUBLIC_KEY_PATH"
          chmod 644 "$PUBLIC_KEY_PATH"
          echo "✓ Deployed SSH public key to $PUBLIC_KEY_PATH"
        }
        
        # Deploy private key (if needed or forced)
        if [[ "$FORCE_REFRESH" == "true" ]] || [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
          deploy_private_key
        else
          echo "✓ SSH private key $PRIVATE_KEY_PATH already exists, skipping gopass fetch"
          chmod 600 "$PRIVATE_KEY_PATH"  # Ensure correct permissions
        fi

	# Load private key into SSH agent (if agent is running)
        if [[ -n "$SSH_AUTH_SOCK" ]] && command -v ssh-add >/dev/null 2>&1; then
          echo "Adding SSH key to agent..."
          ssh-add "$PRIVATE_KEY_PATH" 2>/dev/null || echo "Note: Could not add key to SSH agent (agent may not be running)"
        fi
        
        # Deploy public key (if needed or forced)
        if [[ "$FORCE_REFRESH" == "true" ]] || [[ ! -f "$PUBLIC_KEY_PATH" ]]; then
          deploy_public_key
        else
          echo "✓ SSH public key $PUBLIC_KEY_PATH already exists, skipping gopass fetch"
          chmod 644 "$PUBLIC_KEY_PATH"  # Ensure correct permissions
        fi
        
        echo "✓ SSH key pair '${cfg.keyPair.baseName}' deployment complete"
      '';
    })
  ];
}
