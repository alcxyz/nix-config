# My Declarative System: Setup & Bootstrapping Guide

This repository contains the complete declarative configuration for my NixOS and macOS systems. It uses [Nix Flakes](https://nixos.wiki/wiki/Flakes) to manage system packages, services, and user dotfiles via [Home Manager](https://github.com/nix-community/home-manager).

## Philosophy & Key Management

The core principle is a strict separation of public configuration from private secrets. This setup uses two distinct types of SSH keys for a flexible and secure workflow:

| Key Type | Description | Where It Lives | How It's Used |
| :--- | :--- | :--- | :--- |
| **Host-Specific Key** | A standard SSH key pair unique to each machine (`xyz`, `mac`, etc.). | Private key is stored in `gopass`, deployed to `~/.ssh/id_ed25519` on the host. | Day-to-day `git` operations. Works without the YubiKey present. |
| **YubiKey PIV Key** | A high-security key that **cannot leave the YubiKey**. | Private key is in the YubiKey's PIV hardware module. | Authenticating to critical services (GitHub, production servers). Requires the YubiKey to be plugged in and touched. |

The system is configured so that SSH automatically uses the correct key for the situation.

---

## Part 1: The Foundation (One-Time Setup)

This section covers the one-time process of creating the GPG key on the YubiKey, setting up the `gopass` secret store, and configuring the YubiKey's PIV function for direct SSH access.

### 1.1. Generating the GPG Key on the YubiKey

*(This section is preserved from your original README)*

This process ensures the private key is generated on the YubiKey's secure chip and can never be extracted.

**Prerequisites:** A computer with `gnupg` and `yubikey-manager` installed.

1.  **Reset the YubiKey's OpenPGP Applet:**
    ```bash
    ykman openpgp reset
    ```

2.  **Set New PINs:** The defaults are `123456` (PIN) and `12345678` (Admin PIN). Change them immediately.
    ```bash
    gpg --change-pin
    ```

3.  **Generate the Keys:**
    ```bash
    gpg --expert --full-generate-key
    ```
    *   Choose `(10) ECC (sign and encrypt)` or `(1) RSA and RSA`.
    *   Set an expiration date (e.g., `2y`).
    *   Enter your name and email.
    *   Enter your Admin PIN and User PIN when prompted.

4.  **Get Your Key ID:** This is your primary GPG identifier.
    ```bash
    gpg --list-secret-keys
    ```
    Find the `sec>` line corresponding to your YubiKey (it will have a `Card serial no.`). The long hexadecimal string (e.g., `0x0385794DEDBC06E6`) is your **Key ID**. Save this somewhere safe.

### 1.2. Initializing the `gopass` Secret Store

*(This section is preserved from your original README)*

This creates the encrypted Git repository for your secrets.

1.  **Initialize `gopass`:** On a trusted machine, run the init command, replacing `<YOUR_KEY_ID>` with the ID from the previous step.
    ```bash
    gopass init <YOUR_KEY_ID>
    ```

2.  **Connect to a Remote Git Repo:**
    *   Create a new, **private** repository on GitHub/GitLab (e.g., `my-secrets`).
    *   Navigate to your new password store and link it to the remote. Modern `gopass` uses the XDG path.
        ```bash
        cd ~/.local/share/gopass/stores/root
        git remote add origin git@github.com:your-username/my-secrets.git
        gopass git push --set-upstream origin main
        ```

3.  **Add Your Host-Specific SSH Keys to `gopass`:** For each host, add its SSH private and public keys to the store. The path inside `gopass` is important, as our Nix module expects the `ssh/` prefix.
    ```bash
    # For host 'xyz'
    gopass insert -m ssh/xyz_id_ed25519 < ~/.ssh/xyz_id_ed25519
    gopass insert ssh/xyz_id_ed25519.pub < ~/.ssh/xyz_id_ed25519.pub

    # For host 'mac'
    gopass insert -m ssh/mac_id_ed25519 < ~/.ssh/mac_id_ed25519
    gopass insert ssh/mac_id_ed25519.pub < ~/.ssh/mac_id_ed25519.pub
    ```

### 1.3. Setting up the YubiKey for Direct SSH (PIV)

This configures the YubiKey's hardware key for direct use with SSH, bypassing the GPG agent entirely.

1.  **Ensure `yubico-piv-tool` is installed.** Our Nix configuration automatically installs this via `environment.systemPackages`.

2.  **Get the PIV Public Key.** The easiest and most reliable way to get the public key is to ask the SSH agent, which can see the key thanks to our configuration.
    *   Plug in your YubiKey.
    *   Open a **new terminal** to ensure the SSH config is loaded.
    *   Run the command:
        ```bash
        ssh-add -L
        ```
    *   The output will list all available keys. Copy the line that starts with `ecdsa-sha2-nistp256` and references your card number. This is your YubiKey's SSH public key.

3.  **Add the Public Key to Services.** Add the copied public key to GitHub, GitLab, and any servers you want to access with your YubiKey.

---

## Part 2: The Automation (How Keys are Managed)

***(This section is expanded from your original)***

### 2.1. Host-Specific Keys (via `gopass`)

This configuration uses a custom Home Manager module (`modules/home-manager/secrets/ssh-keys.nix`) to deploy secrets.

*   The module defines a `secrets.ssh.keyPair` option.
*   In each host-specific Home Manager configuration (`home-linux.nix`, `home-darwin.nix`), we enable this option and specify the `baseName` of the key to deploy from `gopass`.
*   During a rebuild, if `~/.ssh/id_ed25519` doesn't exist, an activation script runs `gopass show ...` to fetch the secret, triggering a YubiKey PIN prompt, and places the key in `~/.ssh/` with the correct permissions.

### 2.2. YubiKey PIV Key (via `PKCS11Provider`)

The SSH configuration (`modules/home-manager/programs/ssh/default.nix`) contains a critical line:
```nix
extraConfig = ''
  PKCS11Provider ${pkcs11ProviderPath}
  ...
'';
```
This tells the entire OpenSSH suite (`ssh`, `ssh-agent`, `ssh-add`) to communicate directly with the YubiKey's PIV applet using the standard PKCS#11 library. This is the "magic" that makes `ssh-add -L` and direct SSH access work automatically without any GPG agent involvement.

---

## Part 3: Bootstrapping a New Machine

*(This section is preserved from your original README, as its steps are correct and lead into the automated setup)*

This is the practical workflow for setting up a new computer from scratch.

### 3.1. Bootstrapping a New NixOS Machine

1.  **Install NixOS:** Perform a minimal NixOS installation.
2.  **Clone This Repository:** `git clone https://github.com/your-username/your-nix-config.git /mnt/etc/nixos`
3.  **Initial Build:** Run `sudo nixos-rebuild switch --flake /mnt/etc/nixos#<hostname>`. This installs all tools (`gopass`, etc.). **The secret deployment will fail gracefully; this is expected.**
4.  **Log in and Clone Secrets:** Reboot, log in as your user. Clone your encrypted `gopass` store.
    ```bash
    git clone git@github.com:your-username/my-secrets.git ~/.local/share/gopass/stores/root
    ```
5.  **Final Build:** Run `sudo nixos-rebuild switch --flake .#<hostname>` again. This time, it will find the `gopass` store, prompt for your YubiKey PIN, and deploy your SSH keys.

### 3.2. Bootstrapping a New macOS Machine

1.  **Install Nix & Homebrew:** Follow the official guides.
2.  **Clone This Repository:** `git clone https://github.com/your-username/your-nix-config.git ~/nix-config`
3.  **Initial Build:** Run `darwin-rebuild switch --flake .#mac`. This installs the tools. **The secret deployment will fail gracefully; this is expected.**

4.  **GPG Keyring Bootstrap:** The new Mac knows nothing about your GPG identity. You must introduce it.
    *   **A. Export Public Key:** On a trusted machine, export your public key.
        ```bash
        gpg --export --armor <YOUR_KEY_ID> > ~/my-public-key.asc
        ```
    *   **B. Transfer and Import:** Copy `my-public-key.asc` to your Mac and import it.
        ```bash
        # On the Mac
        gpg --import ~/my-public-key.asc
        ```
    *   **C. Set Ultimate Trust:** Tell GPG to trust this key.
        ```bash
        # On the Mac
        gpg --edit-key <YOUR_KEY_ID>
        ```
        In the prompt, type `trust`, select `5` (I trust ultimately), confirm with `y`, and `quit`.
    *   **D. Link to YubiKey:** Force GPG to scan for the hardware and link it to the key you just trusted.
        ```bash
        # On the Mac, with YubiKey plugged in
        gpg --card-status
        ```
        This command makes the connection. You can verify with `gpg --list-secret-keys`, which should now show your YubiKey.

5.  **Clone Secrets Store:** Now that GPG is ready, clone your encrypted `gopass` store.
    ```bash
    git clone git@github.com:your-username/my-secrets.git ~/.local/share/gopass/stores/root
    ```

6.  **Final Build:** Run the rebuild again. This is the final step that brings everything together.
    ```bash
    # On the Mac
    darwin-rebuild switch --flake .#mac
    ```
    This run will find the `gopass` store, trigger the YubiKey PIN prompt via the native macOS `pinentry` window, and deploy your SSH keys.

Your new machine is now fully configured and secure.
