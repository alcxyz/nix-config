# modules/nixos/virtualisation/kvm/default.nix
#
# General KVM/libvirtd setup — no GPU passthrough logic.
# Works for any VM (Linux, Windows, dev environments).
{
  config,
  pkgs,
  lib,
  username,
  ...
}:
with lib; let
  cfg = config.virtualisation.kvm.managed;
in {
  options.virtualisation.kvm.managed = {
    enable = mkEnableOption "KVM/QEMU virtualisation with libvirtd";

    storagePoolPath = mkOption {
      type = types.str;
      default = "/ypool/vault/vm";
      description = "Path for the libvirt storage pool.";
    };

    isoPath = mkOption {
      type = types.str;
      default = "/ypool/vault/isos";
      description = "Path for ISO images.";
    };
  };

  config = mkIf cfg.enable {
    boot.kernelModules = ["kvm-amd"];

    virtualisation.libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        runAsRoot = true;
        swtpm.enable = true;
        verbatimConfig = ''
          security_driver = "none"
          memory_backing_dir = "/dev/shm"
        '';
        vhostUserPackages = [pkgs.virtiofsd];
      };
    };

    environment.systemPackages = with pkgs; [
      virt-manager
      guestfs-tools
      libvirt
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.storagePoolPath} 0770 root media - -"
      "d ${cfg.isoPath} 0770 root media - -"
    ];

    users.users.${username}.extraGroups = [
      "libvirtd"
      "kvm"
    ];

    # Declaratively define libvirt storage pool
    systemd.services."libvirt-pool-vm" = {
      description = "Define and start the VM libvirt storage pool";
      path = [pkgs.libvirt];
      requires = ["libvirtd.service"];
      after = ["libvirtd.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -e
        POOL_NAME="vm_storage"
        POOL_PATH="${cfg.storagePoolPath}"

        virsh_cmd() {
          virsh --connect qemu:///system "$@"
        }

        define_pool() {
          virsh_cmd pool-define /dev/stdin <<EOF
            <pool type='dir'>
              <name>$POOL_NAME</name>
              <target>
                <path>$POOL_PATH</path>
              </target>
            </pool>
        EOF
        }

        if virsh_cmd pool-list --all --name | grep -Fxq "$POOL_NAME"; then
          CURRENT_PATH="$(virsh_cmd pool-dumpxml "$POOL_NAME" | sed -n "s:.*<path>\\(.*\\)</path>.*:\\1:p" | head -n1)"
          if [ "$CURRENT_PATH" != "$POOL_PATH" ]; then
            if virsh_cmd pool-list --name | grep -Fxq "$POOL_NAME"; then
              echo "libvirt pool $POOL_NAME points at $CURRENT_PATH, expected $POOL_PATH, but it is active; refusing to redefine" >&2
              exit 1
            fi

            virsh_cmd pool-autostart --disable "$POOL_NAME" || true
            virsh_cmd pool-undefine "$POOL_NAME"
            define_pool
          fi
        else
          define_pool
        fi

        if virsh_cmd pool-list --inactive --name | grep -Fxq "$POOL_NAME"; then
          virsh_cmd pool-start "$POOL_NAME"
        fi

        virsh_cmd pool-autostart "$POOL_NAME"
      '';
    };
  };
}
