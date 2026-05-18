# nix-config/modules/nixos/services/flatpak/default.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.flatpak.managed;
in {
  options.services.flatpak.managed = {
    enable = lib.mkEnableOption "declarative system Flatpak installation";

    remotes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        flathub = "https://dl.flathub.org/repo/flathub.flatpakrepo";
      };
      description = "Flatpak remotes to ensure on the system installation.";
    };

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Flatpak application IDs to ensure are installed from Flathub.";
    };

    overrides = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      description = "System Flatpak override arguments keyed by application ID.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.flatpak.enable = true;

    systemd.services.flatpak-managed = {
      description = "Ensure declarative Flatpak applications";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.flatpak];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: url: "flatpak remote-add --system --if-not-exists ${lib.escapeShellArg name} ${lib.escapeShellArg url}"
          )
          cfg.remotes
        )}

        ${lib.concatMapStringsSep "\n" (
            app: "flatpak install --system --noninteractive flathub ${lib.escapeShellArg app}"
          )
          cfg.packages}

        ${lib.concatMapStringsSep "\n" (
            app: "flatpak override --system ${lib.concatMapStringsSep " " lib.escapeShellArg cfg.overrides.${app}} ${lib.escapeShellArg app}"
          )
          (lib.attrNames cfg.overrides)}
      '';
    };
  };
}
