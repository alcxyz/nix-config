{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.security.credentialConsent;
  actionId = "xyz.alc.credentials.use-admin";
  ownerIdentities = lib.concatMapStringsSep " " (user: "unix-user:${lib.escapeXML user}") cfg.ownerUsers;
  actionPolicy = pkgs.writeTextDir "share/polkit-1/actions/${actionId}.policy" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE policyconfig PUBLIC
      "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
      "https://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
    <policyconfig>
      <vendor>alc.xyz</vendor>
      <vendor_url>https://alc.xyz/</vendor_url>
      <action id="${actionId}">
        <description>Use an administrative credential</description>
        <message>Authentication is required to approve this credential operation</message>
        <annotate key="org.freedesktop.policykit.owner">${ownerIdentities}</annotate>
        <defaults>
          <allow_any>no</allow_any>
          <allow_inactive>no</allow_inactive>
          <allow_active>auth_self</allow_active>
        </defaults>
      </action>
    </policyconfig>
  '';
  consentHelper = import ./helper.nix {
    inherit actionId lib pkgs;
    ownerUsers = cfg.ownerUsers;
    grepCommand = lib.getExe pkgs.gnugrep;
    idCommand = lib.getExe' pkgs.coreutils "id";
    pkcheckCommand = lib.getExe' pkgs.polkit "pkcheck";
    inherit (cfg) requesterCommand;
    remote =
      if cfg.remote.enable
      then {
        command = lib.getExe cfg.remote.package;
        inherit (cfg.remote) origin rpId publicKey credentialId timeoutSeconds spoolDir notifyCommand;
      }
      else null;
  };
  package = pkgs.symlinkJoin {
    name = "credential-consent";
    paths = [
      actionPolicy
      consentHelper
    ];
  };
in {
  options.security.credentialConsent = {
    enable = lib.mkEnableOption "interactive consent for administrative credential use";

    ownerUsers = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z_][a-z0-9_-]*[$]?");
      default = [];
      example = ["operator"];
      description = ''
        Local users trusted to attach the human-readable operation details to
        this Polkit action. Polkit requires action owners when an unprivileged
        caller supplies details.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = package;
      description = "The credential-consent helper and its Polkit action definition.";
    };

    requesterCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A program that describes the requesting T3 thread for the operator. Given
        the thread's ID, it prints the thread's name on one line and optionally
        an https link ending in that ID on the next, within three seconds. Without
        it, or if it fails, the prompt shows the ID.
      '';
    };

    remote = {
      enable = lib.mkEnableOption "answering from another device with a pinned passkey, alongside the local prompt";

      package = lib.mkPackageOption pkgs "credential-approval" {};

      origin = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "https://deck.example.com";
        description = "The origin of the page that relays requests, as a browser reports it.";
      };

      rpId = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "deck.example.com";
        description = "The relying party ID the passkey was created for.";
      };

      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "The pinned passkey's public key, in the form the relay's enrol page shows.";
      };

      credentialId = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "The pinned passkey's credential ID, in the form the relay's enrol page shows.";
      };

      timeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 600;
        description = ''
          How long a request stays open, on both paths. A broker that waits for
          the helper must wait longer than this.
        '';
      };

      spoolDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          The directory shared with the relay. Null uses credential-consent in
          the caller's runtime directory.
        '';
      };

      notifyCommand = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "A program run once per request as PROGRAM URL TITLE REQUESTER.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.ownerUsers != [];
        message = "security.credentialConsent.ownerUsers must name at least one explicit local user";
      }
      {
        assertion = lib.all (user: builtins.hasAttr user config.users.users) cfg.ownerUsers;
        message = "Every security.credentialConsent.ownerUsers entry must name a declared local user";
      }
      {
        assertion = !cfg.remote.enable || lib.all (value: value != "") [cfg.remote.origin cfg.remote.rpId cfg.remote.publicKey cfg.remote.credentialId];
        message = "security.credentialConsent.remote needs origin, rpId, publicKey and credentialId";
      }
    ];
    security.polkit.enable = true;
    environment.systemPackages = [cfg.package];
  };
}
