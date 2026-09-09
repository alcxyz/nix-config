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
    ];
    security.polkit.enable = true;
    environment.systemPackages = [cfg.package];
  };
}
